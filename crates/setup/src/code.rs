//! The P-049 setup code printed on a controller as a QR code.

use core::fmt;
use core::str::FromStr;

use km43::{DeviceId, DeviceSecret, PrintedSecret};
use zeroize::Zeroizing;

/// The exact length of a P-049 payload: `4 + 1 + 1 + 1 + 32 + 1 + 64`.
pub const SETUP_CODE_LEN: usize = 104;

const DEVICE_ID_BYTES: usize = 16;
const SECRET_BYTES: usize = 32;

const PREFIX: &[u8] = b"km43";
const VERSION: u8 = b'1';
const SEPARATOR: u8 = b':';

// Byte offsets inside the 104-character payload.
const PREFIX_END: usize = 4;
const VERSION_AT: usize = 5;
const DEVICE_ID_AT: usize = 7;
const DEVICE_ID_END: usize = DEVICE_ID_AT + 2 * DEVICE_ID_BYTES;
const SECRET_AT: usize = DEVICE_ID_END + 1;
const SEPARATORS: [usize; 3] = [PREFIX_END, VERSION_AT + 1, DEVICE_ID_END];

const _: () = assert!(SECRET_AT + 2 * SECRET_BYTES == SETUP_CODE_LEN);

/// Which hex field of the payload a [`SetupCodeError::NotLowercaseHex`] names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeField {
    /// The 32-character `device_id`.
    DeviceId,
    /// The 64-character `printed_secret`.
    PrintedSecret,
}

impl fmt::Display for CodeField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::DeviceId => "device_id",
            Self::PrintedSecret => "printed_secret",
        })
    }
}

/// Why a scanned or pasted payload is not a setup code. P-049 refuses every one
/// of these shapes; nothing is paired from a partial parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum SetupCodeError {
    /// Not exactly [`SETUP_CODE_LEN`] bytes, which includes surrounding whitespace.
    #[error("setup code is {len} bytes, not {SETUP_CODE_LEN}")]
    Length {
        /// The length received, in bytes.
        len: u64,
    },
    /// Does not start with the literal `km43`.
    #[error("setup code does not start with km43")]
    Prefix,
    /// A payload version other than `1`.
    #[error("setup code is not payload version 1")]
    Version,
    /// A `:` missing where P-049 puts one.
    #[error("setup code fields are not separated by ':'")]
    Separator,
    /// A field holding anything but lowercase hexadecimal, uppercase included.
    #[error("setup code {field} is not lowercase hexadecimal")]
    NotLowercaseHex {
        /// The field that failed.
        field: CodeField,
    },
}

/// The controller's 16-byte `device_id` (P-038).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControllerId([u8; DEVICE_ID_BYTES]);

impl ControllerId {
    /// The raw identifier, as `Discover 0x80` carries it.
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; DEVICE_ID_BYTES] {
        &self.0
    }
}

impl From<[u8; DEVICE_ID_BYTES]> for ControllerId {
    fn from(bytes: [u8; DEVICE_ID_BYTES]) -> Self {
        Self(bytes)
    }
}

/// 32 lowercase hexadecimal characters, the form P-049 prints.
impl fmt::Display for ControllerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.iter().try_for_each(|byte| write!(f, "{byte:02x}"))
    }
}

/// A parsed setup code: the controller's identity and its printed secret.
///
/// The secret is never exposed: it is zeroed when the code is dropped, it has no
/// accessor, and `Debug` does not render it. The engine drops the code once the
/// controller has enrolled this client.
pub struct SetupCode {
    device_id: ControllerId,
    secret: Zeroizing<[u8; SECRET_BYTES]>,
}

impl SetupCode {
    /// Parse a P-049 payload, refusing anything that is not exactly that shape.
    pub fn parse(text: &str) -> Result<Self, SetupCodeError> {
        let bytes = text.as_bytes();
        if bytes.len() != SETUP_CODE_LEN {
            return Err(SetupCodeError::Length {
                len: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
            });
        }
        if bytes.get(..PREFIX_END) != Some(PREFIX) {
            return Err(SetupCodeError::Prefix);
        }
        if SEPARATORS
            .iter()
            .any(|&at| bytes.get(at) != Some(&SEPARATOR))
        {
            return Err(SetupCodeError::Separator);
        }
        if bytes.get(VERSION_AT) != Some(&VERSION) {
            return Err(SetupCodeError::Version);
        }
        let mut device_id = [0u8; DEVICE_ID_BYTES];
        decode_hex(
            bytes.get(DEVICE_ID_AT..DEVICE_ID_END),
            &mut device_id,
            CodeField::DeviceId,
        )?;
        let mut secret = Zeroizing::new([0u8; SECRET_BYTES]);
        decode_hex(
            bytes.get(SECRET_AT..),
            secret.as_mut(),
            CodeField::PrintedSecret,
        )?;
        Ok(Self {
            device_id: ControllerId(device_id),
            secret,
        })
    }

    /// The controller this code was printed for.
    #[must_use]
    pub const fn device_id(&self) -> ControllerId {
        self.device_id
    }

    /// The KDF input km43 derives the pairing and client keys from.
    ///
    /// km43's own copy is not zeroed on drop, so callers keep it for the one
    /// derivation they need and no longer.
    pub(crate) fn device_secret(&self) -> DeviceSecret {
        DeviceSecret::new(
            DeviceId::new(self.device_id.0),
            PrintedSecret::new(*self.secret),
        )
    }
}

