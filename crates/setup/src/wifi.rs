//! What the controller reports about Wi-Fi: the networks its radio heard and
//! what the radio did with the network it was given (P-216 to P-221).
//!
//! Both are the comms processor's account of itself (P-221). They are shown
//! to a person and nothing here grants or decides anything on them.

use std::net::Ipv4Addr;

use km43::{
    AccessPoint, Radio, RadioReport, ScanAnswer, ScanRefusal as Refusal, ScanState, WifiBand,
    WifiFailure as Failure, WifiSecurity, WifiStatus as Status,
};

use crate::engine::SetupFailure;

/// How a network protects itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NetworkSecurity {
    /// No passphrase. The network section cannot join it.
    Open,
    /// WPA2 Personal.
    Wpa2Personal,
    /// WPA3 Personal.
    Wpa3Personal,
    /// Anything else, such as enterprise. The network section cannot join it.
    Other,
}

impl NetworkSecurity {
    /// Whether the network section can join a network secured this way: it
    /// always carries a WPA passphrase (L-131).
    #[must_use]
    pub const fn is_joinable(self) -> bool {
        match self {
            Self::Wpa2Personal | Self::Wpa3Personal => true,
            Self::Open | Self::Other => false,
        }
    }
}

impl From<WifiSecurity> for NetworkSecurity {
    fn from(security: WifiSecurity) -> Self {
        match security {
            WifiSecurity::Open => Self::Open,
            WifiSecurity::Wpa2Personal => Self::Wpa2Personal,
            WifiSecurity::Wpa3Personal => Self::Wpa3Personal,
            WifiSecurity::Other => Self::Other,
        }
    }
}

/// The band a network was heard on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NetworkBand {
    /// 2.4 GHz.
    Ghz24,
    /// 5 GHz.
    Ghz5,
    /// 6 GHz.
    Ghz6,
}

impl From<WifiBand> for NetworkBand {
    fn from(band: WifiBand) -> Self {
        match band {
            WifiBand::Ghz24 => Self::Ghz24,
            WifiBand::Ghz5 => Self::Ghz5,
            WifiBand::Ghz6 => Self::Ghz6,
        }
    }
}

/// One network the radio heard: the strongest access point for its SSID.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeardNetwork {
    /// 1 to 32 bytes. A hidden network is never listed.
    pub ssid: String,
    /// Signal strength in dBm.
    pub rssi: i8,
    /// How the network is secured.
    pub security: NetworkSecurity,
    /// The band it was heard on.
    pub band: NetworkBand,
    /// The channel within `band`.
    pub channel: u8,
}

impl From<AccessPoint<'_>> for HeardNetwork {
    fn from(row: AccessPoint<'_>) -> Self {
        Self {
            ssid: row.ssid.to_owned(),
            rssi: row.rssi,
            security: row.security.into(),
            band: row.band.into(),
            channel: row.channel,
        }
    }
}

/// The state of the most recent scan (P-217).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanProgress {
    /// No scan since the controller booted.
    None,
    /// A scan is running; ask again for its list.
    Running,
    /// The last scan completed; its list is the one held.
    Complete,
    /// The last scan failed; any list held is from an earlier one.
    Failed,
}

impl From<ScanState> for ScanProgress {
    fn from(state: ScanState) -> Self {
        match state {
            ScanState::None => Self::None,
            ScanState::Running => Self::Running,
            ScanState::Complete => Self::Complete,
            ScanState::Failed => Self::Failed,
        }
    }
}

/// Why a refresh started no scan (P-218).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanRefusal {
    /// A scan ran in the last ten seconds.
    TooSoon,
    /// The network section was never written, so the radio is off.
    RadioOff,
    /// The controller cannot reach its comms processor.
    LinkDown,
    /// This client may not start a scan.
    Unauthorised,
}

impl From<Refusal> for ScanRefusal {
    fn from(refusal: Refusal) -> Self {
        match refusal {
            Refusal::TooSoon => Self::TooSoon,
            Refusal::RadioOff => Self::RadioOff,
            Refusal::LinkDown => Self::LinkDown,
            Refusal::Unauthorised => Self::Unauthorised,
        }
    }
}

/// The networks from the most recent completed scan.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HeardNetworks {
    /// How long the controller has held this list, in milliseconds.
    pub age_ms: u32,
    /// Strongest first, one per SSID, at most 16.
    pub networks: Vec<HeardNetwork>,
    /// Networks heard and left out of `networks`.
    pub unlisted: u16,
}

/// `WifiScan 0x91`: the scan's state, why a refresh was refused, and the list
/// held. No list and an empty list are different answers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NetworkScan {
    /// The state of the most recent scan.
    pub progress: ScanProgress,
    /// Present only when a refresh was asked for and started nothing.
    pub refused: Option<ScanRefusal>,
    /// Absent when no scan has completed since the controller booted.
    pub heard: Option<HeardNetworks>,
}

