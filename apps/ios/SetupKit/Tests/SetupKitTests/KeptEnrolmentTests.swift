import Foundation
import Testing

@testable import SetupKit

/// Keeps nothing: every launch pairs.
struct NoEnrolmentStore: EnrolmentStore {
  func load(deviceID: String) -> Data? { nil }
  func save(_ enrolment: Data, deviceID: String) throws {}
}

/// Keeps entries in memory, or refuses every save.
final class MemoryEnrolmentStore: EnrolmentStore, @unchecked Sendable {
  struct Refused: Error {}
  private let lock = NSLock()
  private var entries: [String: Data]
  private let refusesSaves: Bool
  init(_ entries: [String: Data] = [:], refusesSaves: Bool = false) {
    self.entries = entries
    self.refusesSaves = refusesSaves
  }
  subscript(deviceID: String) -> Data? { lock.withLock { entries[deviceID] } }
  func load(deviceID: String) -> Data? { self[deviceID] }
  func save(_ enrolment: Data, deviceID: String) throws {
    if refusesSaves { throw Refused() }
    lock.withLock { entries[deviceID] = enrolment }
  }
}

private actor Transport: FrameTransport {
  func open() async throws(TransportError) {}
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async {}
}

/// Holds a credential the way the Rust engine does: the setup code, a kept
/// enrolment not yet proven, or an enrolment.
actor KeptClient: ControllerClient {
  enum Credential: Equatable {
    case code
    case kept(Data)
    case enrolled(Data)
  }
  /// What the controller does with a kept enrolment.
  enum Controller { case accepts, otherEpoch, refusesHello, wasReset }
  static let deviceID = "abcd"
  static let paired = Data([0x01, 0xAA])
  let controller: Controller
  private(set) var credential = Credential.code
  private(set) var calls: [String] = []
  init(_ controller: Controller) { self.controller = controller }
  /// A client resumed from `kept` with no setup code, as a relaunch builds it.
  init(_ controller: Controller, resuming kept: Data) {
    self.controller = controller
    credential = .kept(kept)
  }

  func restore(from store: any EnrolmentStore) async {
    if let kept = store.load(deviceID: Self.deviceID) { credential = .kept(kept) }
  }
  func isEnrolled() async -> Bool { credential != .code }
  func keep(in store: any EnrolmentStore) async throws {
    guard case .enrolled(let bytes) = credential else { return }
    try store.save(bytes, deviceID: Self.deviceID)
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append("discover")
    if controller == .wasReset { throw .controllerReset }
    if case .kept = credential, controller == .otherEpoch { credential = .code }
    return ControllerSummary(deviceID: Self.deviceID)
  }
  func pair() async throws(SetupFailure) {
    calls.append("pair")
    credential = .enrolled(Self.paired)
  }
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append("hello")
    if case .kept(let bytes) = credential {
      guard controller != .refusesHello else {
        credential = .code
        throw .enrolmentRefused
      }
      credential = .enrolled(bytes)
    }
    return SessionReport(reportsWiFi: false)
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    calls.append("read")
    return NetworkSettings(version: 1, ssid: nil, passphraseSet: false, country: nil, hostname: nil)
  }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan { throw .protocolError }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus { throw .protocolError }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  { expectedVersion + 1 }
  func setTime(_ date: Date) async throws(SetupFailure) {}
  func close() async {}
}
private struct Factory: ControllerClientFactory {
  let client: KeptClient
  /// Built by a relaunch when the store keeps an enrolment for its controller.
  var resumed: KeptClient?
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { client }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    guard store.load(deviceID: deviceID) != nil else { return nil }
    return resumed
  }
}
/// Remembers the last controller in memory.
final class MemoryLastController: LastControllerStore, @unchecked Sendable {
  private let lock = NSLock()
  private var deviceID: String?
  init(_ deviceID: String? = nil) { self.deviceID = deviceID }
  func load() -> String? { lock.withLock { deviceID } }
  func save(_ deviceID: String?) { lock.withLock { self.deviceID = deviceID } }
}
/// The pairing window never closes in these tests.
@MainActor private struct OpenWindowClock: SetupClock {
  var now: Duration { .zero }
  func sleep(until deadline: Duration) async throws { throw CancellationError() }
}

private let kept = Data([0x01, 0x55])
private let editing = SetupFlow.State.editingNetwork(
  NetworkSettings(version: 1, ssid: nil, passphraseSet: false, country: nil, hostname: nil))

