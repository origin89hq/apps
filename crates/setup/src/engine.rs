//! The sans-IO setup engine: it builds outbound KM43 frames and judges inbound
//! ones, and never touches a transport, a clock or a thread.
//!
//! Each step is a request method that returns the frame to send and a reply
//! method that takes one received frame. A reply method returns `Ok(None)` for
//! a frame that answers nothing outstanding (P-024), an unsolicited event, or
//! the link diagnostic `Error` with `session_id = 0, req_id = 0`; the caller
//! keeps receiving until it gets `Ok(Some(_))` or an error.
//!
//! The network steps are `GetConfig` and a signed `SetConfig`; on a controller
//! that sets capability bit 8 the engine also reads `WifiScan` and
//! `WifiStatus` (P-216), and refuses to send either to one that does not.

use core::mem;

use km43::{
    Attempt, ClientId, ClientKind, ConfigAnswer, ConfigSection, Counter, Country, Discovery,
    EmptyBody, Enrolment, Envelope, Epoch, ErrorBody, ErrorCode, GetConfigRequest, Handshake,
    Header, HelloInner, Hostname, Incoming, JoinWrite, MAX_LABEL, MAX_PAYLOAD, MAX_STRING,
    MessageType, NetworkRead, NetworkWrite, Outcome, PairAckClaim, PairRequest, Passphrase, ReqId,
    ScanRequest, Session as Opened, SessionId, SessionKey, SetConfig, SetConfigAck,
    SetConfigOperation, Signed, Ssid, Tagged, Time, TimeAck, TimeOperation, Version, Wrapper,
};
use zeroize::{Zeroize, Zeroizing};

use crate::code::{ControllerId, SetupCode};
use crate::wifi::{NetworkScan, WifiStatus};

const NONCE_BYTES: usize = 16;

/// `Hello 0x81` capability bit 8, `CapabilityBit::WifiScanAndJoinStatus`: the
/// controller answers `WifiScan` and `WifiStatus` (P-216).
const REPORTS_WIFI: u32 = 1 << 8;

/// What this client calls itself in `Hello` (`client_version`) unless told
/// otherwise.
pub const CLIENT_VERSION: &str = concat!("origin89-setup ", env!("CARGO_PKG_VERSION"));

/// The label sent when the one supplied is empty.
pub const FALLBACK_LABEL: &str = "Origin89 app";

/// Why a setup step failed. One variant per case the Swift `SetupFailure` names,
/// except `timedOut`, which only the transport can observe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum SetupFailure {
    /// `Pair 0x8B` outcome 2: no pairing window is open at the panel.
    #[error("the pairing window is closed")]
    WindowClosed,
    /// `Pair 0x8B` outcome 3: the proof from this setup code did not verify.
    #[error("the controller refused the proof from this setup code")]
    WrongProof,
    /// `Pair 0x8B` outcome 4: eight other clients are enrolled.
    #[error("the controller's client table is full")]
    TableFull,
    /// `SetConfigAck` outcome 2 (P-100): the section changed since it was read.
    #[error("the network section changed since it was read")]
    StaleVersion,
    /// `SetConfigAck` outcome 3 (P-101, P-107), or the same judgement made here
    /// before sending.
    #[error("the network settings are invalid")]
    InvalidConfig,
    /// The controller that answered `Discover` is not the one the code names.
    #[error("the controller is not the one this setup code was printed for")]
    ControllerMismatch,
    /// The link or the session is gone: reconnect, `Discover` and `Hello` again.
    #[error("the connection to the controller was lost")]
    ConnectionDropped,
    /// `TimeAck` outcome 2 (P-113): the time is outside the plausibility window.
    #[error("the controller refused the time as implausible")]
    TimeRejected,
    /// `TimeAck` outcome 4 (P-114): the time is below the log floor and needs the
    /// override armed at the panel.
    #[error("setting this time needs the button at the panel")]
    TimeNeedsButton,
    /// A malformed, unauthenticated or unexpected reply, a `Config` carrying a
    /// secret (P-106), a step called out of order, or no local randomness.
    #[error("the controller's reply broke the protocol")]
    ProtocolError,
}

impl SetupFailure {
    /// Whether the engine can continue after this failure without reconnecting.
    const fn is_refusal(self) -> bool {
        match self {
            Self::WindowClosed
            | Self::WrongProof
            | Self::TableFull
            | Self::StaleVersion
            | Self::InvalidConfig
            | Self::TimeRejected
            | Self::TimeNeedsButton => true,
            Self::ControllerMismatch | Self::ConnectionDropped | Self::ProtocolError => false,
        }
    }
}

/// The controller `Discover` found.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ControllerSummary {
    /// The `device_id`, 32 lowercase hexadecimal characters.
    pub device_id: String,
}

/// The enrolment `Pair` produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PairedClient {
    /// The `client_id` the controller allocated.
    pub client_id: u32,
    /// Whether an existing row with this label was reused (outcome 5, P-078).
    pub reclaimed: bool,
}

/// What `Hello` reported that the setup flow can use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SessionInfo {
    /// Whether the controller's clock has been set.
    pub time_known: bool,
    /// Whether the controller answers `WifiScan` and `WifiStatus` (capability
    /// bit 8, P-216). Without it the person types the network name.
    pub reports_wifi: bool,
}

