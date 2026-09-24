//! The setup exchange against KM43's published vectors.
//!
//! Where a vector covers a frame, the frame this client builds is compared
//! with it byte for byte. Where no vector covers a controller reply, the reply
//! is built with km43's controller-side API, which is what the controller
//! firmware links.

use std::collections::VecDeque;
use std::sync::OnceLock;

use km43::{
    Caps, CborReader, CborWriter, ClientId, ConfigAnswer, ConfigSection, Counter, DeviceId,
    DeviceSecret, Discovery, Enrolment, Envelope, Epoch, ErrorBody, ErrorCode, Handshake, Header,
    HelloClaim, HelloReport, Incoming, LogSeq, MAX_PAYLOAD, MessageType, Outcome, PairClaim,
    PairResponse, PrintedSecret, ReqId, SessionId, SessionKey, SetConfig, SetConfigAck,
    SignedClaim, StateSeq, Tagged, Time, TimeAck, Topology, Version, Wrapper,
};
use origin89_setup::{
    Engine, ErrorNote, FrameNote, HeardNetwork, JoinFailure, NetworkBand, NetworkChange,
    NetworkScan, NetworkSecurity, NetworkSettings, NonceSource, RadioState, RadioStatus,
    ScanProgress, ScanRefusal, SetupCode, SetupFailure, SetupSession, WifiStatus,
};
use serde_json::Value;

use km43::VECTORS_JSON as VECTORS;

fn vectors() -> &'static Value {
    static PARSED: OnceLock<Value> = OnceLock::new();
    PARSED.get_or_init(|| serde_json::from_str(VECTORS).expect("v1.json parses"))
}

fn text(pointer: &str) -> &'static str {
    vectors()
        .pointer(pointer)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("v1.json has no string at {pointer}"))
}

fn bytes(pointer: &str) -> Vec<u8> {
    hex::decode(text(pointer)).expect("vector is hex")
}

fn b16(pointer: &str) -> [u8; 16] {
    bytes(pointer).try_into().expect("16 bytes")
}

const HANDLE: u16 = 3;
const CLIENT_ID: u32 = 7;
const HELLO_COUNTER: u64 = 65;
const AT: u64 = 1_700_000_000_000;

/// Nonces handed out in order; the vectors use one client nonce throughout.
struct Fixed(VecDeque<[u8; 16]>);

impl NonceSource for Fixed {
    fn nonce(&mut self) -> Option<[u8; 16]> {
        self.0.pop_front()
    }
}

fn nonces(count: usize) -> Box<dyn NonceSource> {
    Box::new(Fixed(
        std::iter::repeat_n(b16("/inputs/client_nonce"), count).collect(),
    ))
}

fn code() -> SetupCode {
    SetupCode::parse(text("/qr/payload")).expect("the published payload parses")
}

fn engine() -> Engine {
    Engine::new(code(), text("/inputs/label"), "o89-cli 0.1.0", nonces(8))
}

fn handle() -> SessionId {
    SessionId::from(HANDLE)
}

fn buffer() -> Vec<u8> {
    vec![0u8; MAX_PAYLOAD]
}

fn finished(mut frame: Vec<u8>, len: usize) -> Vec<u8> {
    frame.truncate(len);
    frame
}

/// The controller's side of the exchange, built from km43's own types.
struct Controller {
    secret: DeviceSecret,
    device_id: [u8; 16],
    epoch: Epoch,
    challenge: [u8; 16],
    session: Option<(SessionKey, ClientId)>,
    capabilities: u32,
}

impl Controller {
    fn new() -> Self {
        let device_id = b16("/inputs/device_id");
        let secret: [u8; 32] = bytes("/inputs/printed_secret").try_into().unwrap();
        Self {
            secret: DeviceSecret::new(DeviceId::new(device_id), PrintedSecret::new(secret)),
            device_id,
            epoch: Epoch::new(1).unwrap(),
            challenge: b16("/inputs/challenge"),
            session: None,
            capabilities: Self::report().capabilities,
        }
    }

    fn header(kind: MessageType, req: ReqId) -> Header {
        Header {
            kind,
            session: handle(),
            req_id: req,
        }
    }

    fn discovery(&self) -> Discovery<'static> {
        Discovery {
            version: Version::V1_0,
            device_id: self.device_id,
            model: text("/inputs/model"),
            provisioned: false,
            pairing_open: true,
            challenge: self.challenge,
            epoch: self.epoch,
        }
    }

    fn discover(&self, request: &[u8]) -> Vec<u8> {
        Self::discover_as(request, &self.discovery())
    }

    fn discover_as(request: &[u8], discovery: &Discovery<'_>) -> Vec<u8> {
        let header = Envelope::decode(request).unwrap().header();
        assert_eq!(header.kind, MessageType::Discover);
        let mut frame = buffer();
        let len = discovery
            .write(
                Self::header(MessageType::DiscoverResponse, header.req_id),
                &mut frame,
            )
            .unwrap();
        finished(frame, len)
    }

    /// Answer `Pair` the way the controller does: `bad_proof` when the proof
    /// does not verify, otherwise `decided`.
    fn pair(&mut self, request: &[u8], decided: Outcome, next_challenge: [u8; 16]) -> Vec<u8> {
        let envelope = Envelope::decode(request).unwrap();
        let req = envelope.header().req_id;
        let claim = PairClaim::decode(envelope).unwrap();
        let attempt = claim.attempt(self.device_id, self.challenge);
        let pair_key = self.secret.pair_key();
        let outcome = match claim.verify(&pair_key, &attempt) {
            Ok(fields) => {
                assert_eq!(fields.label, text("/inputs/label"));
                decided
            }
            Err(refused) => refused.outcome(),
        };
        let mut frame = buffer();
        let len = PairResponse {
            outcome,
            epoch: self.epoch,
            next_challenge,
        }
        .write(
            &pair_key,
            &attempt,
            Self::header(MessageType::PairResponse, req),
            &mut frame,
        )
        .unwrap();
        self.challenge = next_challenge;
        finished(frame, len)
    }

    fn report() -> HelloReport<'static> {
        HelloReport {
            version: Version::V1_0,
            session: handle(),
            fw_controller: text("/inputs/fw_controller"),
            fw_comms: text("/inputs/fw_comms"),
            capabilities: 247,
            log_oldest_seq: LogSeq(1),
            log_newest_seq: LogSeq(256),
            state_seq: StateSeq(255),
            time_known: true,
            counter: HELLO_COUNTER,
            caps: Caps::THIS_CONTROLLER,
            topology: Topology::THIS_CONTROLLER,
        }
    }

    /// Verify the `Hello` proof and open the session.
    fn hello(&mut self, request: &[u8]) -> Vec<u8> {
        let envelope = Envelope::decode(request).unwrap();
        let req = envelope.header().req_id;
        let claim = HelloClaim::decode(envelope).unwrap();
        let enrolment: Enrolment = self.secret.enrolment(self.epoch, claim.client_id());
        let handshake = Handshake {
            challenge: self.challenge,
            client_nonce: claim.client_nonce(),
        };
        let accepted = claim
            .verify(&enrolment.client_key(), &self.challenge, Version::V1_0)
            .expect("the Hello proof verifies");
        assert_eq!(accepted.inner.client_id.get(), CLIENT_ID);
        let key = enrolment.session_key(&handshake, handle());
        let mut payload = buffer();
        let report = HelloReport {
            capabilities: self.capabilities,
            ..Self::report()
        };
        let len = report.encode(&mut payload).unwrap();
        let frame = Self::wrapped(&key, MessageType::HelloResponse, req, &payload[..len]);
        self.session = Some((key, enrolment.client_id()));
        frame
    }

    fn wrapped(key: &SessionKey, kind: MessageType, req: ReqId, payload: &[u8]) -> Vec<u8> {
        let tagged = Tagged::over(Self::header(kind, req), payload, key).unwrap();
        let mut frame = buffer();
        let len = tagged.write(&mut frame).unwrap();
        finished(frame, len)
    }

    fn key(&self) -> &SessionKey {
        &self.session.as_ref().expect("a session is open").0
    }

    /// The verified payload of a wrapped request, and its `req_id`.
    fn unwrap_request(&self, request: &[u8], kind: MessageType) -> (ReqId, Vec<u8>) {
        let envelope = Envelope::decode(request).unwrap();
        let header = envelope.header();
        assert_eq!(header.kind, kind);
        assert_eq!(header.session, handle());
        let verified = Wrapper::decode(envelope)
            .unwrap()
            .verify(self.key())
            .unwrap();
        (header.req_id, verified.payload().to_vec())
    }

    /// The verified operation of a signed request, its `req_id` and counter.
    fn signed(&self, request: &[u8], kind: MessageType, last: u64) -> (ReqId, Vec<u8>, Counter) {
        let (key, client_id) = self.session.as_ref().expect("a session is open");
        let envelope = Envelope::decode(request).unwrap();
        let header = envelope.header();
        assert_eq!(header.kind, kind);
        let fresh = SignedClaim::decode(envelope)
            .unwrap()
            .verify(key, *client_id)
            .expect("the signed request verifies")
            .fresh(Counter(last))
            .expect("the counter is fresh");
        (header.req_id, fresh.operation().to_vec(), fresh.counter())
    }

    fn reply(&self, kind: MessageType, req: ReqId, payload: &[u8]) -> Vec<u8> {
        Self::wrapped(self.key(), kind, req, payload)
    }
}

