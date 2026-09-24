//! KM43 message fragmentation over BLE GATT (P-036, P-037, P-039), wrapping
//! km43's `BleSender` and `BleReceiver` for a `CoreBluetooth` transport that
//! never interprets the bytes it carries.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use km43::{
    BLE_MAX_MTU, BLE_MAX_VALUE, BLE_RX_UUID, BLE_SERVICE_UUID, BLE_TX_UUID, BleError, BleMtu,
    BleReceiver, BleSender, BleValueLimit,
};

/// Why a message could not be fragmented or a fragment could not be taken.
/// Every case means the connection's assembly or queue was discarded; a
/// transport treats it as the connection dropping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum BleFailure {
    /// An ATT MTU outside 23 through 517.
    #[error("the ATT MTU is outside 23 through 517")]
    Mtu,
    /// A value limit outside 20 through 512 bytes (P-037).
    #[error("the value limit is outside 20 through 512 bytes")]
    ValueLimit,
    /// An empty or oversized message, a fragment shorter than three bytes or
    /// above the receive bound, or an assembly that would pass `MAX_PAYLOAD` or
    /// index 127 without `last` (P-036).
    #[error("a message or fragment has an invalid length")]
    Length,
    /// A missing, duplicate or out-of-order fragment (P-039).
    #[error("a fragment arrived out of sequence")]
    Sequence,
    /// A second message offered while one is queued. [`BleCodec::fragments`]
    /// drains every message it takes, so it does not report this.
    #[error("a message is already queued")]
    Busy,
    /// An output buffer too small for a fragment; not reached through
    /// [`BleCodec`], whose buffer holds the largest value.
    #[error("the fragment buffer is too small")]
    Buffer,
    /// No message queued; not reached through [`BleCodec`].
    #[error("no message is queued")]
    Idle,
}

impl From<BleError> for BleFailure {
    fn from(why: BleError) -> Self {
        match why {
            BleError::Mtu => Self::Mtu,
            BleError::ValueLimit => Self::ValueLimit,
            BleError::Length => Self::Length,
            BleError::Sequence => Self::Sequence,
            BleError::Busy => Self::Busy,
            BleError::Buffer => Self::Buffer,
            BleError::Idle => Self::Idle,
        }
    }
}

/// The GATT identifiers, as canonical UUID text for platform APIs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BluetoothIdentifiers {
    /// The primary service, advertised by the controller.
    pub service: String,
    /// Client to controller, Write Without Response.
    pub rx: String,
    /// Controller to client, Notify.
    pub tx: String,
}

/// The KM43 GATT service and characteristic UUIDs.
#[uniffi::export]
#[must_use]
pub fn bluetooth_identifiers() -> BluetoothIdentifiers {
    BluetoothIdentifiers {
        service: BLE_SERVICE_UUID.to_owned(),
        rx: BLE_RX_UUID.to_owned(),
        tx: BLE_TX_UUID.to_owned(),
    }
}

struct Directions {
    sender: BleSender,
    receiver: BleReceiver,
    /// Checked by [`BleCodec::set_mtu`]. It starts at the largest supported
    /// MTU so that a transport that never learns the negotiated one still
    /// accepts every legal notification; `MAX_PAYLOAD` bounds the assembly
    /// whatever the MTU.
    receive_mtu: u16,
}

/// One connection's fragmenter and reassembler. Both directions start over on
/// a new connection, so make one per connection or call [`BleCodec::reset`].
#[derive(uniffi::Object)]
pub struct BleCodec {
    directions: Mutex<Directions>,
}

#[uniffi::export]
impl BleCodec {
    /// A codec for a fresh connection: both message IDs at zero, nothing
    /// assembled, receive bound at the largest MTU.
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            directions: Mutex::new(Directions {
                sender: BleSender::new(),
                receiver: BleReceiver::new(),
                receive_mtu: BLE_MAX_MTU,
            }),
        })
    }

    /// Discard both directions, as a disconnect does (P-039): the partial
    /// assembly goes and the next message ID is zero. The receive bound stays.
    pub fn reset(&self) {
        let mut directions = self.directions();
        directions.sender.reset();
        directions.receiver.reset();
    }

    /// Bound received values by the negotiated ATT MTU (P-037, step 2).
    pub fn set_mtu(&self, mtu: u16) -> Result<(), BleFailure> {
        BleMtu::new(mtu)?;
        self.directions().receive_mtu = mtu;
        Ok(())
    }

    /// Every fragment value for one KM43 message, in order, each at most
    /// `value_limit` bytes including the two KM43 bytes (P-036, P-037).
    ///
    /// The limit is frozen for the whole message. The message ID advances once
    /// all of its fragments are returned, which models them all entering the
    /// ordered transmit path; a transport that cannot send them all closes the
    /// connection and calls [`BleCodec::reset`].
    pub fn fragments(&self, message: &[u8], value_limit: u32) -> Result<Vec<Vec<u8>>, BleFailure> {
        let limit = usize::try_from(value_limit).map_err(|_| BleFailure::ValueLimit)?;
        let limit = BleValueLimit::new(limit)?;
        let mut directions = self.directions();
        let sender = &mut directions.sender;
        sender.enqueue(message, limit)?;
        let drained = drain(sender);
        if drained.is_err() {
            sender.reset();
        }
        drained
    }

    /// Take one notified value. Returns the assembled message when its last
    /// fragment arrives. `now_ms` is monotonic milliseconds; an assembly idle
    /// for 5000 ms or more, or a clock that went backwards, discards it first.
    pub fn receive(&self, fragment: &[u8], now_ms: u64) -> Result<Option<Vec<u8>>, BleFailure> {
        let mut directions = self.directions();
        let mtu = BleMtu::new(directions.receive_mtu)?;
        let assembled = directions.receiver.receive(fragment, mtu, now_ms)?;
        Ok(assembled.map(<[u8]>::to_vec))
    }

    /// Run the reassembly timer without a fragment (P-039, step 1).
    pub fn expire(&self, now_ms: u64) {
        self.directions().receiver.expire(now_ms);
    }
}