/// The network section as `Config 0x86` carries it: never the passphrase.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetworkSettings {
    /// 0 when the section has never been written (P-108).
    pub version: u32,
    /// The network to join, absent when none is set.
    pub ssid: Option<String>,
    /// Whether a passphrase is held for `ssid` (`psk_set`, P-106).
    pub passphrase_set: bool,
    /// ISO 3166-1 alpha-2, absent only when never written.
    pub country: Option<String>,
    /// Absent only when never written.
    pub hostname: Option<String>,
}

/// A network write, as the person entered it.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetworkChange {
    /// The network to join; `None` clears it.
    pub ssid: Option<String>,
    /// `None` keeps the held passphrase, valid only for the same `ssid` (P-107).
    pub passphrase: Option<String>,
    /// Two capital letters.
    pub country: String,
    /// Letters, digits and inner hyphens, 1 to 32 bytes.
    pub hostname: String,
}

impl core::fmt::Debug for NetworkChange {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("NetworkChange")
            .field("ssid", &self.ssid)
            .field("passphrase", &self.passphrase.as_ref().map(|_| "withheld"))
            .field("country", &self.country)
            .field("hostname", &self.hostname)
            .finish()
    }
}

/// Where the 16-byte nonces `Pair` and `Hello` need come from (P-069, P-071).
pub trait NonceSource: Send {
    /// A fresh nonce, or `None` when no randomness is available.
    fn nonce(&mut self) -> Option<[u8; NONCE_BYTES]>;
}

/// The operating system's CSPRNG.
#[derive(Debug, Clone, Copy, Default)]
pub struct OsNonces;

impl NonceSource for OsNonces {
    fn nonce(&mut self) -> Option<[u8; NONCE_BYTES]> {
        let mut nonce = [0u8; NONCE_BYTES];
        getrandom::fill(&mut nonce).ok()?;
        Some(nonce)
    }
}

/// A connection before `Hello`: its handle (P-024) and a live challenge.
#[derive(Clone, Copy)]
struct Link {
    handle: SessionId,
    challenge: [u8; NONCE_BYTES],
    epoch: Epoch,
}

/// What the last `Config` said, for the local P-107 check.
struct ReadBack {
    version: u32,
    ssid: Option<String>,
    passphrase_set: bool,
}

struct Session {
    id: SessionId,
    key: SessionKey,
    client_id: ClientId,
    counter: Counter,
    read: Option<ReadBack>,
    reports_wifi: bool,
}

enum Stage {
    Idle,
    Discovering {
        req: ReqId,
    },
    Discovered(Link),
    Pairing {
        req: ReqId,
        link: Link,
        attempt: Attempt,
    },
    Enrolled(Link),
    Greeting {
        req: ReqId,
        handshake: Handshake,
    },
    Ready(Session),
    Reading {
        req: ReqId,
        session: Session,
    },
    Writing {
        req: ReqId,
        session: Session,
        expected: u32,
    },
    SettingTime {
        req: ReqId,
        session: Session,
    },
    Scanning {
        req: ReqId,
        session: Session,
    },
    CheckingWifi {
        req: ReqId,
        session: Session,
    },
    Failed,
}

/// One setup session with one controller.
pub struct Engine {
    device_id: ControllerId,
    code: Option<SetupCode>,
    enrolment: Option<Enrolment>,
    label: String,
    client_version: String,
    nonces: Box<dyn NonceSource>,
    next_req: u32,
    stage: Stage,
}

impl Engine {
    /// Start a session for the controller `code` names, enrolling as `label`.
    ///
    /// `label` is what a person sees in the controller's client list, and a
    /// re-pair with the same label reclaims the same row (P-078), so it should
    /// be stable and distinct per device. It is cut to `MAX_LABEL` bytes on a
    /// character boundary; an empty one becomes [`FALLBACK_LABEL`].
    /// `client_version` is cut to `MAX_STRING` bytes the same way, and an empty
    /// one becomes [`CLIENT_VERSION`].
    #[must_use]
    pub fn new(
        code: SetupCode,
        label: &str,
        client_version: &str,
        nonces: Box<dyn NonceSource>,
    ) -> Self {
        Self {
            device_id: code.device_id(),
            code: Some(code),
            enrolment: None,
            label: fit_text(label, MAX_LABEL, FALLBACK_LABEL),
            client_version: fit_text(client_version, MAX_STRING, CLIENT_VERSION),
            nonces,
            next_req: 1,
            stage: Stage::Idle,
        }
    }

    /// The controller the setup code names.
    #[must_use]
    pub const fn device_id(&self) -> ControllerId {
        self.device_id
    }

    /// Whether the controller has enrolled this client. From then on the setup
    /// code's secret is gone.
    #[must_use]
    pub const fn is_enrolled(&self) -> bool {
        self.enrolment.is_some()
    }

    /// Forget the connection and any session, keeping the enrolment (or the
    /// setup code, if not yet enrolled). Call it on a new transport; the next
    /// step is `Discover`.
    pub fn reset_link(&mut self) {
        self.stage = Stage::Idle;
    }