fn req_of(frame: &[u8]) -> ReqId {
    Envelope::decode(frame).unwrap().header().req_id
}

fn first_write() -> NetworkChange {
    NetworkChange {
        ssid: Some("cabin".to_owned()),
        passphrase: Some("correct horse battery".to_owned()),
        country: "CA".to_owned(),
        hostname: "origin89-cabin".to_owned(),
    }
}

/// Run `Discover`, `Pair` (enrolled, next challenge `next`) and `Hello`.
fn open_session(engine: &mut Engine, controller: &mut Controller, next: [u8; 16]) {
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap()
        .unwrap();
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        next,
    );
    engine.pair_reply(&ack).unwrap().unwrap();
    let request = engine.hello_request().unwrap();
    engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
}

fn read_unwritten(engine: &mut Engine, controller: &Controller) -> NetworkSettings {
    let request = engine.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let mut payload = buffer();
    let len = ConfigAnswer::new(ConfigSection::Network, 0, None)
        .unwrap()
        .encode(&mut payload)
        .unwrap();
    let reply = controller.reply(MessageType::GetConfigResponse, req, &payload[..len]);
    engine.read_network_reply(&reply).unwrap().unwrap()
}

#[test]
fn full_exchange_matches_the_vectors() {
    let mut engine = engine();
    let mut controller = Controller::new();

    // Discover: an empty map, answered by the published Discover 0x80.
    let request = engine.discover_request().unwrap();
    assert_eq!(request, hex::decode("84000001a0").unwrap());
    let answer = controller.discover(&request);
    assert!(answer.ends_with(&bytes("/bodies/discover_0x80/body_cbor")));
    let summary = engine.discover_reply(&answer).unwrap().unwrap();
    assert_eq!(summary.device_id, text("/inputs/device_id"));

    // Pair: body and ack are the published ones.
    let request = engine.pair_request().unwrap();
    assert!(request.ends_with(&bytes("/bodies/pair_0x0B/body_cbor")));
    assert_eq!(
        Envelope::decode(&request).unwrap().header().session,
        handle()
    );
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    assert!(ack.ends_with(&bytes("/bodies/pair_0x8B/body_cbor")));
    let paired = engine.pair_reply(&ack).unwrap().unwrap();
    assert_eq!(paired.client_id, CLIENT_ID);
    assert!(!paired.reclaimed);
    assert!(engine.is_enrolled());

    // Hello against the challenge the ack carried; the report is the vector's.
    let request = engine.hello_request().unwrap();
    let answer = controller.hello(&request);
    let mut report = buffer();
    let len = Controller::report().encode(&mut report).unwrap();
    assert_eq!(report[..len], bytes("/bodies/hello_0x81/body_cbor"));
    let info = engine.hello_reply(&answer).unwrap().unwrap();
    assert!(info.time_known);

    write_then_reread(&mut engine, &controller);
    keep_then_set_time(&mut engine, &controller);
}

/// `GetConfig` of a network section never written, the first `SetConfig`, and
/// `GetConfig` again: every frame the published one.
fn write_then_reread(engine: &mut Engine, controller: &Controller) {
    let request = engine.read_network_request().unwrap();
    let (req, payload) = controller.unwrap_request(&request, MessageType::GetConfig);
    assert_eq!(payload, bytes("/bodies/getconfig_0x06/body_cbor"));
    let mut answer = buffer();
    let len = ConfigAnswer::new(ConfigSection::Network, 0, None)
        .unwrap()
        .encode(&mut answer)
        .unwrap();
    let reply = controller.reply(MessageType::GetConfigResponse, req, &answer[..len]);
    let read = engine.read_network_reply(&reply).unwrap().unwrap();
    assert_eq!(
        read,
        NetworkSettings {
            version: 0,
            ssid: None,
            passphrase_set: false,
            country: None,
            hostname: None,
        }
    );

    // SetConfig: the first write, signed with the counter after Hello's.
    let request = engine.write_network_request(first_write(), 0).unwrap();
    let (req, operation, counter) =
        controller.signed(&request, MessageType::SetConfig, HELLO_COUNTER);
    assert_eq!(operation, bytes("/bodies/setconfig_0x07/body_cbor"));
    assert_eq!(counter, Counter(HELLO_COUNTER + 1));
    let mut ack = buffer();
    let len = SetConfigAck {
        section: ConfigSection::Network,
        version: 1,
        outcome: SetConfig::Accepted,
    }
    .encode(&mut ack)
    .unwrap();
    assert_eq!(ack[..len], bytes("/bodies/setconfigack_0x87/body_cbor"));
    let reply = controller.reply(MessageType::SetConfigResponse, req, &ack[..len]);
    assert_eq!(engine.write_network_reply(&reply).unwrap(), Some(1));

    // GetConfig again: the published Config 0x86, passphrase absent.
    let request = engine.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let reply = controller.reply(
        MessageType::GetConfigResponse,
        req,
        &bytes("/bodies/config_0x86/body_cbor"),
    );
    let read = engine.read_network_reply(&reply).unwrap().unwrap();
    assert_eq!(
        read,
        NetworkSettings {
            version: 1,
            ssid: Some("cabin".to_owned()),
            passphrase_set: true,
            country: Some("CA".to_owned()),
            hostname: Some("origin89-cabin".to_owned()),
        }
    );
}