@MainActor private func connected(_ client: KeptClient, _ store: MemoryEnrolmentStore) async throws
  -> SetupFlow
{
  let transport = Transport()
  let flow = SetupFlow(
    factory: Factory(client: client), store: store, transportFactory: { transport },
    clock: OpenWindowClock())
  try flow.submitCode("valid")
  await flow.connect()
  return flow
}

/// The failure the issue came from: a relaunch with the enrolment kept goes
/// to the network without asking for the pairing window.
@Test @MainActor func aKeptEnrolmentSkipsThePairingWindow() async throws {
  let client = KeptClient(.accepts)
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let flow = try await connected(client, store)
  #expect(flow.state == editing)
  #expect(await client.calls == ["discover", "hello", "read"])
  #expect(!flow.keptEnrolmentLost)
  #expect(store[KeptClient.deviceID] == kept)
}

@Test @MainActor func aSuccessfulPairIsKept() async throws {
  let client = KeptClient(.accepts)
  let store = MemoryEnrolmentStore()
  let flow = try await connected(client, store)
  #expect(flow.state == .openWindow)
  #expect(!flow.keptEnrolmentLost)
  await flow.confirmWindowOpened()
  #expect(flow.state == editing)
  #expect(store[KeptClient.deviceID] == KeptClient.paired)
}

/// P-222: a kept enrolment for another epoch pairs again on the same
/// connection, and the new enrolment replaces it.
@Test @MainActor func aKeptEnrolmentForAnotherEpochPairsAgain() async throws {
  let client = KeptClient(.otherEpoch)
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let flow = try await connected(client, store)
  #expect(flow.state == .openWindow)
  #expect(flow.keptEnrolmentLost)
  #expect(await client.calls == ["discover"])
  await flow.confirmWindowOpened()
  #expect(flow.state == editing)
  #expect(await client.calls == ["discover", "discover", "pair", "hello", "read"])
  #expect(store[KeptClient.deviceID] == KeptClient.paired)
}

/// A refused Hello asks for the window; the old entry stays until the new
/// Pair succeeds.
@Test @MainActor func aRefusedKeptEnrolmentPairsAfterTheWindowOpens() async throws {
  let client = KeptClient(.refusesHello)
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let flow = try await connected(client, store)
  #expect(flow.state == .failed(.enrolmentRefused, .openWindow))
  #expect(flow.keptEnrolmentLost)
  #expect(store[KeptClient.deviceID] == kept)
  await flow.retry()
  #expect(flow.state == .openWindow)
  await flow.confirmWindowOpened()
  #expect(flow.state == editing)
  #expect(store[KeptClient.deviceID] == KeptClient.paired)
  await flow.reset()
  #expect(!flow.keptEnrolmentLost)
}

@Test @MainActor func aStoreThatCannotSaveStillFinishesPairing() async throws {
  let client = KeptClient(.accepts)
  let store = MemoryEnrolmentStore(refusesSaves: true)
  let flow = try await connected(client, store)
  await flow.confirmWindowOpened()
  #expect(flow.state == editing)
  #expect(store[KeptClient.deviceID] == nil)
}

/// Reset after this session paired: the printed secret is gone, so the only
/// way on is scanning the code again.
@Test @MainActor func aResetControllerSendsThePersonBackToTheCode() async throws {
  let client = KeptClient(.wasReset)
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let flow = try await connected(client, store)
  #expect(flow.state == .failed(.controllerReset, .enterCode))
  await flow.retry()
  #expect(flow.state == .enterCode)
}

@MainActor private func relaunched(
  _ resumed: KeptClient, _ store: MemoryEnrolmentStore, _ lastController: MemoryLastController
) -> SetupFlow {
  let transport = Transport()
  return SetupFlow(
    factory: Factory(client: KeptClient(.accepts), resumed: resumed), store: store,
    transportFactory: { transport }, clock: OpenWindowClock(), lastController: lastController)
}