    /// `Discover 0x00`. Valid on a fresh link, or before `Pair` or `Hello` to
    /// fetch a live challenge again.
    pub fn discover_request(&mut self) -> Result<Vec<u8>, SetupFailure> {
        let handle = match &self.stage {
            Stage::Idle => SessionId::None,
            Stage::Discovered(link) | Stage::Enrolled(link) => link.handle,
            Stage::Discovering { .. }
            | Stage::Pairing { .. }
            | Stage::Greeting { .. }
            | Stage::Ready(_)
            | Stage::Reading { .. }
            | Stage::Writing { .. }
            | Stage::SettingTime { .. }
            | Stage::Scanning { .. }
            | Stage::CheckingWifi { .. }
            | Stage::Failed => return Err(SetupFailure::ProtocolError),
        };
        let req = self.allocate()?;
        let header = Header {
            kind: MessageType::Discover,
            session: handle,
            req_id: req,
        };
        let frame = build(|dst| {
            let cbor = header.write(0, dst).map_err(encoding)?;
            cbor.finish().map_err(encoding)
        })?;
        self.stage = Stage::Discovering { req };
        Ok(frame)
    }

    /// Judge a frame received while `Discover` is outstanding.
    pub fn discover_reply(
        &mut self,
        frame: &[u8],
    ) -> Result<Option<ControllerSummary>, SetupFailure> {
        let Stage::Discovering { req } = self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = self.judge_discover(frame, req);
        self.settle(judged)
    }

    fn judge_discover(
        &mut self,
        frame: &[u8],
        req: ReqId,
    ) -> Result<Option<ControllerSummary>, SetupFailure> {
        let Some(envelope) = inbound(frame, req, None, MessageType::DiscoverResponse)? else {
            return Ok(None);
        };
        let handle = envelope.header().session;
        let found = Discovery::decode(envelope).map_err(malformed)?;
        Version::V1_0.agreed(found.version).map_err(malformed)?;
        let found_id = ControllerId::from(found.device_id);
        if found_id != self.device_id {
            return Err(SetupFailure::ControllerMismatch);
        }
        let link = Link {
            handle,
            challenge: found.challenge,
            epoch: found.epoch,
        };
        self.stage = if self.enrolment.is_some() {
            Stage::Enrolled(link)
        } else {
            Stage::Discovered(link)
        };
        Ok(Some(ControllerSummary {
            device_id: found_id.to_string(),
        }))
    }

    /// `Pair 0x0B`, proving knowledge of the printed secret under `pair_key`.
    pub fn pair_request(&mut self) -> Result<Vec<u8>, SetupFailure> {
        let Stage::Discovered(link) = self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let Some(code) = &self.code else {
            return Err(SetupFailure::ProtocolError);
        };
        let client_nonce = self.nonces.nonce().ok_or(SetupFailure::ProtocolError)?;
        let attempt = Attempt {
            device_id: *self.device_id.as_bytes(),
            challenge: link.challenge,
            client_nonce,
        };
        let pair_key = code.device_secret().pair_key();
        let req = self.allocate()?;
        let header = Header {
            kind: MessageType::Pair,
            session: link.handle,
            req_id: req,
        };
        let request = PairRequest {
            client_kind: ClientKind::App,
            label: &self.label,
        };
        let frame = build(|dst| {
            request
                .write(&pair_key, &attempt, header, dst)
                .map_err(encoding)
        })?;
        self.stage = Stage::Pairing { req, link, attempt };
        Ok(frame)
    }

    /// Judge a frame received while `Pair` is outstanding. A refusal leaves the
    /// engine ready to `Pair` again against the challenge the refusal carried
    /// (P-058).
    pub fn pair_reply(&mut self, frame: &[u8]) -> Result<Option<PairedClient>, SetupFailure> {
        let Stage::Pairing { req, link, attempt } = self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = self.judge_pair(frame, req, link, &attempt);
        self.settle(judged)
    }

    fn judge_pair(
        &mut self,
        frame: &[u8],
        req: ReqId,
        link: Link,
        attempt: &Attempt,
    ) -> Result<Option<PairedClient>, SetupFailure> {
        let Some(code) = &self.code else {
            return Err(SetupFailure::ProtocolError);
        };
        let Some(envelope) = inbound(frame, req, None, MessageType::PairResponse)? else {
            return Ok(None);
        };
        let handle = envelope.header().session;
        let secret = code.device_secret();
        // P-064: nothing in the ack is believed until its MAC verifies.
        let answer = PairAckClaim::decode(envelope)
            .map_err(malformed)?
            .verify(&secret.pair_key(), attempt, link.epoch)
            .map_err(malformed)?;
        let next = Link {
            handle,
            challenge: answer.next_challenge,
            epoch: link.epoch,
        };
        let (client_id, reclaimed) = match answer.outcome {
            Outcome::Enrolled(id) => (id, false),
            Outcome::Reclaimed(id) => (id, true),
            Outcome::WindowClosed => return self.refuse_pair(next, SetupFailure::WindowClosed),
            Outcome::BadProof => return self.refuse_pair(next, SetupFailure::WrongProof),
            Outcome::TableFull => return self.refuse_pair(next, SetupFailure::TableFull),
        };
        self.enrolment = Some(secret.enrolment(link.epoch, client_id));
        // Enrolled: the printed secret is no longer needed and goes now.
        self.code = None;
        self.stage = Stage::Enrolled(next);
        Ok(Some(PairedClient {
            client_id: client_id.get(),
            reclaimed,
        }))
    }

