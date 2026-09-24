//! KM43's published `ble` action trace, replayed against [`BleCodec`].
//!
//! The trace drives km43's sender a fragment at a time, with backpressure: a
//! value is offered (`fragment`), offered again while the stack is busy, and
//! advanced only when admitted (`accepted`). [`BleCodec::fragments`] returns a
//! whole message's values at once, so the replay checks that every value the
//! trace admits is the next one the codec produced, in order, with the same
//! message ID. `busy` and `small_buffer` rows model a queue and a buffer the
//! codec does not expose and are checked only for consistency.

use std::collections::VecDeque;
use std::sync::Arc;

use origin89_setup::{BleCodec, BleFailure};
use serde_json::Value;

use km43::VECTORS_JSON as VECTORS;

struct Sending {
    values: VecDeque<Vec<u8>>,
    offered: bool,
}

struct Case {
    name: String,
    codec: Arc<BleCodec>,
    value_limit: u32,
    sending: Option<Sending>,
    messages: usize,
}

impl Case {
    fn new(row: &Row) -> Self {
        let codec = BleCodec::new();
        codec.set_mtu(row.mtu).unwrap();
        let derived = u32::from(row.mtu - 3).min(512);
        Self {
            name: row.expected.clone(),
            codec,
            value_limit: row.value_limit.unwrap_or(derived),
            sending: None,
            messages: 0,
        }
    }

    fn step(&mut self, row: &Row, at: usize) {
        let context = format!("{} row {at}: {} {}", self.name, row.action, row.expected);
        match (row.action.as_str(), row.expected.as_str()) {
            ("disconnect", "ok") => {
                self.codec.reset();
                self.sending = None;
            }
            ("enqueue", "ok") => {
                assert!(self.sending.is_none(), "{context}");
                let values = self.codec.fragments(&row.input, self.value_limit).unwrap();
                self.sending = Some(Sending {
                    values: values.into(),
                    offered: false,
                });
                self.messages += 1;
            }
            ("enqueue", "busy") => assert!(self.sending.is_some(), "{context}"),
            ("enqueue", "length") => assert_eq!(
                self.codec.fragments(&row.input, self.value_limit),
                Err(BleFailure::Length),
                "{context}"
            ),
            ("fragment", "ok") => {
                let sending = self.sending.as_mut().expect(&context);
                assert_eq!(sending.values.front(), Some(&row.output), "{context}");
                sending.offered = true;
            }
            ("fragment" | "small_buffer", "idle" | "buffer") => {}
            ("accepted", "ok") => {
                let sending = self.sending.as_mut().expect(&context);
                assert!(sending.offered, "{context}");
                sending.values.pop_front();
                sending.offered = false;
                if sending.values.is_empty() {
                    self.sending = None;
                }
            }
            ("accepted", "idle") => {
                assert!(
                    self.sending.as_ref().is_none_or(|s| !s.offered),
                    "{context}"
                );
            }
            ("receive", expected) => {
                let got = self.codec.receive(&row.input, row.now_ms);
                let want = match expected {
                    "pending" => Ok(None),
                    "message" => Ok(Some(row.output.clone())),
                    "sequence" => Err(BleFailure::Sequence),
                    "length" => Err(BleFailure::Length),
                    other => panic!("{context}: unknown receive outcome {other}"),
                };
                assert_eq!(got, want, "{context}");
            }
            ("expire", "ok") => self.codec.expire(row.now_ms),
            (action, expected) => panic!("{context}: unhandled {action} {expected}"),
        }
    }
}

struct Row {
    action: String,
    expected: String,
    mtu: u16,
    now_ms: u64,
    input: Vec<u8>,
    output: Vec<u8>,
    value_limit: Option<u32>,
}

fn rows() -> Vec<Row> {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let hex = |row: &Value, key: &str| hex::decode(row[key].as_str().unwrap()).unwrap();
    vectors["ble"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| Row {
            action: row["action"].as_str().unwrap().to_owned(),
            expected: row["expected"].as_str().unwrap().to_owned(),
            mtu: u16::try_from(row["mtu"].as_u64().unwrap()).unwrap(),
            now_ms: row["now_ms"].as_u64().unwrap(),
            input: hex(row, "input"),
            output: hex(row, "output"),
            value_limit: row
                .get("value_limit")
                .and_then(Value::as_u64)
                .map(|limit| u32::try_from(limit).unwrap()),
        })
        .collect()
}

#[test]
fn the_published_ble_trace_replays() {
    let mut cases = Vec::new();
    let mut case: Option<Case> = None;
    for (at, row) in rows().iter().enumerate() {
        if row.action == "reset" {
            cases.extend(case.take());
            case = Some(Case::new(row));
            continue;
        }
        case.as_mut()
            .expect("the trace opens with a reset")
            .step(row, at);
    }
    cases.extend(case);

    let names: Vec<&str> = cases.iter().map(|case| case.name.as_str()).collect();
    for expected in [
        "full_payload_and_backpressure",
        "selected_value_limit_and_backpressure",
        "missing_fragment",
        "duplicate",
        "out_of_order",
        "changed_id_zero_restarts_immediately",
        "timeout_boundary_and_refresh",
        "timer_without_traffic",
        "clock_regression_discards",
        "disconnect_discards_both_directions",
        "malformed_values",
        "index_exhaustion",
        "last_index_is_legal_when_final",
        "payload_overflow",
        "transmit_refusals_preserve_id",
        "ordered_wrap_under_backpressure",
    ] {
        assert!(names.contains(&expected), "the trace lost {expected}");
    }
    let sent: usize = cases.iter().map(|case| case.messages).sum();
    assert_eq!(
        sent, 271,
        "every enqueued message was fragmented by the codec"
    );
    for case in &cases {
        assert!(
            case.sending.is_none(),
            "{} left a message half admitted",
            case.name
        );
    }
}