/// `SetConfig` keeping the held passphrase for the same network (P-107), then
/// the published Time.
fn keep_then_set_time(engine: &mut Engine, controller: &Controller) {
    let keep = NetworkChange {
        passphrase: None,
        ..first_write()
    };
    let request = engine.write_network_request(keep, 1).unwrap();
    let (req, operation, counter) =
        controller.signed(&request, MessageType::SetConfig, HELLO_COUNTER + 1);
    assert!(operation.ends_with(&bytes("/bodies/network_write_keep_0x0020/body_cbor")));
    assert_eq!(counter, Counter(HELLO_COUNTER + 2));
    let mut ack = buffer();
    let len = SetConfigAck {
        section: ConfigSection::Network,
        version: 2,
        outcome: SetConfig::Accepted,
    }
    .encode(&mut ack)
    .unwrap();
    let reply = controller.reply(MessageType::SetConfigResponse, req, &ack[..len]);
    assert_eq!(engine.write_network_reply(&reply).unwrap(), Some(2));

    let request = engine.set_time_request(AT).unwrap();
    let (req, operation, _) = controller.signed(&request, MessageType::Time, HELLO_COUNTER + 2);
    assert_eq!(operation, bytes("/bodies/time_0x0A/body_cbor"));
    let reply = controller.reply(
        MessageType::TimeResponse,
        req,
        &bytes("/bodies/timeack_0x8A/body_cbor"),
    );
    assert_eq!(engine.set_time_reply(&reply).unwrap(), Some(AT));
}

#[test]
fn hello_proof_matches_the_vector() {
    // With the ack handing back the Discover challenge, the Hello is the
    // vector's: same challenge, nonce, client_id, epoch and client_version.
    let mut engine = engine();
    let mut controller = Controller::new();
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/challenge"),
    );
    engine.pair_reply(&ack).unwrap();
    let request = engine.hello_request().unwrap();
    let mut body = Envelope::decode(&request).unwrap().into_body();
    assert_eq!(body.key().unwrap(), 1);
    assert_eq!(
        body.bytes().unwrap(),
        bytes("/macs/hello_proof/inner_body_cbor")
    );
    assert_eq!(body.key().unwrap(), 2);
    assert_eq!(body.bytes().unwrap(), bytes("/macs/hello_proof/out16"));
    body.finish().unwrap();
    // And the session key both sides derive from it opens the session.
    engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
}

#[test]
fn pair_refusals_leave_pair_retryable_on_the_next_challenge() {
    for (decided, expected) in [
        (Outcome::WindowClosed, SetupFailure::WindowClosed),
        (Outcome::BadProof, SetupFailure::WrongProof),
        (Outcome::TableFull, SetupFailure::TableFull),
    ] {
        let mut engine = engine();
        let mut controller = Controller::new();
        let request = engine.discover_request().unwrap();
        engine
            .discover_reply(&controller.discover(&request))
            .unwrap();
        let request = engine.pair_request().unwrap();
        let ack = controller.pair(&request, decided, b16("/inputs/next_challenge"));
        assert_eq!(engine.pair_reply(&ack).unwrap_err(), expected);
        assert!(!engine.is_enrolled());

        // The retry proves against next_challenge, which the controller now holds.
        let request = engine.pair_request().unwrap();
        let ack = controller.pair(
            &request,
            Outcome::Reclaimed(ClientId::new(CLIENT_ID).unwrap()),
            b16("/inputs/challenge"),
        );
        let paired = engine.pair_reply(&ack).unwrap().unwrap();
        assert!(paired.reclaimed, "{decided:?}");
    }
}