/// The failure this came from: pairing, closing the app and opening it again
/// asked for the code once more. The relaunch goes back to the network.
@Test @MainActor func aPairedSetupContinuesAfterARelaunch() async throws {
  let store = MemoryEnrolmentStore()
  let lastController = MemoryLastController()
  let first = SetupFlow(
    factory: Factory(client: KeptClient(.accepts)), store: store, transportFactory: { Transport() },
    clock: OpenWindowClock(), lastController: lastController)
  #expect(first.state == .enterCode)
  try first.submitCode("valid")
  await first.connect()
  await first.confirmWindowOpened()
  #expect(first.state == editing)
  #expect(lastController.load() == KeptClient.deviceID)

  let resumed = KeptClient(.accepts, resuming: KeptClient.paired)
  let flow = relaunched(resumed, store, lastController)
  #expect(flow.state == .connecting)
  #expect(flow.resumed)
  await flow.connect()
  #expect(flow.state == editing)
  #expect(await resumed.calls == ["discover", "hello", "read"])
}

@Test @MainActor func noLastControllerStartsAtTheCode() {
  let flow = relaunched(
    KeptClient(.accepts, resuming: kept), MemoryEnrolmentStore([KeptClient.deviceID: kept]),
    MemoryLastController())
  #expect(flow.state == .enterCode)
  #expect(!flow.resumed)
}

/// No kept enrolment to continue with, such as a Keychain that was cleared:
/// the code is needed, and the last controller is forgotten.
@Test @MainActor func aLastControllerWithNoEnrolmentStartsAtTheCode() {
  let lastController = MemoryLastController(KeptClient.deviceID)
  let flow = relaunched(
    KeptClient(.accepts, resuming: kept), MemoryEnrolmentStore(), lastController)
  #expect(flow.state == .enterCode)
  #expect(lastController.load() == nil)
}

/// A resumed session has no setup code, so a refused enrolment or a reset
/// controller sends the person to scan it.
@Test(arguments: [KeptClient.Controller.refusesHello, .wasReset])
@MainActor func aResumeTheControllerRefusesAsksForTheCode(controller: KeptClient.Controller)
  async throws
{
  let lastController = MemoryLastController(KeptClient.deviceID)
  let flow = relaunched(
    KeptClient(controller, resuming: kept), MemoryEnrolmentStore([KeptClient.deviceID: kept]),
    lastController)
  await flow.connect()
  guard case .failed(_, let target) = flow.state else {
    Issue.record("expected a failure, got \(flow.state)")
    return
  }
  #expect(target == .enterCode)
  #expect(lastController.load() == nil)
  await flow.retry()
  #expect(flow.state == .enterCode)
}

/// The failure from issue #18: after a network was written, a relaunch asked
/// for the code and the pairing window. It reconnects and reads the network,
/// so the phone can change or forget it.
@Test @MainActor func aRelaunchAfterAWrittenNetworkReopensIt() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let lastController = MemoryLastController(KeptClient.deviceID)
  let flow = relaunched(KeptClient(.accepts, resuming: kept), store, lastController)
  await flow.connect()
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(2))
  await flow.finish()
  #expect(flow.state == .finished(version: 2, timeSet: false))
  #expect(lastController.load() == KeptClient.deviceID)

  let reopened = KeptClient(.accepts, resuming: kept)
  let next = relaunched(reopened, store, lastController)
  #expect(next.state == .connecting)
  await next.connect()
  #expect(next.state == editing)
  #expect(await reopened.calls == ["discover", "hello", "read"])
}

/// After a written network, the kept enrolment may stop working; the
/// relaunch then asks for the code and forgets the controller.
@Test @MainActor func aRefusedReopenAfterAWriteAsksForTheCode() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let lastController = MemoryLastController(KeptClient.deviceID)
  let first = relaunched(KeptClient(.accepts, resuming: kept), store, lastController)
  await first.connect()
  await first.writeNetwork(
    NetworkChange(ssid: nil, passphrase: nil, country: "CA", hostname: "unit"))
  await first.finish()

  let next = relaunched(KeptClient(.refusesHello, resuming: kept), store, lastController)
  await next.connect()
  #expect(next.state == .failed(.enrolmentRefused, .enterCode))
  #expect(lastController.load() == nil)
}

@Test @MainActor func startingOverForgetsTheLastController() async throws {
  let lastController = MemoryLastController(KeptClient.deviceID)
  let flow = relaunched(
    KeptClient(.accepts, resuming: kept), MemoryEnrolmentStore([KeptClient.deviceID: kept]),
    lastController)
  #expect(flow.state == .connecting)
  await flow.reset()
  #expect(flow.state == .enterCode)
  #expect(!flow.resumed)
  #expect(lastController.load() == nil)
}