impl NetworkScan {
    pub(crate) fn read(payload: &[u8]) -> Result<Self, SetupFailure> {
        let answer = ScanAnswer::decode(payload).map_err(|_| SetupFailure::ProtocolError)?;
        let heard = answer
            .held()
            .map(|held| {
                let networks = held
                    .list
                    .iter()
                    .map(|row| row.map(HeardNetwork::from))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|_| SetupFailure::ProtocolError)?;
                Ok(HeardNetworks {
                    age_ms: held.age_ms,
                    networks,
                    unlisted: held.list.unlisted(),
                })
            })
            .transpose()?;
        Ok(Self {
            progress: answer.scan().into(),
            refused: answer.refused().map(ScanRefusal::from),
            heard,
        })
    }
}

/// Why the radio is not joined.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum JoinFailure {
    /// The network refused the passphrase.
    AuthFailed,
    /// The network was not heard.
    NotFound,
    /// Joined, but no address was assigned.
    NoIp,
    /// Joined, then lost.
    Lost,
    /// Anything else.
    Other,
}

impl From<Failure> for JoinFailure {
    fn from(failure: Failure) -> Self {
        match failure {
            Failure::AuthFailed => Self::AuthFailed,
            Failure::NotFound => Self::NotFound,
            Failure::NoIp => Self::NoIp,
            Failure::Lost => Self::Lost,
            Failure::Other => Self::Other,
        }
    }
}

/// What the radio is doing with the network it holds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RadioState {
    /// Holds no network, or no country, and is not trying.
    Off,
    /// Trying, with no outcome yet.
    Joining,
    /// Joined.
    Joined {
        /// The IPv4 address the network assigned, dotted.
        address: String,
    },
    /// Not joined and still trying; this was the most recent failure.
    Failed {
        /// Why.
        reason: JoinFailure,
    },
}

impl From<Radio> for RadioState {
    fn from(radio: Radio) -> Self {
        match radio {
            Radio::Off => Self::Off,
            Radio::Joining => Self::Joining,
            Radio::Joined { ipv4 } => Self::Joined {
                address: Ipv4Addr::from(ipv4).to_string(),
            },
            Radio::Failed { reason } => Self::Failed {
                reason: reason.into(),
            },
        }
    }
}

/// The comms processor's latest report.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RadioStatus {
    /// The network section version the radio is acting on.
    pub version: u32,
    /// What it is doing with it.
    pub state: RadioState,
}

impl From<RadioReport> for RadioStatus {
    fn from(report: RadioReport) -> Self {
        Self {
            version: report.version,
            state: report.radio.into(),
        }
    }
}

/// `WifiStatus 0x92`: the section version the controller holds beside the
/// version the radio is acting on, so a client can tell the result of its own
/// write from an earlier one (P-219).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WifiStatus {
    /// The network section's version; 0 when never written.
    pub section: u32,
    /// Absent after link loss or a comms reboot, until the radio reports.
    pub radio: Option<RadioStatus>,
}

impl WifiStatus {
    pub(crate) fn read(payload: &[u8]) -> Result<Self, SetupFailure> {
        let status = Status::decode(payload).map_err(|_| SetupFailure::ProtocolError)?;
        Ok(Self {
            section: status.section,
            radio: status.report.map(RadioStatus::from),
        })
    }

    /// The radio's state when it is acting on `version`, the section version
    /// a write produced; `None` while it reports on another one or not at all.
    #[must_use]
    pub fn state_for(&self, version: u32) -> Option<&RadioState> {
        self.radio
            .as_ref()
            .filter(|radio| radio.version == version)
            .map(|radio| &radio.state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(radio: Option<(u32, RadioState)>) -> WifiStatus {
        WifiStatus {
            section: 2,
            radio: radio.map(|(version, state)| RadioStatus { version, state }),
        }
    }

    #[test]
    fn state_for_answers_only_for_the_version_asked() {
        let joined = RadioState::Joined {
            address: "192.168.1.42".to_owned(),
        };
        assert_eq!(
            status(Some((2, joined.clone()))).state_for(2),
            Some(&joined)
        );
        assert_eq!(status(Some((1, joined))).state_for(2), None);
        assert_eq!(status(None).state_for(2), None);
    }

    #[test]
    fn only_wpa_personal_is_joinable() {
        assert!(NetworkSecurity::Wpa2Personal.is_joinable());
        assert!(NetworkSecurity::Wpa3Personal.is_joinable());
        assert!(!NetworkSecurity::Open.is_joinable());
        assert!(!NetworkSecurity::Other.is_joinable());
    }
}