impl FromStr for SetupCode {
    type Err = SetupCodeError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        Self::parse(text)
    }
}

impl fmt::Debug for SetupCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "SetupCode {{ device_id: {}, printed_secret: withheld }}",
            self.device_id
        )
    }
}

/// Parse a P-049 payload. The same as [`SetupCode::parse`].
pub fn parse_setup_code(text: &str) -> Result<SetupCode, SetupCodeError> {
    SetupCode::parse(text)
}

fn decode_hex(src: Option<&[u8]>, dst: &mut [u8], field: CodeField) -> Result<(), SetupCodeError> {
    let refused = SetupCodeError::NotLowercaseHex { field };
    let src = src.ok_or(refused)?;
    if src.len() != dst.len() * 2 {
        return Err(refused);
    }
    let (pairs, rest) = src.as_chunks::<2>();
    if !rest.is_empty() {
        return Err(refused);
    }
    for (out, [high, low]) in dst.iter_mut().zip(pairs) {
        *out = (nibble(*high).ok_or(refused)? << 4) | nibble(*low).ok_or(refused)?;
    }
    Ok(())
}

const fn nibble(digit: u8) -> Option<u8> {
    match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = "km43:1:4f524947494e38392044454d4f203031:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    fn with(at: usize, byte: u8) -> String {
        let mut bytes = VALID.as_bytes().to_vec();
        bytes[at] = byte;
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn parses_the_published_payload() {
        let code = SetupCode::parse(VALID).unwrap();
        assert_eq!(
            code.device_id().to_string(),
            "4f524947494e38392044454d4f203031"
        );
        assert_eq!(code.secret[0], 0x00);
        assert_eq!(code.secret[31], 0x1f);
    }

    #[test]
    fn debug_never_renders_the_secret() {
        let rendered = format!("{:?}", SetupCode::parse(VALID).unwrap());
        assert!(rendered.contains("withheld"));
        assert!(!rendered.contains("000102030405"));
    }

    #[test]
    fn refuses_wrong_lengths() {
        assert_eq!(
            SetupCode::parse("").unwrap_err(),
            SetupCodeError::Length { len: 0 }
        );
        assert_eq!(
            SetupCode::parse(&format!("{VALID}\n")).unwrap_err(),
            SetupCodeError::Length { len: 105 }
        );
        assert_eq!(
            SetupCode::parse(&format!(" {VALID}")).unwrap_err(),
            SetupCodeError::Length { len: 105 }
        );
        assert_eq!(
            SetupCode::parse(&VALID[..103]).unwrap_err(),
            SetupCodeError::Length { len: 103 }
        );
        // A bare secret is never accepted in place of the whole payload.
        assert_eq!(
            SetupCode::parse(&VALID[40..]).unwrap_err(),
            SetupCodeError::Length { len: 64 }
        );
    }

    #[test]
    fn refuses_a_wrong_prefix() {
        assert_eq!(
            SetupCode::parse(&VALID.replacen("km43", "KM43", 1)).unwrap_err(),
            SetupCodeError::Prefix
        );
        assert_eq!(
            SetupCode::parse(&with(0, b'x')).unwrap_err(),
            SetupCodeError::Prefix
        );
    }

    #[test]
    fn refuses_a_wrong_version() {
        assert_eq!(
            SetupCode::parse(&with(5, b'2')).unwrap_err(),
            SetupCodeError::Version
        );
        assert_eq!(
            SetupCode::parse(&with(5, b'0')).unwrap_err(),
            SetupCodeError::Version
        );
    }

    #[test]
    fn refuses_a_missing_separator() {
        for at in SEPARATORS {
            assert_eq!(
                SetupCode::parse(&with(at, b';')).unwrap_err(),
                SetupCodeError::Separator,
                "separator at {at}"
            );
        }
    }

    #[test]
    fn refuses_non_hex_in_either_field() {
        assert_eq!(
            SetupCode::parse(&with(DEVICE_ID_AT, b'g')).unwrap_err(),
            SetupCodeError::NotLowercaseHex {
                field: CodeField::DeviceId
            }
        );
        assert_eq!(
            SetupCode::parse(&with(SETUP_CODE_LEN - 1, b' ')).unwrap_err(),
            SetupCodeError::NotLowercaseHex {
                field: CodeField::PrintedSecret
            }
        );
    }

    #[test]
    fn refuses_uppercase_hex() {
        assert_eq!(
            SetupCode::parse(&with(DEVICE_ID_AT, b'F')).unwrap_err(),
            SetupCodeError::NotLowercaseHex {
                field: CodeField::DeviceId
            }
        );
        assert_eq!(
            SetupCode::parse(&with(SECRET_AT + 3, b'A')).unwrap_err(),
            SetupCodeError::NotLowercaseHex {
                field: CodeField::PrintedSecret
            }
        );
    }

    #[test]
    fn counts_bytes_not_characters() {
        // 104 characters, 105 bytes: one of them is two bytes of UTF-8.
        let mut text = VALID[..103].to_owned();
        text.push('é');
        assert_eq!(
            SetupCode::parse(&text).unwrap_err(),
            SetupCodeError::Length { len: 105 }
        );
    }
}