impl BleCodec {
    /// Every step leaves km43's sender and receiver consistent, so a poisoned
    /// lock is recovered rather than propagated.
    fn directions(&self) -> MutexGuard<'_, Directions> {
        self.directions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

/// Offer and admit every fragment of the queued message.
fn drain(sender: &mut BleSender) -> Result<Vec<Vec<u8>>, BleFailure> {
    let mut values = Vec::new();
    let mut value = [0u8; BLE_MAX_VALUE];
    // Index 127 is the last a message may use, so 128 offers always finish it.
    for _ in 0..=km43::BLE_INDEX_MASK {
        match sender.fragment(&mut value) {
            Ok(len) => {
                values.push(value.get(..len).ok_or(BleFailure::Buffer)?.to_vec());
                sender.accepted()?;
            }
            Err(BleError::Idle) => return Ok(values),
            Err(why) => return Err(why.into()),
        }
    }
    match sender.fragment(&mut value) {
        Err(BleError::Idle) => Ok(values),
        Ok(_) => Err(BleFailure::Length),
        Err(why) => Err(why.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_km43s() {
        let ids = bluetooth_identifiers();
        assert_eq!(ids.service, "ab43e89a-7c21-4a5d-9b62-19e430000001");
        assert_eq!(ids.rx, "ab43e89a-7c21-4a5d-9b62-19e430000002");
        assert_eq!(ids.tx, "ab43e89a-7c21-4a5d-9b62-19e430000003");
    }

    #[test]
    fn a_full_payload_takes_57_fragments_at_the_minimum_mtu() {
        let codec = BleCodec::new();
        let values = codec.fragments(&[0x5a; 1024], 20).unwrap();
        assert_eq!(values.len(), 57);
        assert!(values.iter().all(|value| value.len() <= 20));
        assert_eq!(values[56][1], 0x80 | 0x38);
        let receiver = BleCodec::new();
        receiver.set_mtu(23).unwrap();
        let mut assembled = None;
        for value in &values {
            assembled = receiver.receive(value, 0).unwrap();
        }
        assert_eq!(assembled.unwrap(), vec![0x5a; 1024]);
    }

    #[test]
    fn refused_messages_do_not_advance_the_id() {
        let codec = BleCodec::new();
        assert_eq!(codec.fragments(&[], 20).unwrap_err(), BleFailure::Length);
        assert_eq!(
            codec.fragments(&[0; 1025], 20).unwrap_err(),
            BleFailure::Length
        );
        assert_eq!(
            codec.fragments(&[1], 19).unwrap_err(),
            BleFailure::ValueLimit
        );
        assert_eq!(
            codec.fragments(&[1], 513).unwrap_err(),
            BleFailure::ValueLimit
        );
        assert_eq!(codec.fragments(&[7], 20).unwrap(), vec![vec![0, 0x80, 7]]);
        assert_eq!(codec.fragments(&[8], 20).unwrap(), vec![vec![1, 0x80, 8]]);
    }

    #[test]
    fn the_message_id_wraps_and_resets() {
        let codec = BleCodec::new();
        for id in 0..=255u8 {
            assert_eq!(codec.fragments(&[id], 20).unwrap()[0][0], id);
        }
        assert_eq!(codec.fragments(&[0], 20).unwrap()[0][0], 0);
        codec.fragments(&[0], 20).unwrap();
        codec.reset();
        assert_eq!(codec.fragments(&[0], 20).unwrap()[0][0], 0);
    }

    #[test]
    fn the_receive_bound_follows_the_mtu() {
        let codec = BleCodec::new();
        assert_eq!(codec.set_mtu(22).unwrap_err(), BleFailure::Mtu);
        assert_eq!(codec.set_mtu(518).unwrap_err(), BleFailure::Mtu);
        let mut value = vec![0, 0x80];
        value.extend([1; 21]);
        // 23 bytes: legal at the default bound, above MTU 23's 20.
        assert_eq!(codec.receive(&value, 0).unwrap(), Some(vec![1; 21]));
        codec.set_mtu(23).unwrap();
        assert_eq!(codec.receive(&value, 0).unwrap_err(), BleFailure::Length);
    }

    #[test]
    fn expiry_runs_without_traffic() {
        let codec = BleCodec::new();
        assert_eq!(codec.receive(&[0, 0, 1], 0).unwrap(), None);
        codec.expire(5000);
        // The assembly is gone, so index 1 cannot continue it.
        assert_eq!(
            codec.receive(&[0, 0x81, 2], 5000).unwrap_err(),
            BleFailure::Sequence
        );
    }
}
