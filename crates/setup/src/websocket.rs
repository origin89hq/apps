//! Where a client reaches the KM43 WebSocket on the site network: the address
//! the controller reports in `WifiStatus` or advertises over DNS-SD (P-224), at
//! `WS_PORT` and `WS_PATH` (P-223). Every candidate address still needs
//! `Discover` before use (P-225).

use core::net::Ipv4Addr;

use km43::{DNSSD_SERVICE, DNSSD_TXT_DEVICE_ID, MAX_PAYLOAD, WS_PATH, WS_PORT};

/// The WebSocket URL for a controller at `ipv4`, in dotted-decimal form, or
/// `None` when it is not a unicast IPv4 address.
#[uniffi::export]
#[must_use]
pub fn web_socket_url(ipv4: &str) -> Option<String> {
    let address: Ipv4Addr = ipv4.parse().ok()?;
    if address.is_unspecified() || address.is_broadcast() || address.is_multicast() {
        return None;
    }
    Some(format!("ws://{address}:{WS_PORT}{WS_PATH}"))
}

/// The largest KM43 message in bytes. A binary WebSocket frame carries one
/// message (P-034), so a larger frame is not one.
#[uniffi::export]
#[must_use]
pub fn max_message_bytes() -> u32 {
    // 1024: it fits.
    u32::try_from(MAX_PAYLOAD).unwrap_or(u32::MAX)
}

/// The DNS-SD service type a controller advertises in `local.` (P-224).
#[uniffi::export]
#[must_use]
pub fn dnssd_service() -> String {
    DNSSD_SERVICE.to_owned()
}

/// The TXT key whose value is the advertising controller's `device_id`. It is
/// unauthenticated: an instance that names a controller is only a candidate.
#[uniffi::export]
#[must_use]
pub fn dnssd_txt_device_id() -> String {
    DNSSD_TXT_DEVICE_ID.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reported_address_names_km43s_port_and_path() {
        assert_eq!(
            web_socket_url("192.168.1.42").as_deref(),
            Some("ws://192.168.1.42:80/km43")
        );
    }

    #[test]
    fn text_that_is_not_an_ipv4_address_is_refused() {
        for text in [
            "",
            "controller.local",
            "192.168.1",
            "192.168.1.256",
            "::1",
            " 10.0.0.1",
        ] {
            assert_eq!(web_socket_url(text), None, "{text:?}");
        }
    }

    #[test]
    fn the_browsed_service_and_txt_key_are_km43s() {
        assert_eq!(dnssd_service(), "_km43._tcp");
        assert_eq!(dnssd_txt_device_id(), "id");
    }

    #[test]
    fn the_message_bound_is_km43s_payload() {
        assert_eq!(max_message_bytes(), 1024);
    }

    #[test]
    fn leading_zeros_are_refused_rather_than_read_as_octal() {
        assert_eq!(web_socket_url("010.0.0.1"), None);
    }

    #[test]
    fn addresses_no_controller_holds_are_refused() {
        for text in ["0.0.0.0", "255.255.255.255", "224.0.0.251"] {
            assert_eq!(web_socket_url(text), None, "{text:?}");
        }
    }
}