    fn refuse_pair<T>(&mut self, link: Link, why: SetupFailure) -> Result<T, SetupFailure> {
        self.stage = Stage::Discovered(link);
        Err(why)
    }

    /// `Hello 0x01`, proving the enrolment against the live challenge.
    pub fn hello_request(&mut self) -> Result<Vec<u8>, SetupFailure> {
        let Stage::Enrolled(link) = self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let Some(enrolment) = &self.enrolment else {
            return Err(SetupFailure::ProtocolError);
        };
        let client_nonce = self.nonces.nonce().ok_or(SetupFailure::ProtocolError)?;
        let inner = HelloInner {
            version: Version::V1_0,
            client_id: enrolment.client_id(),
            client_version: &self.client_version,
            client_nonce,
        };
        let mut payload = [0u8; MAX_PAYLOAD];
        let proven = inner
            .prove(&enrolment.client_key(), &link.challenge, &mut payload)
            .map_err(encoding)?;
        let req = self.allocate()?;
        let header = Header {
            kind: MessageType::Hello,
            session: link.handle,
            req_id: req,
        };
        let frame = build(|dst| proven.write(header, dst).map_err(encoding))?;
        self.stage = Stage::Greeting {
            req,
            handshake: Handshake {
                challenge: link.challenge,
                client_nonce,
            },
        };
        Ok(frame)
    }

    /// Judge a frame received while `Hello` is outstanding.
    pub fn hello_reply(&mut self, frame: &[u8]) -> Result<Option<SessionInfo>, SetupFailure> {
        let Stage::Greeting { req, handshake } = self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = self.judge_hello(frame, req, &handshake);
        self.settle(judged)
    }

    fn judge_hello(
        &mut self,
        frame: &[u8],
        req: ReqId,
        handshake: &Handshake,
    ) -> Result<Option<SessionInfo>, SetupFailure> {
        let Some(enrolment) = &self.enrolment else {
            return Err(SetupFailure::ProtocolError);
        };
        let Some(envelope) = inbound(frame, req, None, MessageType::HelloResponse)? else {
            return Ok(None);
        };
        // P-072: the key comes from the envelope's session_id, and the MAC then
        // proves that session_id was not rewritten.
        let id = envelope.header().session;
        let opened =
            Opened::open(envelope, enrolment, handshake, Version::V1_0).map_err(malformed)?;
        let report = opened.report();
        let info = SessionInfo {
            time_known: report.time_known,
            reports_wifi: report.capabilities & REPORTS_WIFI != 0,
        };
        let counter = Counter(report.counter);
        self.stage = Stage::Ready(Session {
            id,
            key: enrolment.session_key(handshake, id),
            client_id: enrolment.client_id(),
            counter,
            read: None,
            reports_wifi: info.reports_wifi,
        });
        Ok(Some(info))
    }

    /// `GetConfig 0x06` for the network section.
    pub fn read_network_request(&mut self) -> Result<Vec<u8>, SetupFailure> {
        let session = self.take_ready()?;
        match self.get_config(&session) {
            Ok((frame, req)) => {
                self.stage = Stage::Reading { req, session };
                Ok(frame)
            }
            Err(why) => {
                self.stage = Stage::Ready(session);
                Err(why)
            }
        }
    }

    fn get_config(&mut self, session: &Session) -> Result<(Vec<u8>, ReqId), SetupFailure> {
        self.wrapped(session, MessageType::GetConfig, |dst| {
            GetConfigRequest {
                section: ConfigSection::Network,
            }
            .encode(dst)
            .map_err(encoding)
        })
    }

    /// A wrapped read: `body` tagged under the session key.
    fn wrapped(
        &mut self,
        session: &Session,
        kind: MessageType,
        body: impl FnOnce(&mut [u8]) -> Result<usize, SetupFailure>,
    ) -> Result<(Vec<u8>, ReqId), SetupFailure> {
        let mut payload = [0u8; MAX_PAYLOAD];
        let len = body(&mut payload)?;
        let payload = payload.get(..len).ok_or(SetupFailure::ProtocolError)?;
        let req = self.allocate()?;
        let header = Header {
            kind,
            session: session.id,
            req_id: req,
        };
        let tagged = Tagged::over(header, payload, &session.key).map_err(encoding)?;
        let frame = build(|dst| tagged.write(dst).map_err(encoding))?;
        Ok((frame, req))
    }

    /// Judge a frame received while `GetConfig` is outstanding.
    pub fn read_network_reply(
        &mut self,
        frame: &[u8],
    ) -> Result<Option<NetworkSettings>, SetupFailure> {
        let Stage::Reading { req, session } = &self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = judge_config(frame, *req, session);
        let judged = match judged {
            Ok(Some(settings)) => {
                self.finish_request(|session| {
                    session.read = Some(ReadBack {
                        version: settings.version,
                        ssid: settings.ssid.clone(),
                        passphrase_set: settings.passphrase_set,
                    });
                });
                Ok(Some(settings))
            }
            other => other,
        };
        self.settle(judged)
    }

