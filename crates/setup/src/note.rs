//! What a KM43 frame says about itself, for a log a person reads on the bench.
//!
//! A note names the message type and `req_id`, and for an `Error 0xFF` the
//! code it carries. It never holds a payload, a key or a secret, and nothing in
//! it decides anything: the reply methods on [`Engine`] stay the only judges.

use km43::{Envelope, ErrorBody, Incoming, MessageType, SessionKey, Wrapper};

use crate::engine::Engine;

/// The code an `Error 0xFF` carries, and how far it can be believed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ErrorNote {
    /// A wrapped `Error` that verified under this link's session key.
    Verified {
        /// The code's name, such as `SessionExpired`.
        code: String,
    },
    /// A bare `Error`: a hint nobody authenticated (P-140).
    Bare {
        /// The code's name, as the sender gave it.
        code: String,
    },
    /// An `Error` whose code cannot be read here: a wrapper that does not
    /// verify under this link's session, or a body that does not decode.
    Unreadable,
}

/// The envelope of one KM43 frame.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FrameNote {
    /// The message type's name, such as `GetConfigResponse`.
    pub kind: String,
    /// The request this frame is or answers.
    pub req_id: u32,
    /// Present only for an `Error 0xFF`.
    pub error: Option<ErrorNote>,
}

impl Engine {
    /// Describe `frame` for a log, reading an `Error`'s code under the session
    /// open on this link. `None` for bytes that are not a KM43 envelope.
    #[must_use]
    pub fn frame_note(&self, frame: &[u8]) -> Option<FrameNote> {
        let header = Envelope::decode(frame).ok()?.header();
        let error = (header.kind == MessageType::ErrorResponse)
            .then(|| error_note(frame, self.session_key()));
        Some(FrameNote {
            kind: format!("{:?}", header.kind),
            req_id: header.req_id.0,
            error,
        })
    }
}

fn error_note(frame: &[u8], key: Option<&SessionKey>) -> ErrorNote {
    let wrapped = Envelope::decode(frame)
        .ok()
        .and_then(|envelope| Wrapper::decode(envelope).ok());
    if let Some(wrapper) = wrapped {
        return key
            .and_then(|key| wrapper.verify(key).ok())
            .and_then(|verified| ErrorBody::authenticated(verified.payload()).ok())
            .map_or(ErrorNote::Unreadable, |body| ErrorNote::Verified {
                code: code_name(body.code),
            });
    }
    Envelope::decode(frame)
        .ok()
        .and_then(|envelope| ErrorBody::from_envelope(envelope).ok())
        .map_or(ErrorNote::Unreadable, |hint| ErrorNote::Bare {
            code: code_name(hint.code()),
        })
}

fn code_name(code: Incoming) -> String {
    match code {
        Incoming::Client(code) => format!("{code:?}"),
        Incoming::LinkLocal(code) => format!("link {code:?}"),
        Incoming::Unknown(code) => format!("unknown code {code}"),
    }
}
