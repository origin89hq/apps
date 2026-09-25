//! Controller setup for the Origin89 apps: the P-049 setup code, a sans-IO
//! KM43 client that runs `Discover`, `Pair`, `Hello`, `GetConfig` and
//! `SetConfig` of the network section, `WifiScan` and `WifiStatus` where the
//! controller answers them, and an optional signed `Time`, the BLE GATT
//! fragmentation that carries its messages, and the WebSocket URL that
//! carries them on the site network, with the DNS-SD names that find it there.
//!
//! The wire format is the `km43` crate, the one the controller itself speaks.
//! Keys and session state stay in Rust; Swift sends and receives opaque frames
//! and gets typed results. The one exception is the encoded enrolment Swift
//! keeps in the Keychain between launches (P-222): the issued key, never the
//! printed secret.
//!
//! # Binding
//!
//! Swift reaches this crate through **`UniFFI`** (proc-macro mode), not a
//! hand-written C ABI. The records, the error enums and the [`SetupSession`]
//! object arrive in Swift as ordinary Swift types with the same fields and
//! cases, generated from the Rust definitions, so the two sides cannot drift
//! apart and no Swift code interprets bytes or error integers. A C ABI would
//! need that mapping written twice by hand, plus manual ownership of every
//! buffer that crosses. `UniFFI`'s async support is not used: the engine is
//! synchronous and sans-IO, and Swift owns the transport and the waiting.
//! `scripts/build-ios-core.sh` builds the static library for `aarch64-apple-ios`
//! and `aarch64-apple-ios-sim`, wraps it in an `XCFramework`, and generates the
//! Swift bindings with the workspace's `uniffi-bindgen`.

mod ble;
mod code;
mod engine;
mod note;
mod websocket;
mod wifi;

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use zeroize::Zeroize as _;

pub use ble::*;
pub use code::*;
pub use engine::*;
pub use note::*;
pub use websocket::*;
pub use wifi::*;

uniffi::setup_scaffolding!();

/// One setup session with one controller, driven step by step from Swift.
///
/// Every step is a pair: a `*_request` method returning the frame to send, and
/// a `*_reply` method taking each frame received until it returns a value or
/// an error. `None` from a reply method means the frame answered nothing
/// outstanding and the caller keeps receiving.
#[derive(uniffi::Object)]
pub struct SetupSession {
    engine: Mutex<Engine>,
}

/// Continue setup with the controller `device_id` (32 lowercase hexadecimal
/// characters) from the enrolment an earlier launch kept, without the setup
/// code (P-222). The session greets with `Hello` and cannot pair. `None` when
/// the identifier or the bytes do not decode; the bytes are cleared either way.
#[uniffi::export]
#[must_use]
pub fn resume_session(
    device_id: &str,
    mut kept: Vec<u8>,
    label: &str,
) -> Option<Arc<SetupSession>> {
    let engine = device_id.parse().ok().and_then(|device_id| {
        Engine::resume(device_id, &kept, label, CLIENT_VERSION, Box::new(OsNonces))
    });
    kept.zeroize();
    engine.map(|engine| {
        Arc::new(SetupSession {
            engine: Mutex::new(engine),
        })
    })
}

/// The controller and `epoch` an enrolment kept by an earlier launch was
/// issued for, for linking that generation to a site. `None` when the bytes do
/// not decode. The bytes are cleared either way; nothing secret is returned.
#[uniffi::export]
#[must_use]
pub fn kept_generation(mut kept: Vec<u8>) -> Option<KeptGeneration> {
    let generation = KeptGeneration::read(&kept);
    kept.zeroize();
    generation
}

#[uniffi::export]
impl SetupSession {
    /// Start a session from a scanned or pasted setup code, enrolling as
    /// `label` (see [`Engine::new`] for how the label is fitted).
    #[uniffi::constructor]
    pub fn new(setup_code: &str, label: &str) -> Result<Arc<Self>, SetupCodeError> {
        let code = SetupCode::parse(setup_code)?;
        Ok(Arc::new(Self {
            engine: Mutex::new(Engine::new(code, label, CLIENT_VERSION, Box::new(OsNonces))),
        }))
    }

    /// The controller's `device_id`, 32 lowercase hexadecimal characters.
    pub fn device_id(&self) -> String {
        self.engine().device_id().to_string()
    }

    /// Whether the next session greets with `Hello` rather than pairing: this
    /// client was enrolled, or holds a kept enrolment not yet refused.
    pub fn is_enrolled(&self) -> bool {
        self.engine().is_enrolled()
    }

    /// Take the enrolment an earlier launch kept, before this session sends
    /// its first frame. Returns whether it was taken; when it was not, the
    /// session pairs with the setup code. The bytes are cleared here either way.
    pub fn restore_kept(&self, mut kept: Vec<u8>) -> bool {
        let taken = self.engine().restore_kept(&kept);
        kept.zeroize();
        taken
    }