    /// `SetConfig 0x07` of the network section against `expected_version`, the
    /// version just read (P-100). Checked here against the section's bounds and
    /// P-107 first; the controller's verdict is still the one that counts.
    pub fn write_network_request(
        &mut self,
        mut change: NetworkChange,
        expected_version: u32,
    ) -> Result<Vec<u8>, SetupFailure> {
        let session = self.take_ready()?;
        let built =
            network_body(&change, session.read.as_ref(), expected_version).and_then(|body| {
                self.signed(&session, MessageType::SetConfig, |dst| {
                    SetConfigOperation {
                        section: ConfigSection::Network,
                        expected_version,
                        body: &body,
                    }
                    .encode(dst)
                    .map_err(encoding)
                })
            });
        change.passphrase.zeroize();
        match built {
            Ok((frame, req, counter)) => {
                let mut session = session;
                session.counter = counter;
                self.stage = Stage::Writing {
                    req,
                    session,
                    expected: expected_version,
                };
                Ok(frame)
            }
            Err(why) => {
                self.stage = Stage::Ready(session);
                Err(why)
            }
        }
    }

    /// Judge a frame received while `SetConfig` is outstanding. Returns the
    /// section's new version.
    pub fn write_network_reply(&mut self, frame: &[u8]) -> Result<Option<u32>, SetupFailure> {
        let Stage::Writing {
            req,
            session,
            expected,
        } = &self.stage
        else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = judge_set_config(frame, *req, session, *expected);
        let judged = match judged {
            Ok(Some(version)) => {
                self.finish_request(|session| session.read = None);
                Ok(Some(version))
            }
            Err(why) if why.is_refusal() => {
                self.finish_request(|_| {});
                Err(why)
            }
            other => other,
        };
        self.settle(judged)
    }

    /// `WifiScan 0x11`: the networks the controller's radio heard. With
    /// `refresh` the controller also starts a scan unless it refuses (P-218);
    /// the answer then says `running`, and a later read returns the new list.
    /// Refused here, sending nothing, when the controller did not set
    /// capability bit 8 (P-216).
    pub fn wifi_scan_request(&mut self, refresh: bool) -> Result<Vec<u8>, SetupFailure> {
        let session = self.take_reporting()?;
        match self.wrapped(&session, MessageType::WifiScan, |dst| {
            ScanRequest { refresh }.encode(dst).map_err(encoding)
        }) {
            Ok((frame, req)) => {
                self.stage = Stage::Scanning { req, session };
                Ok(frame)
            }
            Err(why) => {
                self.stage = Stage::Ready(session);
                Err(why)
            }
        }
    }

    /// Judge a frame received while `WifiScan` is outstanding.
    pub fn wifi_scan_reply(&mut self, frame: &[u8]) -> Result<Option<NetworkScan>, SetupFailure> {
        let Stage::Scanning { req, session } = &self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = judge_wrapped(frame, *req, session, MessageType::WifiScanResponse)
            .and_then(|payload| payload.map(|body| NetworkScan::read(&body)).transpose());
        if let Ok(Some(_)) = judged {
            self.finish_request(|_| {});
        }
        self.settle(judged)
    }

    /// `WifiStatus 0x12`: what the radio did with the network it holds.
    /// Refused here like [`Engine::wifi_scan_request`].
    pub fn wifi_status_request(&mut self) -> Result<Vec<u8>, SetupFailure> {
        let session = self.take_reporting()?;
        match self.wrapped(&session, MessageType::WifiStatus, |dst| {
            EmptyBody
                .encode(MessageType::WifiStatus, dst)
                .map_err(encoding)
        }) {
            Ok((frame, req)) => {
                self.stage = Stage::CheckingWifi { req, session };
                Ok(frame)
            }
            Err(why) => {
                self.stage = Stage::Ready(session);
                Err(why)
            }
        }
    }

    /// Judge a frame received while `WifiStatus` is outstanding.
    pub fn wifi_status_reply(&mut self, frame: &[u8]) -> Result<Option<WifiStatus>, SetupFailure> {
        let Stage::CheckingWifi { req, session } = &self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = judge_wrapped(frame, *req, session, MessageType::WifiStatusResponse)
            .and_then(|payload| payload.map(|body| WifiStatus::read(&body)).transpose());
        if let Ok(Some(_)) = judged {
            self.finish_request(|_| {});
        }
        self.settle(judged)
    }

    /// A signed `Time 0x0A` setting the controller's clock to `at_ms`,
    /// milliseconds since the Unix epoch.
    pub fn set_time_request(&mut self, at_ms: u64) -> Result<Vec<u8>, SetupFailure> {
        let session = self.take_ready()?;
        let built = self.signed(&session, MessageType::Time, |dst| {
            TimeOperation { at: at_ms }.encode(dst).map_err(encoding)
        });
        match built {
            Ok((frame, req, counter)) => {
                let mut session = session;
                session.counter = counter;
                self.stage = Stage::SettingTime { req, session };
                Ok(frame)
            }
            Err(why) => {
                self.stage = Stage::Ready(session);
                Err(why)
            }
        }
    }