#[test]
fn a_wrong_secret_cannot_authenticate_the_refusal_it_earns() {
    // The controller refuses the proof with bad_proof, MAC'd under the real
    // pair_key. A client holding another secret cannot verify that MAC, and
    // P-064 has it discard the reply rather than believe it.
    let mut payload = text("/qr/payload").to_owned();
    payload.replace_range(payload.len() - 2.., "ff");
    let mut engine = Engine::new(
        SetupCode::parse(&payload).unwrap(),
        text("/inputs/label"),
        "o89-cli 0.1.0",
        nonces(2),
    );
    let mut controller = Controller::new();
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    assert_eq!(
        engine.pair_reply(&ack).unwrap_err(),
        SetupFailure::ProtocolError
    );
    assert!(!engine.is_enrolled());
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn a_forged_pair_ack_is_refused() {
    let mut engine = engine();
    let mut controller = Controller::new();
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    let request = engine.pair_request().unwrap();
    let mut ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    // The client_id byte: a relay naming another identity breaks the MAC.
    let at = ack.len() - 37;
    assert_eq!(ack[at], 0x07);
    ack[at] = 0x06;
    assert_eq!(
        engine.pair_reply(&ack).unwrap_err(),
        SetupFailure::ProtocolError
    );
    assert!(!engine.is_enrolled());
}

#[test]
fn another_controller_is_refused() {
    let mut engine = engine();
    let controller = Controller::new();
    let request = engine.discover_request().unwrap();
    let mut other = controller.discovery();
    other.device_id[0] ^= 1;
    let answer = Controller::discover_as(&request, &other);
    assert_eq!(
        engine.discover_reply(&answer).unwrap_err(),
        SetupFailure::ControllerMismatch
    );
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn another_protocol_major_is_refused() {
    let mut engine = engine();
    let controller = Controller::new();
    let request = engine.discover_request().unwrap();
    let mut other = controller.discovery();
    other.version = Version { major: 2, minor: 0 };
    let answer = Controller::discover_as(&request, &other);
    assert_eq!(
        engine.discover_reply(&answer).unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn a_forged_hello_answer_is_refused() {
    let mut engine = engine();
    let mut controller = Controller::new();
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    engine.pair_reply(&ack).unwrap();
    let request = engine.hello_request().unwrap();
    let mut answer = controller.hello(&request);
    let last = answer.len() - 1;
    answer[last] ^= 1;
    assert_eq!(
        engine.hello_reply(&answer).unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn config_with_a_bad_mac_is_refused() {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let mut reply = controller.reply(
        MessageType::GetConfigResponse,
        req,
        &bytes("/bodies/config_0x86/body_cbor"),
    );
    let last = reply.len() - 1;
    reply[last] ^= 0x80;
    assert_eq!(
        engine.read_network_reply(&reply).unwrap_err(),
        SetupFailure::ProtocolError
    );
    // The session is over; the caller reconnects.
    assert_eq!(
        engine.read_network_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
}

/// A `Config 0x86` payload for the network section carrying `body`.
fn config_payload(version: u32, body: Option<&[u8]>) -> Vec<u8> {
    let mut payload = buffer();
    let mut cbor = CborWriter::new(&mut payload);
    cbor.map(if body.is_some() { 3 } else { 2 }).unwrap();
    cbor.key(1).unwrap();
    cbor.u64(0x20).unwrap();
    cbor.key(2).unwrap();
    cbor.u64(u64::from(version)).unwrap();
    if let Some(body) = body {
        cbor.key(3).unwrap();
        cbor.raw(body).unwrap();
    }
    let len = cbor.finish().unwrap();
    finished(payload, len)
}

fn refuse_config(payload: &[u8]) -> SetupFailure {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let reply = controller.reply(MessageType::GetConfigResponse, req, payload);
    engine.read_network_reply(&reply).unwrap_err()
}

#[test]
fn a_config_carrying_the_passphrase_is_refused() {
    // P-106: key 2 `psk` in a Config body, even beside psk_set.
    let mut body = buffer();
    let mut cbor = CborWriter::new(&mut body);
    cbor.map(5).unwrap();
    for (key, value) in [(1, "cabin"), (2, "correct horse battery")] {
        cbor.key(key).unwrap();
        cbor.text(value).unwrap();
    }
    cbor.key(3).unwrap();
    cbor.bool(true).unwrap();
    for (key, value) in [(4, "CA"), (5, "origin89-cabin")] {
        cbor.key(key).unwrap();
        cbor.text(value).unwrap();
    }
    let len = cbor.finish().unwrap();
    assert_eq!(
        refuse_config(&config_payload(1, Some(&body[..len]))),
        SetupFailure::ProtocolError
    );
}

#[test]
fn a_config_whose_version_and_body_disagree_is_refused() {
    // P-108, both ways round.
    let body = bytes("/bodies/networkread_0x0020/body_cbor");
    assert_eq!(
        refuse_config(&config_payload(0, Some(&body))),
        SetupFailure::ProtocolError
    );
    assert_eq!(
        refuse_config(&config_payload(1, None)),
        SetupFailure::ProtocolError
    );
}

#[test]
fn a_config_for_another_section_is_refused() {
    let mut payload = buffer();
    let len = ConfigAnswer::new(ConfigSection::IdentityAndSite, 0, None)
        .unwrap()
        .encode(&mut payload)
        .unwrap();
    assert_eq!(refuse_config(&payload[..len]), SetupFailure::ProtocolError);
}

fn refuse_write(outcome: SetConfig, version: u32) -> (SetupFailure, Engine, Controller) {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    read_unwritten(&mut engine, &controller);
    let request = engine.write_network_request(first_write(), 0).unwrap();
    let (req, _, _) = controller.signed(&request, MessageType::SetConfig, HELLO_COUNTER);
    let mut ack = buffer();
    let len = SetConfigAck {
        section: ConfigSection::Network,
        version,
        outcome,
    }
    .encode(&mut ack)
    .unwrap();
    let reply = controller.reply(MessageType::SetConfigResponse, req, &ack[..len]);
    let why = engine.write_network_reply(&reply).unwrap_err();
    (why, engine, controller)
}

#[test]
fn a_stale_version_is_reported_and_the_session_continues() {
    let (why, mut engine, controller) = refuse_write(SetConfig::StaleVersion, 4);
    assert_eq!(why, SetupFailure::StaleVersion);
    // Read again and retry: the next signed write spends a fresh counter.
    read_unwritten(&mut engine, &controller);
    let request = engine.write_network_request(first_write(), 0).unwrap();
    let (_, _, counter) = controller.signed(&request, MessageType::SetConfig, HELLO_COUNTER + 1);
    assert_eq!(counter, Counter(HELLO_COUNTER + 2));
}

#[test]
fn an_invalid_write_is_reported_and_the_session_continues() {
    let (why, mut engine, controller) = refuse_write(SetConfig::Invalid, 0);
    assert_eq!(why, SetupFailure::InvalidConfig);
    read_unwritten(&mut engine, &controller);
}

#[test]
fn an_unauthorised_write_is_a_protocol_error() {
    let (why, mut engine, _) = refuse_write(SetConfig::Unauthorised, 0);
    assert_eq!(why, SetupFailure::ProtocolError);
    assert_eq!(
        engine.read_network_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn an_accepted_write_must_advance_the_version_by_one() {
    let (why, _, _) = refuse_write(SetConfig::Accepted, 5);
    assert_eq!(why, SetupFailure::ProtocolError);
}

#[test]
fn writes_breaking_the_section_bounds_are_refused_before_sending() {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let cases = [
        NetworkChange {
            country: "ca".to_owned(),
            ..first_write()
        },
        NetworkChange {
            hostname: "-cabin".to_owned(),
            ..first_write()
        },
        NetworkChange {
            passphrase: Some("short".to_owned()),
            ..first_write()
        },
        NetworkChange {
            ssid: Some("s".repeat(33)),
            ..first_write()
        },
        NetworkChange {
            ssid: None,
            ..first_write()
        },
    ];
    for change in cases {
        let shown = format!("{change:?}");
        assert_eq!(
            engine.write_network_request(change, 0).unwrap_err(),
            SetupFailure::InvalidConfig,
            "{shown}"
        );
    }
    // Nothing was sent, so the session is still usable.
    read_unwritten(&mut engine, &controller);
}

#[test]
fn keeping_a_passphrase_for_another_network_is_refused_before_sending() {
    // P-107: the held passphrase is for `cabin`; `barn` without one is invalid.
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let reply = controller.reply(
        MessageType::GetConfigResponse,
        req,
        &bytes("/bodies/config_0x86/body_cbor"),
    );
    engine.read_network_reply(&reply).unwrap().unwrap();
    let elsewhere = NetworkChange {
        ssid: Some("barn".to_owned()),
        passphrase: None,
        ..first_write()
    };
    assert_eq!(
        engine
            .write_network_request(elsewhere.clone(), 1)
            .unwrap_err(),
        SetupFailure::InvalidConfig
    );
    // Against a version this client has not read, the controller decides.
    assert!(engine.write_network_request(elsewhere, 7).is_ok());
}

#[test]
fn clearing_the_network_needs_no_passphrase() {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let clear = NetworkChange {
        ssid: None,
        passphrase: None,
        ..first_write()
    };
    let request = engine.write_network_request(clear, 3).unwrap();
    let (_, operation, _) = controller.signed(&request, MessageType::SetConfig, HELLO_COUNTER);
    assert!(operation.ends_with(&bytes("/bodies/network_write_clear_0x0020/body_cbor")));
}

fn refuse_time(outcome: Time, at: Option<u64>) -> (Result<Option<u64>, SetupFailure>, Engine) {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.set_time_request(AT).unwrap();
    let (req, _, _) = controller.signed(&request, MessageType::Time, HELLO_COUNTER);
    let mut ack = buffer();
    let len = TimeAck::new(outcome, at).unwrap().encode(&mut ack).unwrap();
    let reply = controller.reply(MessageType::TimeResponse, req, &ack[..len]);
    (engine.set_time_reply(&reply), engine)
}

#[test]
fn time_refusals_are_named() {
    let (result, mut engine) = refuse_time(Time::Rejected, Some(AT - 1));
    assert_eq!(result.unwrap_err(), SetupFailure::TimeRejected);
    assert!(engine.set_time_request(AT).is_ok(), "the session continues");

    let (result, _) = refuse_time(Time::NeedsButton, None);
    assert_eq!(result.unwrap_err(), SetupFailure::TimeNeedsButton);

    let (result, _) = refuse_time(Time::Unauthorised, None);
    assert_eq!(result.unwrap_err(), SetupFailure::ProtocolError);
}

#[test]
fn frames_answering_nothing_outstanding_are_ignored() {
    let mut engine = engine();
    let mut controller = Controller::new();
    let request = engine.discover_request().unwrap();
    let req = req_of(&request);

    // A response to another req_id (P-024).
    let mut stray = buffer();
    let len = controller
        .discovery()
        .write(
            Controller::header(MessageType::DiscoverResponse, ReqId(req.0 + 5)),
            &mut stray,
        )
        .unwrap();
    assert_eq!(engine.discover_reply(&stray[..len]).unwrap(), None);

    // The link diagnostic Error with session 0 and req_id 0 (P-024, P-025).
    let mut diagnostic = buffer();
    let len = ErrorBody {
        code: Incoming::Client(ErrorCode::MalformedFrame),
        detail: "frame did not parse",
    }
    .write(
        Header {
            kind: MessageType::ErrorResponse,
            session: SessionId::None,
            req_id: ReqId(0),
        },
        &mut diagnostic,
    )
    .unwrap();
    assert_eq!(engine.discover_reply(&diagnostic[..len]).unwrap(), None);

    // The real answer still lands.
    assert!(
        engine
            .discover_reply(&controller.discover(&request))
            .unwrap()
            .is_some()
    );

    // In a session, an event and a response on another session are ignored.
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    engine.pair_reply(&ack).unwrap();
    let request = engine.hello_request().unwrap();
    engine.hello_reply(&controller.hello(&request)).unwrap();
    let request = engine.read_network_request().unwrap();
    let req = req_of(&request);
    let mut event = buffer();
    let cbor = Header {
        kind: MessageType::EventResponse,
        session: handle(),
        req_id: ReqId(0),
    }
    .write(0, &mut event)
    .unwrap();
    let len = cbor.finish().unwrap();
    assert_eq!(engine.read_network_reply(&event[..len]).unwrap(), None);
    let unwritten = config_payload(0, None);
    let other_session = Tagged::over(
        Header {
            kind: MessageType::GetConfigResponse,
            session: SessionId::from(9),
            req_id: req,
        },
        &unwritten,
        controller.key(),
    )
    .unwrap();
    let mut frame = buffer();
    let len = other_session.write(&mut frame).unwrap();
    assert_eq!(engine.read_network_reply(&frame[..len]).unwrap(), None);
}

#[test]
fn a_reply_of_the_wrong_type_is_refused() {
    let mut engine = engine();
    let request = engine.discover_request().unwrap();
    let mut frame = buffer();
    let cbor = Controller::header(MessageType::PairResponse, req_of(&request))
        .write(0, &mut frame)
        .unwrap();
    let len = cbor.finish().unwrap();
    assert_eq!(
        engine.discover_reply(&frame[..len]).unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn garbage_is_refused() {
    let mut engine = engine();
    engine.discover_request().unwrap();
    assert_eq!(
        engine.discover_reply(&[0xff, 0x00]).unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn a_bare_error_only_licenses_a_reconnect() {
    // Before a session: the published bare Error, re-addressed to our request.
    let mut engine = engine();
    let request = engine.discover_request().unwrap();
    let mut frame = buffer();
    let len = ErrorBody {
        code: Incoming::Client(ErrorCode::ChallengeUnavailable),
        detail: "no challenge",
    }
    .write(
        Controller::header(MessageType::ErrorResponse, req_of(&request)),
        &mut frame,
    )
    .unwrap();
    assert_eq!(
        engine.discover_reply(&frame[..len]).unwrap_err(),
        SetupFailure::ConnectionDropped
    );

    // In a session: a bare Error is not the wrapper, so its code is not read.
    let mut engine = self::engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let mut frame = buffer();
    let len = ErrorBody {
        code: Incoming::Client(ErrorCode::UnknownSection),
        detail: "no such section",
    }
    .write(
        Controller::header(MessageType::ErrorResponse, req_of(&request)),
        &mut frame,
    )
    .unwrap();
    assert_eq!(
        engine.read_network_reply(&frame[..len]).unwrap_err(),
        SetupFailure::ConnectionDropped
    );
}

fn wrapped_error(code: ErrorCode) -> SetupFailure {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let mut payload = buffer();
    let len = ErrorBody {
        code: Incoming::Client(code),
        detail: "refused",
    }
    .encode(&mut payload)
    .unwrap();
    let reply = controller.reply(
        MessageType::ErrorResponse,
        req_of(&request),
        &payload[..len],
    );
    engine.read_network_reply(&reply).unwrap_err()
}

#[test]
fn an_authenticated_error_is_read() {
    assert_eq!(
        wrapped_error(ErrorCode::BusyRetry),
        SetupFailure::ConnectionDropped
    );
    assert_eq!(
        wrapped_error(ErrorCode::CounterNotFresh),
        SetupFailure::ConnectionDropped
    );
    assert_eq!(
        wrapped_error(ErrorCode::UnknownSection),
        SetupFailure::ProtocolError
    );
}

#[test]
fn the_published_wrapped_error_verifies_only_under_its_session() {
    // macs.error_response is busy on session 3, req_id 17. Delivered to a
    // session that did not derive that key, it cannot be read, and P-142 makes
    // it a reconnect rather than a statement about the controller.
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let req = req_of(&request);
    let body = bytes("/macs/error_response/full_body_cbor");
    let mut frame = buffer();
    let mut cbor = CborWriter::new(&mut frame);
    cbor.array(4).unwrap();
    cbor.u64(0xff).unwrap();
    cbor.u64(u64::from(HANDLE)).unwrap();
    cbor.u64(u64::from(req.0)).unwrap();
    cbor.raw(&body).unwrap();
    let len = cbor.finish().unwrap();
    assert_eq!(
        engine.read_network_reply(&frame[..len]).unwrap_err(),
        SetupFailure::ConnectionDropped
    );
}

/// An `Error 0xFF` answering `req`, bare or wrapped under `controller`'s key.
fn error_frame(controller: &Controller, req: ReqId, code: ErrorCode, wrapped: bool) -> Vec<u8> {
    let body = ErrorBody {
        code: Incoming::Client(code),
        detail: "refused",
    };
    let mut frame = buffer();
    if wrapped {
        let len = body.encode(&mut frame).unwrap();
        return controller.reply(MessageType::ErrorResponse, req, &frame[..len]);
    }
    let len = body
        .write(
            Controller::header(MessageType::ErrorResponse, req),
            &mut frame,
        )
        .unwrap();
    finished(frame, len)
}

#[test]
fn a_note_names_a_frame_and_judges_nothing() {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let req = req_of(&request);
    assert_eq!(
        engine.frame_note(&request),
        Some(FrameNote {
            kind: "GetConfig".to_owned(),
            req_id: req.0,
            error: None,
        })
    );
    let error = error_frame(&controller, req, ErrorCode::SessionExpired, true);
    assert_eq!(
        engine.frame_note(&error),
        Some(FrameNote {
            kind: "ErrorResponse".to_owned(),
            req_id: req.0,
            error: Some(ErrorNote::Verified {
                code: "SessionExpired".to_owned()
            }),
        })
    );
    // Noting the Error left GetConfig outstanding: its answer is still taken.
    let answer = controller.reply(
        MessageType::GetConfigResponse,
        req,
        &config_payload(0, None),
    );
    assert_eq!(
        engine.frame_note(&answer).map(|note| note.kind),
        Some("GetConfigResponse".to_owned())
    );
    assert_eq!(
        engine.read_network_reply(&answer).unwrap().unwrap().version,
        0
    );
}

#[test]
fn a_bare_error_is_noted_as_a_hint() {
    // Before a session there is no key, and a bare Error is all that can come.
    let mut engine = engine();
    let controller = Controller::new();
    let request = engine.discover_request().unwrap();
    let error = error_frame(
        &controller,
        req_of(&request),
        ErrorCode::ChallengeUnavailable,
        false,
    );
    assert_eq!(
        engine.frame_note(&error).and_then(|note| note.error),
        Some(ErrorNote::Bare {
            code: "ChallengeUnavailable".to_owned()
        })
    );
}

#[test]
fn an_error_under_another_key_is_unreadable() {
    // The published wrapped Error, for a session this link did not open.
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    let request = engine.read_network_request().unwrap();
    let body = bytes("/macs/error_response/full_body_cbor");
    let mut frame = buffer();
    let mut cbor = CborWriter::new(&mut frame);
    cbor.array(4).unwrap();
    cbor.u64(0xff).unwrap();
    cbor.u64(u64::from(HANDLE)).unwrap();
    cbor.u64(u64::from(req_of(&request).0)).unwrap();
    cbor.raw(&body).unwrap();
    let len = cbor.finish().unwrap();
    let error = finished(frame, len);
    assert_eq!(
        engine.frame_note(&error).and_then(|note| note.error),
        Some(ErrorNote::Unreadable)
    );
    // A wrapped Error with no session on the link cannot be read either.
    let fresh = self::engine();
    assert_eq!(
        fresh.frame_note(&error).and_then(|note| note.error),
        Some(ErrorNote::Unreadable)
    );
}

#[test]
fn bytes_that_are_no_envelope_have_no_note() {
    let engine = engine();
    assert_eq!(engine.frame_note(&[]), None);
    assert_eq!(engine.frame_note(&[0xff, 0x00, 0x13]), None);
}

#[test]
fn steps_out_of_order_are_refused_without_losing_state() {
    let mut engine = engine();
    let mut controller = Controller::new();
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
    assert_eq!(
        engine.hello_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
    assert_eq!(
        engine.read_network_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
    assert_eq!(
        engine.discover_reply(&[0x80]).unwrap_err(),
        SetupFailure::ProtocolError
    );
    // None of that consumed the engine.
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
    read_unwritten(&mut engine, &controller);
}

#[test]
fn a_reconnect_says_hello_again_without_pairing() {
    let mut engine = engine();
    let mut controller = Controller::new();
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));

    engine.reset_link();
    controller.challenge = [0x5a; 16];
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
    let request = engine.hello_request().unwrap();
    engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
    read_unwritten(&mut engine, &controller);
}

#[test]
fn no_randomness_sends_nothing() {
    let mut engine = Engine::new(code(), "kitchen phone", "o89-cli 0.1.0", nonces(0));
    let controller = Controller::new();
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap();
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError
    );
}

#[test]
fn the_swift_facing_session_runs_the_same_exchange() {
    let session = SetupSession::with_nonces(code(), "kitchen phone", nonces(2));
    let mut controller = Controller::new();
    assert_eq!(session.device_id(), text("/inputs/device_id"));
    let request = session.discover_request().unwrap();
    session
        .discover_reply(&controller.discover(&request))
        .unwrap()
        .unwrap();
    let request = session.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    session.pair_reply(&ack).unwrap().unwrap();
    assert!(session.is_enrolled());
    let request = session.hello_request().unwrap();
    session
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
    let request = session.read_network_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::GetConfig);
    let reply = controller.reply(
        MessageType::GetConfigResponse,
        req,
        &bytes("/bodies/config_0x86/body_cbor"),
    );
    let read = session.read_network_reply(&reply).unwrap().unwrap();
    assert_eq!(read.version, 1);
    assert!(read.passphrase_set);
}

#[test]
fn the_swift_facing_constructor_refuses_a_malformed_code() {
    assert!(SetupSession::new("km43:1:", "kitchen phone").is_err());
    assert!(SetupSession::new(text("/qr/payload"), "kitchen phone").is_ok());
}

#[test]
fn cbor_reader_is_used_as_published() {
    // Guards the assumption the Hello test makes about envelope bodies.
    let request = hex::decode("84000001a0").unwrap();
    let envelope = Envelope::decode(&request).unwrap();
    assert_eq!(envelope.keys(), 0);
    let body: CborReader<'_> = envelope.into_body();
    body.finish().unwrap();
}

/// Bit 8: the controller answers `WifiScan` and `WifiStatus` (P-216).
const REPORTS_WIFI: u32 = 1 << 8;

/// An open session with a controller whose `Hello` sets bit 8.
fn wifi_session() -> (Engine, Controller) {
    let mut engine = engine();
    let mut controller = Controller::new();
    controller.capabilities |= REPORTS_WIFI;
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap()
        .unwrap();
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Enrolled(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    engine.pair_reply(&ack).unwrap().unwrap();
    let request = engine.hello_request().unwrap();
    let info = engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
    assert!(info.reports_wifi);
    (engine, controller)
}

fn scan(engine: &mut Engine, controller: &Controller, refresh: bool, answer: &[u8]) -> NetworkScan {
    let request = engine.wifi_scan_request(refresh).unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiScan);
    let reply = controller.reply(MessageType::WifiScanResponse, req, answer);
    engine.wifi_scan_reply(&reply).unwrap().unwrap()
}

fn status(engine: &mut Engine, controller: &Controller, answer: &[u8]) -> WifiStatus {
    let request = engine.wifi_status_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiStatus);
    let reply = controller.reply(MessageType::WifiStatusResponse, req, answer);
    engine.wifi_status_reply(&reply).unwrap().unwrap()
}

#[test]
fn wifi_scan_matches_the_vectors() {
    let (mut engine, controller) = wifi_session();

    let request = engine.wifi_scan_request(true).unwrap();
    let (req, body) = controller.unwrap_request(&request, MessageType::WifiScan);
    assert_eq!(body, bytes("/bodies/wifiscan_0x11/body_cbor"));
    let reply = controller.reply(
        MessageType::WifiScanResponse,
        req,
        &bytes("/bodies/wifiscan_0x91/body_cbor"),
    );
    let answer = engine.wifi_scan_reply(&reply).unwrap().unwrap();
    assert_eq!(answer.progress, ScanProgress::Complete);
    assert_eq!(answer.refused, None);
    let heard = answer.heard.expect("a completed scan holds a list");
    assert_eq!(heard.age_ms, 4200);
    assert_eq!(heard.unlisted, 4);
    assert_eq!(heard.networks.len(), 3);
    assert_eq!(
        heard.networks[0],
        HeardNetwork {
            ssid: "cabin".to_owned(),
            rssi: -48,
            security: NetworkSecurity::Wpa3Personal,
            band: NetworkBand::Ghz24,
            channel: 6,
        }
    );
    // The published list's second row: a 32-byte SSID with multibyte characters.
    assert_eq!(heard.networks[1].ssid, "chalet-été-réseau-du-voisin-2");
    assert_eq!(heard.networks[1].ssid.len(), 32);
    assert!(
        heard
            .networks
            .windows(2)
            .all(|pair| pair[0].rssi >= pair[1].rssi),
        "strongest first"
    );

    // Refused: the section was never written, so there is no list either.
    let answer = scan(
        &mut engine,
        &controller,
        true,
        &bytes("/bodies/wifiscan_refused_0x91/body_cbor"),
    );
    assert_eq!(
        answer,
        NetworkScan {
            progress: ScanProgress::None,
            refused: Some(ScanRefusal::RadioOff),
            heard: None,
        }
    );

    // Reading without a refresh asks for no scan.
    let request = engine.wifi_scan_request(false).unwrap();
    let (_, body) = controller.unwrap_request(&request, MessageType::WifiScan);
    assert_eq!(body, hex::decode("a101f4").unwrap());
}

#[test]
fn wifi_status_matches_the_vectors() {
    let (mut engine, controller) = wifi_session();

    let request = engine.wifi_status_request().unwrap();
    let (req, body) = controller.unwrap_request(&request, MessageType::WifiStatus);
    assert_eq!(body, hex::decode("a0").unwrap());
    let reply = controller.reply(
        MessageType::WifiStatusResponse,
        req,
        &bytes("/bodies/wifistatus_0x92/body_cbor"),
    );
    let joined = engine.wifi_status_reply(&reply).unwrap().unwrap();
    assert_eq!(
        joined,
        WifiStatus {
            section: 2,
            radio: Some(RadioStatus {
                version: 2,
                state: RadioState::Joined {
                    address: "192.168.1.42".to_owned(),
                },
            }),
        }
    );
    assert!(matches!(
        joined.state_for(2),
        Some(RadioState::Joined { .. })
    ));
    assert_eq!(joined.state_for(3), None);

    let unknown = status(
        &mut engine,
        &controller,
        &bytes("/bodies/wifistatus_unknown_0x92/body_cbor"),
    );
    assert_eq!(
        unknown,
        WifiStatus {
            section: 2,
            radio: None,
        }
    );

    // The session is still usable for the network steps.
    read_unwritten(&mut engine, &controller);
}

#[test]
fn a_failed_join_reports_its_reason() {
    let (mut engine, controller) = wifi_session();
    // Section 3, radio still on version 2 and failed auth_failed: the keys of
    // the published 0x0806 record, which WifiStatus shares.
    let answer = status(
        &mut engine,
        &controller,
        &bytes("/bodies/wifistatuschanged_0x0806/body_cbor"),
    );
    assert_eq!(answer.section, 3);
    assert_eq!(
        answer.radio,
        Some(RadioStatus {
            version: 2,
            state: RadioState::Failed {
                reason: JoinFailure::AuthFailed,
            },
        })
    );
    assert_eq!(
        answer.state_for(3),
        None,
        "the verdict is on the previous write"
    );
}

#[test]
fn wifi_steps_are_refused_without_capability_bit_8() {
    let mut engine = engine();
    let mut controller = Controller::new();
    assert_eq!(controller.capabilities & REPORTS_WIFI, 0);
    open_session(&mut engine, &mut controller, b16("/inputs/next_challenge"));
    assert_eq!(
        engine.wifi_scan_request(true),
        Err(SetupFailure::ProtocolError)
    );
    assert_eq!(
        engine.wifi_status_request(),
        Err(SetupFailure::ProtocolError)
    );
    // Nothing was sent and the session carries on.
    read_unwritten(&mut engine, &controller);
}

#[test]
fn a_scan_answer_that_breaks_p217_ends_the_session() {
    // `complete` with no list.
    let (mut engine, controller) = wifi_session();
    let request = engine.wifi_scan_request(false).unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiScan);
    let reply = controller.reply(
        MessageType::WifiScanResponse,
        req,
        &hex::decode("a10103").unwrap(),
    );
    assert_eq!(
        engine.wifi_scan_reply(&reply),
        Err(SetupFailure::ProtocolError)
    );
    assert_eq!(
        engine.read_network_request(),
        Err(SetupFailure::ProtocolError)
    );
}

#[test]
fn a_status_whose_state_lacks_its_field_is_refused() {
    // `joined` with no address.
    let (mut engine, controller) = wifi_session();
    let request = engine.wifi_status_request().unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiStatus);
    let reply = controller.reply(
        MessageType::WifiStatusResponse,
        req,
        &hex::decode("a3010202020303").unwrap(),
    );
    assert_eq!(
        engine.wifi_status_reply(&reply),
        Err(SetupFailure::ProtocolError)
    );
}

#[test]
fn a_scan_answer_with_a_bad_mac_is_refused() {
    let (mut engine, controller) = wifi_session();
    let request = engine.wifi_scan_request(false).unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiScan);
    let mut reply = controller.reply(
        MessageType::WifiScanResponse,
        req,
        &bytes("/bodies/wifiscan_0x91/body_cbor"),
    );
    let last = reply.len() - 1;
    reply[last] ^= 1;
    assert_eq!(
        engine.wifi_scan_reply(&reply),
        Err(SetupFailure::ProtocolError)
    );
}

#[test]
fn a_frame_for_another_request_leaves_the_scan_outstanding() {
    let (mut engine, controller) = wifi_session();
    let request = engine.wifi_scan_request(false).unwrap();
    let (req, _) = controller.unwrap_request(&request, MessageType::WifiScan);
    let answer = bytes("/bodies/wifiscan_0x91/body_cbor");
    let stray = controller.reply(MessageType::WifiScanResponse, ReqId(req.0 + 5), &answer);
    assert_eq!(engine.wifi_scan_reply(&stray), Ok(None));
    let reply = controller.reply(MessageType::WifiScanResponse, req, &answer);
    assert!(engine.wifi_scan_reply(&reply).unwrap().is_some());
}

/// Pair a fresh engine and return what it hands over to keep.
fn kept_after_pairing(controller: &mut Controller) -> Vec<u8> {
    let mut engine = engine();
    assert!(
        engine.kept_enrolment().is_none(),
        "nothing to keep before Pair"
    );
    open_session(&mut engine, controller, b16("/inputs/next_challenge"));
    engine.kept_enrolment().expect("enrolled").to_vec()
}

/// A relaunched engine: the setup code scanned again, and the kept enrolment.
fn relaunched(kept: &[u8]) -> Engine {
    let mut engine = engine();
    assert!(engine.restore_kept(kept));
    assert!(engine.is_enrolled());
    engine
}

fn discover(engine: &mut Engine, controller: &Controller) -> bool {
    let request = engine.discover_request().unwrap();
    engine
        .discover_reply(&controller.discover(&request))
        .unwrap()
        .unwrap()
        .enrolled
}

fn pair(engine: &mut Engine, controller: &mut Controller) {
    let request = engine.pair_request().unwrap();
    let ack = controller.pair(
        &request,
        Outcome::Reclaimed(ClientId::new(CLIENT_ID).unwrap()),
        b16("/inputs/next_challenge"),
    );
    engine.pair_reply(&ack).unwrap().unwrap();
}

fn bare_error(request: &[u8]) -> Vec<u8> {
    let mut frame = buffer();
    let len = ErrorBody {
        code: Incoming::Client(ErrorCode::UnknownClient),
        detail: "unknown client",
    }
    .write(
        Controller::header(MessageType::ErrorResponse, req_of(request)),
        &mut frame,
    )
    .unwrap();
    finished(frame, len)
}

/// The failure the issue came from: an app that paired, quit and relaunched
/// could only pair again, which needs a person at the panel (P-066).
#[test]
fn a_kept_enrolment_says_hello_without_pairing() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    let mut engine = relaunched(&kept);
    assert!(discover(&mut engine, &controller));
    assert_eq!(
        engine.pair_request().unwrap_err(),
        SetupFailure::ProtocolError,
        "an engine greeting with a kept key does not pair"
    );
    assert!(engine.kept_enrolment().is_none(), "unproven until Hello");
    let request = engine.hello_request().unwrap();
    engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
    assert_eq!(
        engine.kept_enrolment().expect("proven").as_slice(),
        kept.as_slice()
    );
    read_unwritten(&mut engine, &controller);
}

#[test]
fn the_kept_bytes_hold_no_printed_secret() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    assert_eq!(kept.len(), km43::StoredEnrolment::LEN);
    let secret = bytes("/inputs/printed_secret");
    assert!(
        !kept
            .windows(4)
            .any(|window| secret.windows(4).any(|s| s == window)),
        "four bytes of the printed secret are in storage"
    );
}

/// P-222: once a kept key's Hello succeeds the setup code goes, as it does
/// after Pair. A reset then cannot be paired through without scanning again.
#[test]
fn a_proven_kept_enrolment_drops_the_setup_code() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    let mut engine = relaunched(&kept);
    assert!(discover(&mut engine, &controller));
    let request = engine.hello_request().unwrap();
    engine
        .hello_reply(&controller.hello(&request))
        .unwrap()
        .unwrap();
    engine.reset_link();
    controller.epoch = Epoch::new(2).unwrap();
    let request = engine.discover_request().unwrap();
    assert_eq!(
        engine
            .discover_reply(&controller.discover(&request))
            .unwrap_err(),
        SetupFailure::ControllerReset
    );
    assert!(!engine.is_enrolled());
}

/// P-222, P-085: a key kept before a factory reset is not sent; the engine
/// pairs with the code in hand and hands over the new key to keep.
#[test]
fn a_kept_enrolment_for_another_epoch_pairs_again() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    for epoch in [2, 1] {
        let mut engine = relaunched(&kept);
        let mut reset = Controller::new();
        reset.epoch = Epoch::new(epoch + 1).unwrap();
        reset.challenge = controller.challenge;
        assert!(!discover(&mut engine, &reset), "epoch {}", epoch + 1);
        assert!(!engine.is_enrolled());
        assert_eq!(
            engine.hello_request().unwrap_err(),
            SetupFailure::ProtocolError,
            "no Hello under a key for another epoch"
        );
        pair(&mut engine, &mut reset);
        let replaced = engine.kept_enrolment().expect("paired again");
        assert_ne!(replaced.as_slice(), kept.as_slice());
    }
}

/// The controller answers a kept key it will not take with an `Error`; the
/// engine drops the key and pairs with the setup code on the next link.
#[test]
fn a_refused_kept_enrolment_falls_back_to_pairing() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    let mut engine = relaunched(&kept);
    assert!(discover(&mut engine, &controller));
    let request = engine.hello_request().unwrap();
    assert_eq!(
        engine.hello_reply(&bare_error(&request)).unwrap_err(),
        SetupFailure::EnrolmentRefused
    );
    assert!(!engine.is_enrolled());
    assert!(engine.kept_enrolment().is_none());
    engine.reset_link();
    assert!(!discover(&mut engine, &controller));
    pair(&mut engine, &mut controller);
    assert!(engine.kept_enrolment().is_some());
}

/// After a Pair in this session the same `Error` is the reconnect hint it
/// always was, not a reason to forget the enrolment.
#[test]
fn an_error_answering_hello_after_pairing_keeps_the_enrolment() {
    let mut engine = engine();
    let mut controller = Controller::new();
    assert!(!discover(&mut engine, &controller));
    pair(&mut engine, &mut controller);
    let request = engine.hello_request().unwrap();
    assert_eq!(
        engine.hello_reply(&bare_error(&request)).unwrap_err(),
        SetupFailure::ConnectionDropped
    );
    assert!(engine.is_enrolled());
    engine.reset_link();
    assert!(discover(&mut engine, &controller));
}

#[test]
fn unreadable_kept_bytes_leave_the_engine_pairing() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);
    let mut unknown_format = kept.clone();
    unknown_format[0] ^= 0xFF;
    let mut zero_client = kept.clone();
    // Format, device_id and epoch come first; client_id is the next four bytes.
    zero_client[21..25].fill(0);
    let cases: [&[u8]; 5] = [
        &[],
        &kept[..kept.len() - 1],
        &[kept.as_slice(), &[0]].concat(),
        &unknown_format,
        &zero_client,
    ];
    for bytes in cases {
        let mut engine = engine();
        assert!(!engine.restore_kept(bytes), "{} bytes taken", bytes.len());
        assert!(!engine.is_enrolled());
        assert!(!discover(&mut engine, &controller));
        engine.pair_request().unwrap();
    }
}

