import Foundation
import Origin89SetupCore
import SetupKit
import os

/// Builds a ``SetupKit/ControllerClient`` over the Rust KM43 core. Keys, the
/// printed secret and the session stay in Rust; this side moves frames, and
/// the encoded enrolment between the core and the store.
public struct RustControllerClientFactory: ControllerClientFactory {
  /// What the controller lists this phone as. A re-pair with the same label
  /// reclaims the same row (P-078), so it must be stable and distinct per device.
  public let label: String

  public init(label: String) { self.label = label }

  public func client(setupCode: String, transport: any FrameTransport)
    throws(SetupKit.SetupCodeError)
    -> any ControllerClient
  {
    let session: Origin89SetupCore.SetupSession
    do {
      session = try Origin89SetupCore.SetupSession(setupCode: setupCode, label: label)
    } catch {
      throw .malformed
    }
    return RustControllerClient(session: session, transport: transport)
  }

  public func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    guard var kept = store.load(deviceID: deviceID) else { return nil }
    defer { kept.resetBytes(in: kept.startIndex..<kept.endIndex) }
    guard
      let session = Origin89SetupCore.resumeSession(deviceId: deviceID, kept: kept, label: label)
    else { return nil }
    return RustControllerClient(session: session, transport: transport)
  }
}