    /// Judge a frame received while `Time` is outstanding. Returns the
    /// controller's clock after the write.
    pub fn set_time_reply(&mut self, frame: &[u8]) -> Result<Option<u64>, SetupFailure> {
        let Stage::SettingTime { req, session } = &self.stage else {
            return Err(SetupFailure::ProtocolError);
        };
        let judged = match judge_time(frame, *req, session) {
            Ok(Some(at)) => {
                self.finish_request(|_| {});
                Ok(Some(at))
            }
            Err(why) if why.is_refusal() => {
                self.finish_request(|_| {});
                Err(why)
            }
            other => other,
        };
        self.settle(judged)
    }

    /// Sign an operation for the session, returning the frame, its `req_id` and
    /// the counter it spent.
    fn signed(
        &mut self,
        session: &Session,
        kind: MessageType,
        operation: impl FnOnce(&mut [u8]) -> Result<usize, SetupFailure>,
    ) -> Result<(Vec<u8>, ReqId, Counter), SetupFailure> {
        let mut op = Zeroizing::new([0u8; MAX_PAYLOAD]);
        let len = operation(op.as_mut())?;
        let op = op.get(..len).ok_or(SetupFailure::ProtocolError)?;
        let counter = session.counter.next().ok_or(SetupFailure::ProtocolError)?;
        let req = self.allocate()?;
        let header = Header {
            kind,
            session: session.id,
            req_id: req,
        };
        let signed =
            Signed::over(header, session.client_id, counter, op, &session.key).map_err(encoding)?;
        let frame = build(|dst| signed.write(dst).map_err(encoding))?;
        Ok((frame, req, counter))
    }

    /// The ready session, only when its controller reports Wi-Fi (P-216).
    fn take_reporting(&mut self) -> Result<Session, SetupFailure> {
        let session = self.take_ready()?;
        if session.reports_wifi {
            Ok(session)
        } else {
            self.stage = Stage::Ready(session);
            Err(SetupFailure::ProtocolError)
        }
    }

    fn take_ready(&mut self) -> Result<Session, SetupFailure> {
        match mem::replace(&mut self.stage, Stage::Failed) {
            Stage::Ready(session) => Ok(session),
            other => {
                self.stage = other;
                Err(SetupFailure::ProtocolError)
            }
        }
    }

    /// Return an in-flight session to `Ready`, updating it on the way.
    fn finish_request(&mut self, update: impl FnOnce(&mut Session)) {
        match mem::replace(&mut self.stage, Stage::Failed) {
            Stage::Reading { mut session, .. }
            | Stage::Writing { mut session, .. }
            | Stage::SettingTime { mut session, .. }
            | Stage::Scanning { mut session, .. }
            | Stage::CheckingWifi { mut session, .. } => {
                update(&mut session);
                self.stage = Stage::Ready(session);
            }
            other @ (Stage::Idle
            | Stage::Discovering { .. }
            | Stage::Discovered(_)
            | Stage::Pairing { .. }
            | Stage::Enrolled(_)
            | Stage::Greeting { .. }
            | Stage::Ready(_)
            | Stage::Failed) => self.stage = other,
        }
    }

    /// The next `req_id`, strictly increasing and never reused (P-022).
    fn allocate(&mut self) -> Result<ReqId, SetupFailure> {
        let req = self.next_req;
        self.next_req = req.checked_add(1).ok_or(SetupFailure::ProtocolError)?;
        Ok(ReqId(req))
    }

    /// A failure that is not a refusal ends the session: the caller reconnects
    /// (or gives up) and starts again from `Discover`.
    fn settle<T>(&mut self, judged: Result<T, SetupFailure>) -> Result<T, SetupFailure> {
        if let Err(why) = judged
            && !why.is_refusal()
        {
            self.stage = Stage::Failed;
        }
        judged
    }
}

/// Classify one received frame against the one request outstanding.
///
/// `Ok(None)` is a frame this request must ignore: an event, the link
/// diagnostic `Error` with `session_id = 0, req_id = 0` (P-024), or a response
/// to something else. Before a session exists responses match on `req_id`
/// alone (P-024); after, on `(session_id, req_id)`.
fn inbound<'f>(
    frame: &'f [u8],
    req: ReqId,
    session: Option<&Session>,
    want: MessageType,
) -> Result<Option<Envelope<'f>>, SetupFailure> {
    let envelope = Envelope::decode(frame).map_err(malformed)?;
    let header = envelope.header();
    if header.kind == MessageType::EventResponse {
        return Ok(None);
    }
    if header.kind == MessageType::ErrorResponse
        && header.session == SessionId::None
        && header.req_id == ReqId(0)
    {
        return Ok(None);
    }
    if header.req_id != req {
        return Ok(None);
    }
    if let Some(session) = session
        && header.session != session.id
    {
        return Ok(None);
    }
    if header.kind == MessageType::ErrorResponse {
        return Err(refused_by_error(envelope, session));
    }
    if header.kind != want {
        return Err(SetupFailure::ProtocolError);
    }
    Ok(Some(envelope))
}