    /// The enrolment to keep, once `Pair` or a kept enrolment's `Hello` has
    /// succeeded: the issued key with its `device_id`, `epoch` and `client_id`,
    /// never the printed secret (P-222). Clear the copy once storage has it.
    pub fn kept_enrolment(&self) -> Option<Vec<u8>> {
        // The encoding clears itself on drop; the copy crossing to Swift is the
        // caller's to clear.
        self.engine().kept_enrolment().map(|bytes| bytes.to_vec())
    }

    /// Forget the connection and any session, keeping the enrolment. Call it
    /// on a new transport before `discover_request`.
    pub fn reset_link(&self) {
        self.engine().reset_link();
    }

    /// The `Discover` frame.
    pub fn discover_request(&self) -> Result<Vec<u8>, SetupFailure> {
        self.engine().discover_request()
    }

    /// Judge a frame received after `discover_request`.
    pub fn discover_reply(&self, frame: &[u8]) -> Result<Option<ControllerSummary>, SetupFailure> {
        self.engine().discover_reply(frame)
    }

    /// The `Pair` frame, proven from the setup code.
    pub fn pair_request(&self) -> Result<Vec<u8>, SetupFailure> {
        self.engine().pair_request()
    }

    /// Judge a frame received after `pair_request`.
    pub fn pair_reply(&self, frame: &[u8]) -> Result<Option<PairedClient>, SetupFailure> {
        self.engine().pair_reply(frame)
    }

    /// The `Hello` frame, proven from the enrolment.
    pub fn hello_request(&self) -> Result<Vec<u8>, SetupFailure> {
        self.engine().hello_request()
    }

    /// Judge a frame received after `hello_request`.
    pub fn hello_reply(&self, frame: &[u8]) -> Result<Option<SessionInfo>, SetupFailure> {
        self.engine().hello_reply(frame)
    }

    /// The `GetConfig` frame for the network section.
    pub fn read_network_request(&self) -> Result<Vec<u8>, SetupFailure> {
        self.engine().read_network_request()
    }

    /// Judge a frame received after `read_network_request`.
    pub fn read_network_reply(
        &self,
        frame: &[u8],
    ) -> Result<Option<NetworkSettings>, SetupFailure> {
        self.engine().read_network_reply(frame)
    }

    /// The signed `SetConfig` frame writing `change` against `expected_version`.
    pub fn write_network_request(
        &self,
        change: NetworkChange,
        expected_version: u32,
    ) -> Result<Vec<u8>, SetupFailure> {
        self.engine()
            .write_network_request(change, expected_version)
    }

    /// Judge a frame received after `write_network_request`; the new version.
    pub fn write_network_reply(&self, frame: &[u8]) -> Result<Option<u32>, SetupFailure> {
        self.engine().write_network_reply(frame)
    }

    /// The `WifiScan` frame; `refresh` also asks for a new scan.
    pub fn wifi_scan_request(&self, refresh: bool) -> Result<Vec<u8>, SetupFailure> {
        self.engine().wifi_scan_request(refresh)
    }

    /// Judge a frame received after `wifi_scan_request`.
    pub fn wifi_scan_reply(&self, frame: &[u8]) -> Result<Option<NetworkScan>, SetupFailure> {
        self.engine().wifi_scan_reply(frame)
    }

    /// The `WifiStatus` frame.
    pub fn wifi_status_request(&self) -> Result<Vec<u8>, SetupFailure> {
        self.engine().wifi_status_request()
    }

    /// Judge a frame received after `wifi_status_request`.
    pub fn wifi_status_reply(&self, frame: &[u8]) -> Result<Option<WifiStatus>, SetupFailure> {
        self.engine().wifi_status_reply(frame)
    }

    /// The signed `Time` frame for `at_ms`, milliseconds since the Unix epoch.
    pub fn set_time_request(&self, at_ms: u64) -> Result<Vec<u8>, SetupFailure> {
        self.engine().set_time_request(at_ms)
    }

    /// Judge a frame received after `set_time_request`; the controller's clock
    /// after the write, in milliseconds since the Unix epoch.
    pub fn set_time_reply(&self, frame: &[u8]) -> Result<Option<u64>, SetupFailure> {
        self.engine().set_time_reply(frame)
    }

    /// Describe a frame sent or received, for a log: its type, `req_id` and,
    /// for an `Error`, the code. Nothing else from the frame is included.
    pub fn frame_note(&self, frame: &[u8]) -> Option<FrameNote> {
        self.engine().frame_note(frame)
    }
}

impl SetupSession {
    /// A session with an injected nonce source, for deterministic tests.
    #[must_use]
    pub fn with_nonces(code: SetupCode, label: &str, nonces: Box<dyn NonceSource>) -> Arc<Self> {
        Arc::new(Self {
            engine: Mutex::new(Engine::new(code, label, CLIENT_VERSION, nonces)),
        })
    }

    /// A panic inside one step cannot leave the engine half-updated in a way
    /// that matters: every step either sets its next stage or leaves the old
    /// one, so a poisoned lock is recovered rather than propagated.
    fn engine(&self) -> MutexGuard<'_, Engine> {
        self.engine.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