/// One controller, one Rust `SetupSession`, driven over a ``FrameTransport``.
actor RustControllerClient: ControllerClient {
  /// Frames that answer nothing outstanding (P-024) before a step gives up.
  private static let ignoredFrameLimit = 16
  /// Message types, `req_id`s, outcomes and error codes; never a payload.
  private static let log = Logger(subsystem: SetupLog.subsystem, category: "km43")

  private let session: Origin89SetupCore.SetupSession
  private let transport: any FrameTransport

  init(session: Origin89SetupCore.SetupSession, transport: any FrameTransport) {
    self.session = session
    self.transport = transport
  }

  func restore(from store: any EnrolmentStore) async {
    guard var kept = store.load(deviceID: session.deviceId()) else { return }
    defer { kept.resetBytes(in: kept.startIndex..<kept.endIndex) }
    // Refused bytes leave the session pairing, which `isEnrolled()` reports.
    _ = session.restoreKept(kept: kept)
  }

  func isEnrolled() async -> Bool { session.isEnrolled() }

  func keep(in store: any EnrolmentStore) async throws {
    guard var kept = session.keptEnrolment() else { return }
    defer { kept.resetBytes(in: kept.startIndex..<kept.endIndex) }
    try store.save(kept, deviceID: session.deviceId())
  }

  func discover() async throws(SetupKit.SetupFailure) -> SetupKit.ControllerSummary {
    // Every discover starts a fresh link: the transport may have reconnected.
    session.resetLink()
    let found = try await exchange(session.discoverRequest, session.discoverReply)
    return SetupKit.ControllerSummary(deviceID: found.deviceId)
  }

  func pair() async throws(SetupKit.SetupFailure) {
    // After a reconnect an enrolled session goes straight to Hello.
    guard !session.isEnrolled() else { return }
    _ = try await exchange(session.pairRequest, session.pairReply)
  }

  func hello() async throws(SetupKit.SetupFailure) -> SetupKit.SessionReport {
    let info = try await exchange(session.helloRequest, session.helloReply)
    return SetupKit.SessionReport(reportsWiFi: info.reportsWifi)
  }

  func scanWiFi(refresh: Bool) async throws(SetupKit.SetupFailure) -> SetupKit.NetworkScan {
    let session = self.session
    let scan = try await exchange(
      { try session.wifiScanRequest(refresh: refresh) }, session.wifiScanReply)
    return SetupKit.NetworkScan(
      progress: Self.progress(scan.progress), refused: scan.refused.map(Self.refusal),
      networks: scan.heard?.networks.map(Self.network),
      unlisted: Int(scan.heard?.unlisted ?? 0))
  }

  func wifiStatus() async throws(SetupKit.SetupFailure) -> SetupKit.WiFiStatus {
    let status = try await exchange(session.wifiStatusRequest, session.wifiStatusReply)
    return SetupKit.WiFiStatus(
      section: status.section,
      radio: status.radio.map { (version: $0.version, state: Self.radio($0.state)) })
  }

  func readNetwork() async throws(SetupKit.SetupFailure) -> SetupKit.NetworkSettings {
    let read = try await exchange(session.readNetworkRequest, session.readNetworkReply)
    return SetupKit.NetworkSettings(
      version: read.version, ssid: read.ssid, passphraseSet: read.passphraseSet,
      country: read.country, hostname: read.hostname)
  }

  func writeNetwork(_ change: SetupKit.NetworkChange, expectedVersion: UInt32)
    async throws(SetupKit.SetupFailure) -> UInt32
  {
    let rust = Origin89SetupCore.NetworkChange(
      ssid: change.ssid, passphrase: change.passphrase, country: change.country,
      hostname: change.hostname)
    let session = self.session
    return try await exchange(
      { try session.writeNetworkRequest(change: rust, expectedVersion: expectedVersion) },
      session.writeNetworkReply)
  }

  func setTime(_ date: Date) async throws(SetupKit.SetupFailure) {
    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
    // A date before 1970 or past the u64 range is no time the controller accepts.
    guard let atMs = UInt64(exactly: milliseconds) else { throw .timeRejected }
    let session = self.session
    _ = try await exchange({ try session.setTimeRequest(atMs: atMs) }, session.setTimeReply)
  }

  /// Abandon the session: the Rust core forgets the session key and link, and
  /// keeps the enrolment for a later Hello. The transport is the flow's; it
  /// opens and closes it, so this does not touch the connection.
  func close() async { session.resetLink() }

  /// Send one request and receive until the core accepts a reply to it.
  private func exchange<Reply>(
    _ request: () throws -> Data, _ reply: (Data) throws -> Reply?
  ) async throws(SetupKit.SetupFailure) -> Reply {
    let frame: Data
    do { frame = try request() } catch {
      let failure = Self.failure(error)
      Self.log.error("not sent: \(String(describing: failure), privacy: .public)")
      throw failure
    }
    let sent = Self.label(session.frameNote(frame: frame))
    Self.log.info("send \(sent, privacy: .public)")
    do { try await transport.send(frame) } catch {
      let failure = Self.failure(error)
      Self.log.error(
        "send \(sent, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
      throw failure
    }
    for _ in 0...Self.ignoredFrameLimit {
      let incoming: Data
      do { incoming = try await transport.receive() } catch {
        let failure = Self.failure(error)
        Self.log.error(
          "no answer to \(sent, privacy: .public): \(String(describing: failure), privacy: .public)"
        )
        throw failure
      }
      // Noted before judging: a failure ends the session and its key.
      let received = Self.label(session.frameNote(frame: incoming))
      do {
        if let answer = try reply(incoming) {
          Self.log.info("received \(received, privacy: .public): accepted")
          return answer
        }
        Self.log.debug("received \(received, privacy: .public): answers nothing outstanding")
      } catch {
        let failure = Self.failure(error)
        Self.log.error(
          "received \(received, privacy: .public): \(String(describing: failure), privacy: .public)"
        )
        throw failure
      }
    }
    Self.log.error(
      "no answer to \(sent, privacy: .public) among \(Self.ignoredFrameLimit + 1) frames")
    throw .protocolError
  }

  /// A frame's type and `req_id`, and an `Error`'s code, for the log.
  static func label(_ note: FrameNote?) -> String {
    guard let note else { return "an unreadable frame" }
    let head = "\(note.kind) req \(note.reqId)"
    switch note.error {
    case nil: return head
    case .verified(let code): return "\(head) code \(code)"
    case .bare(let code): return "\(head) code \(code) (bare, unauthenticated)"
    case .unreadable: return "\(head) code unreadable"
    }
  }

  static func progress(_ progress: Origin89SetupCore.ScanProgress) -> SetupKit.ScanProgress {
    switch progress {
    case .none: .none
    case .running: .running
    case .complete: .complete
    case .failed: .failed
    }
  }

  static func refusal(_ refusal: Origin89SetupCore.ScanRefusal) -> SetupKit.ScanRefusal {
    switch refusal {
    case .tooSoon: .tooSoon
    case .radioOff: .radioOff
    case .linkDown: .linkDown
    case .unauthorised: .unauthorised
    }
  }

  static func network(_ heard: Origin89SetupCore.HeardNetwork) -> SetupKit.HeardNetwork {
    let security: SetupKit.NetworkSecurity =
      switch heard.security {
      case .open: .open
      case .wpa2Personal: .wpa2Personal
      case .wpa3Personal: .wpa3Personal
      case .other: .other
      }
    let band: SetupKit.NetworkBand =
      switch heard.band {
      case .ghz24: .ghz24
      case .ghz5: .ghz5
      case .ghz6: .ghz6
      }
    return SetupKit.HeardNetwork(
      ssid: heard.ssid, rssi: heard.rssi, security: security, band: band, channel: heard.channel)
  }

  static func radio(_ state: Origin89SetupCore.RadioState) -> SetupKit.RadioState {
    switch state {
    case .off: .off
    case .joining: .joining
    case .joined(let address): .joined(address: address)
    case .failed(let reason): .failed(joinFailure(reason))
    }
  }

  static func joinFailure(_ reason: Origin89SetupCore.JoinFailure) -> SetupKit.JoinFailure {
    switch reason {
    case .authFailed: .authFailed
    case .notFound: .notFound
    case .noIp: .noIP
    case .lost: .lost
    case .other: .other
    }
  }

  static func failure(_ error: TransportError) -> SetupKit.SetupFailure {
    switch error {
    case .unreachable: .bluetoothUnavailable
    case .dropped: .connectionDropped
    case .timedOut: .timedOut
    }
  }

  static func failure(_ error: any Error) -> SetupKit.SetupFailure {
    guard let failure = error as? Origin89SetupCore.SetupFailure else { return .protocolError }
    return switch failure {
    case .WindowClosed: .windowClosed
    case .WrongProof: .wrongProof
    case .TableFull: .tableFull
    case .StaleVersion: .staleVersion
    case .InvalidConfig: .invalidConfig
    case .ControllerMismatch: .controllerMismatch
    case .EnrolmentRefused: .enrolmentRefused
    case .ControllerReset: .controllerReset
    case .ConnectionDropped: .connectionDropped
    case .TimeRejected: .timeRejected
    case .TimeNeedsButton: .timeNeedsButton
    case .ProtocolError: .protocolError
    }
  }
}