/// An `Error 0xFF` answering the outstanding request.
///
/// Before a session, and on a session whose `Error` is bare or does not verify,
/// the error is a hint and nothing more (P-055, P-140, P-142): the only thing it
/// licenses is reconnecting and sending `Discover` and `Hello` again, which is
/// what [`SetupFailure::ConnectionDropped`] tells the caller to do. Its code is
/// not read.
///
/// A wrapped error that verifies under the session key is read. The codes that
/// a reconnect cures — busy (P-079, P-118), session table full, session expired
/// or unknown (P-143), counter not fresh (P-081 says re-`Hello` for key 11),
/// stale or unavailable challenge (P-060, P-062), `Hello` required — are
/// `ConnectionDropped` too; the rest say this client sent something wrong and
/// are [`SetupFailure::ProtocolError`].
fn refused_by_error(envelope: Envelope<'_>, session: Option<&Session>) -> SetupFailure {
    let Some(session) = session else {
        return SetupFailure::ConnectionDropped;
    };
    let Ok(verified) = Wrapper::decode(envelope).and_then(|wrapper| wrapper.verify(&session.key))
    else {
        return SetupFailure::ConnectionDropped;
    };
    let Ok(body) = ErrorBody::authenticated(verified.payload()) else {
        return SetupFailure::ProtocolError;
    };
    match body.code {
        Incoming::Client(
            ErrorCode::BusyRetry
            | ErrorCode::SessionTableFull
            | ErrorCode::SessionExpired
            | ErrorCode::CounterNotFresh
            | ErrorCode::StaleChallengeReconnectAndRetry
            | ErrorCode::ChallengeUnavailable
            | ErrorCode::HelloRequiredFirst,
        )
        | Incoming::LinkLocal(_) => SetupFailure::ConnectionDropped,
        Incoming::Client(
            ErrorCode::MalformedFrame
            | ErrorCode::UnknownMessageType
            | ErrorCode::ProtocolMajorMismatch
            | ErrorCode::PayloadTooLarge
            | ErrorCode::UnknownSection
            | ErrorCode::BadMAC
            | ErrorCode::UnknownClient,
        )
        | Incoming::Unknown(_) => SetupFailure::ProtocolError,
    }
}

/// The verified payload of a wrapped response of `kind` to `req`, or `None`
/// for a frame answering something else.
fn judge_wrapped(
    frame: &[u8],
    req: ReqId,
    session: &Session,
    kind: MessageType,
) -> Result<Option<Vec<u8>>, SetupFailure> {
    let Some(envelope) = inbound(frame, req, Some(session), kind)? else {
        return Ok(None);
    };
    verified(envelope, &session.key).map(|payload| Some(payload.to_vec()))
}

/// The verified payload of a wrapped response.
fn verified<'f>(envelope: Envelope<'f>, key: &SessionKey) -> Result<&'f [u8], SetupFailure> {
    let verified = Wrapper::decode(envelope)
        .and_then(|wrapper| wrapper.verify(key))
        .map_err(malformed)?;
    Ok(verified.payload())
}

fn judge_config(
    frame: &[u8],
    req: ReqId,
    session: &Session,
) -> Result<Option<NetworkSettings>, SetupFailure> {
    let Some(envelope) = inbound(frame, req, Some(session), MessageType::GetConfigResponse)? else {
        return Ok(None);
    };
    let payload = verified(envelope, &session.key)?;
    // P-108: version 0 exactly when there is no body, enforced by the decode.
    let answer = ConfigAnswer::decode(payload).map_err(malformed)?;
    if answer.section() != ConfigSection::Network {
        return Err(SetupFailure::ProtocolError);
    }
    let Some(body) = answer.body() else {
        return Ok(Some(NetworkSettings {
            version: answer.version(),
            ssid: None,
            passphrase_set: false,
            country: None,
            hostname: None,
        }));
    };
    // P-106: a body carrying `psk` is refused, not shown.
    let read = NetworkRead::decode(body).map_err(malformed)?;
    Ok(Some(NetworkSettings {
        version: answer.version(),
        ssid: read.join.map(|join| join.ssid.as_str().to_owned()),
        passphrase_set: read.join.is_some_and(|join| join.psk_set),
        country: Some(read.country.as_str().to_owned()),
        hostname: Some(read.hostname.as_str().to_owned()),
    }))
}

fn judge_set_config(
    frame: &[u8],
    req: ReqId,
    session: &Session,
    expected: u32,
) -> Result<Option<u32>, SetupFailure> {
    let Some(envelope) = inbound(frame, req, Some(session), MessageType::SetConfigResponse)? else {
        return Ok(None);
    };
    let payload = verified(envelope, &session.key)?;
    let ack = SetConfigAck::decode(payload).map_err(malformed)?;
    if ack.section != ConfigSection::Network {
        return Err(SetupFailure::ProtocolError);
    }
    match ack.outcome {
        SetConfig::Accepted => {
            // The version increments on every accepted write, and this one was
            // accepted against `expected`.
            if Some(ack.version) != expected.checked_add(1) {
                return Err(SetupFailure::ProtocolError);
            }
            Ok(Some(ack.version))
        }
        SetConfig::StaleVersion => Err(SetupFailure::StaleVersion),
        SetConfig::Invalid | SetConfig::ExceedsCap => Err(SetupFailure::InvalidConfig),
        // An app enrols with the network bit (REGISTRY capability mask), and
        // `staged` is reserved: neither is an answer this write can get.
        SetConfig::Unauthorised | SetConfig::Staged => Err(SetupFailure::ProtocolError),
    }
}