#[test]
fn kept_bytes_are_taken_only_before_the_first_frame() {
    let mut controller = Controller::new();
    let kept = kept_after_pairing(&mut controller);

    let mut discovering = engine();
    discovering.discover_request().unwrap();
    assert!(!discovering.restore_kept(&kept), "taken mid-Discover");

    let mut discovered = engine();
    assert!(!discover(&mut discovered, &controller));
    assert!(!discovered.restore_kept(&kept), "taken after Discover");
    discovered.reset_link();
    assert!(!discovered.restore_kept(&kept), "taken on a later link");

    let mut engine = relaunched(&kept);
    assert!(!engine.restore_kept(&kept), "taken twice");
    assert!(discover(&mut engine, &controller));
}

/// A reset while this session is enrolled leaves nothing to prove with: the
/// printed secret went at Pair, so the setup code has to be scanned again.
#[test]
fn a_reset_after_pairing_ends_the_session() {
    let mut engine = engine();
    let mut controller = Controller::new();
    assert!(!discover(&mut engine, &controller));
    pair(&mut engine, &mut controller);
    engine.reset_link();
    controller.epoch = Epoch::new(2).unwrap();
    for _ in 0..2 {
        let request = engine.discover_request().unwrap();
        assert_eq!(
            engine
                .discover_reply(&controller.discover(&request))
                .unwrap_err(),
            SetupFailure::ControllerReset
        );
        assert!(!engine.is_enrolled());
        assert!(engine.kept_enrolment().is_none());
        engine.reset_link();
    }
}