fn judge_time(frame: &[u8], req: ReqId, session: &Session) -> Result<Option<u64>, SetupFailure> {
    let Some(envelope) = inbound(frame, req, Some(session), MessageType::TimeResponse)? else {
        return Ok(None);
    };
    let payload = verified(envelope, &session.key)?;
    // An accepted ack without its time is refused by the decode.
    let ack = TimeAck::decode(payload).map_err(malformed)?;
    match (ack.outcome(), ack.at()) {
        (Time::Accepted, Some(at)) => Ok(Some(at)),
        (Time::Accepted, None) | (Time::Unauthorised, _) => Err(SetupFailure::ProtocolError),
        (Time::Rejected, _) => Err(SetupFailure::TimeRejected),
        (Time::NeedsButton, _) => Err(SetupFailure::TimeNeedsButton),
    }
}

/// The `NetworkWrite 0x0020` body for `change`, refused locally when it breaks
/// the section's bounds or, when `held` is the version being written against,
/// P-107.
fn network_body(
    change: &NetworkChange,
    held: Option<&ReadBack>,
    expected: u32,
) -> Result<Zeroizing<Vec<u8>>, SetupFailure> {
    let join = match (change.ssid.as_deref(), change.passphrase.as_deref()) {
        (None, None) => None,
        (None, Some(_)) => return Err(SetupFailure::InvalidConfig),
        (Some(ssid), psk) => Some(JoinWrite {
            ssid: Ssid::new(ssid).map_err(invalid)?,
            psk: psk.map(Passphrase::new).transpose().map_err(invalid)?,
        }),
    };
    let write = NetworkWrite {
        join,
        country: Country::new(&change.country).map_err(invalid)?,
        hostname: Hostname::new(&change.hostname).map_err(invalid)?,
    };
    if let Some(held) = held.filter(|held| held.version == expected) {
        let held_for = match (held.ssid.as_deref(), held.passphrase_set) {
            (Some(ssid), true) => Some(Ssid::new(ssid).map_err(invalid)?),
            (Some(_) | None, _) => None,
        };
        write.passphrase(held_for).map_err(invalid)?;
    }
    let mut body = Zeroizing::new(vec![0u8; MAX_PAYLOAD]);
    let len = write.encode(&mut body).map_err(invalid)?;
    body.truncate(len);
    Ok(body)
}

/// Cut `text` to `max` bytes without splitting a character, or `fallback` when
/// nothing is left.
fn fit_text(text: &str, max: usize, fallback: &str) -> String {
    let mut end = text.len().min(max);
    while !text.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    match text.get(..end) {
        Some(fitted) if !fitted.is_empty() => fitted.to_owned(),
        Some(_) | None => fallback.to_owned(),
    }
}

fn build(
    write: impl FnOnce(&mut [u8]) -> Result<usize, SetupFailure>,
) -> Result<Vec<u8>, SetupFailure> {
    let mut frame = vec![0u8; MAX_PAYLOAD];
    let len = write(&mut frame)?;
    frame.truncate(len);
    Ok(frame)
}

/// A frame this engine could not encode. Every input is bounded before it gets
/// here, so this is a defect rather than something a person can fix.
fn encoding<E>(_: E) -> SetupFailure {
    SetupFailure::ProtocolError
}

/// A reply that failed to decode or authenticate.
fn malformed<E>(_: E) -> SetupFailure {
    SetupFailure::ProtocolError
}

fn invalid<E>(_: E) -> SetupFailure {
    SetupFailure::InvalidConfig
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_wifi_is_capability_bit_8() {
        assert_eq!(
            km43::CapabilityBit::try_from(8),
            Ok(km43::CapabilityBit::WifiScanAndJoinStatus)
        );
        assert_eq!(REPORTS_WIFI, 1 << 8);
    }

    #[test]
    fn fits_text_on_character_boundaries() {
        let fit = |text: &str| fit_text(text, MAX_LABEL, FALLBACK_LABEL);
        assert_eq!(fit("kitchen phone"), "kitchen phone");
        assert_eq!(fit(""), FALLBACK_LABEL);
        assert_eq!(fit(&"a".repeat(40)), "a".repeat(32));
        // 31 ASCII bytes and a two-byte character: the character is dropped whole.
        let label = format!("{}é", "a".repeat(31));
        assert_eq!(fit(&label), "a".repeat(31));
    }

    #[test]
    fn network_change_debug_withholds_the_passphrase() {
        let change = NetworkChange {
            ssid: Some("cabin".to_owned()),
            passphrase: Some("correct horse battery".to_owned()),
            country: "CA".to_owned(),
            hostname: "origin89-cabin".to_owned(),
        };
        let rendered = format!("{change:?}");
        assert!(rendered.contains("withheld"));
        assert!(!rendered.contains("correct horse"));
    }
}
