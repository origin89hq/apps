import Foundation
import Testing

@testable import SetupKit

/// Keeps nothing: every launch pairs.
struct NoEnrolmentStore: EnrolmentStore {
  func load(deviceID: String) -> Data? { nil }
  func save(_ enrolment: Data, deviceID: String) throws {}
  func remove(deviceID: String) throws {}
  func removeAll() throws {}
  func storedDeviceIDs() throws -> [String] { [] }
}

/// Keeps entries in memory, or refuses every save or removal.
final class MemoryEnrolmentStore: EnrolmentStore, @unchecked Sendable {
  struct Refused: Error {}
  private let lock = NSLock()
  private var entries: [String: Data]
  private let refusesSaves: Bool
  private let refusesRemovals: Bool
  private let refusesReads: Bool
  init(
    _ entries: [String: Data] = [:], refusesSaves: Bool = false, refusesRemovals: Bool = false,
    refusesReads: Bool = false
  ) {
    self.entries = entries
    self.refusesReads = refusesReads
    self.refusesSaves = refusesSaves
    self.refusesRemovals = refusesRemovals
  }
  var isEmpty: Bool { lock.withLock { entries.isEmpty } }
  subscript(deviceID: String) -> Data? { lock.withLock { entries[deviceID] } }
  func load(deviceID: String) -> Data? { self[deviceID] }
  func save(_ enrolment: Data, deviceID: String) throws {
    if refusesSaves { throw Refused() }
    lock.withLock { entries[deviceID] = enrolment }
  }
  func remove(deviceID: String) throws {
    if refusesRemovals { throw Refused() }
    lock.withLock { entries[deviceID] = nil }
  }
  func removeAll() throws {
    if refusesRemovals { throw Refused() }
    lock.withLock { entries.removeAll() }
  }
  func storedDeviceIDs() throws -> [String] {
    if refusesReads { throw Refused() }
    return lock.withLock { entries.keys.sorted() }
  }
}

private actor Transport: FrameTransport {
  private(set) var opens = 0
  private(set) var closes = 0
  func open() async throws(TransportError) { opens += 1 }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async { closes += 1 }
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

@MainActor private func connected(
  _ client: KeptClient, _ store: MemoryEnrolmentStore, transport: Transport = Transport()
) async throws -> SetupFlow {
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

/// P-222: a kept enrolment for another epoch pairs again, and the new
/// enrolment replaces it. Opening the window can restart the comms module, so
/// the link that found out is closed and a new one opens once it is open.
@Test @MainActor func aKeptEnrolmentForAnotherEpochPairsAgain() async throws {
  let client = KeptClient(.otherEpoch)
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let transport = Transport()
  let flow = try await connected(client, store, transport: transport)
  #expect(flow.state == .openWindow)
  #expect(flow.keptEnrolmentLost)
  #expect(await client.calls == ["discover"])
  #expect(flow.link == nil)
  #expect(await transport.opens == 1)
  #expect(await transport.closes == 1)
  await flow.confirmWindowOpened()
  #expect(await transport.opens == 2)
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

/// Issue #24: after forgetting a controller, its code pairs again instead of
/// resuming the kept enrolment, and a relaunch does not reconnect to it.
@Test @MainActor func aForgottenControllerPairsAgain() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept, "other": kept])
  let lastController = MemoryLastController(KeptClient.deviceID)
  let addresses = MemoryAddresses([KeptClient.deviceID: "192.0.2.7", "other": "192.0.2.8"])
  let flow = SetupFlow(
    factory: Factory(client: KeptClient(.accepts), resumed: KeptClient(.accepts, resuming: kept)),
    store: store, transportFactory: { Transport() }, clock: OpenWindowClock(),
    lastController: lastController, addresses: addresses)
  await flow.connect()
  #expect(flow.state == editing)
  #expect(flow.knownController == KeptClient.deviceID)

  try await flow.forgetController()
  #expect(flow.state == .enterCode)
  #expect(flow.knownController == nil)
  #expect(store[KeptClient.deviceID] == nil)
  #expect(store["other"] == kept)
  #expect(addresses.load(deviceID: KeptClient.deviceID) == nil)
  #expect(addresses.load(deviceID: "other") == "192.0.2.8")
  #expect(lastController.load() == nil)

  #expect(
    relaunched(KeptClient(.accepts, resuming: kept), store, lastController).state == .enterCode)
  let client = KeptClient(.accepts)
  let next = try await connected(client, store)
  #expect(next.state == .openWindow)
  #expect(await client.calls.isEmpty)
}

/// A controller this session paired with is forgotten too, before a relaunch.
@Test @MainActor func aControllerPairedThisSessionCanBeForgotten() async throws {
  let store = MemoryEnrolmentStore()
  let flow = try await connected(KeptClient(.accepts), store)
  await flow.confirmWindowOpened()
  #expect(store[KeptClient.deviceID] == KeptClient.paired)
  try await flow.forgetController()
  #expect(flow.state == .enterCode)
  #expect(store.isEmpty)
}

@Test @MainActor func withNoKnownControllerForgetKeepsTheStore() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept])
  let flow = SetupFlow(
    factory: Factory(client: KeptClient(.accepts)), store: store, transportFactory: { Transport() },
    clock: OpenWindowClock())
  #expect(flow.knownController == nil)
  try await flow.forgetController()
  #expect(flow.state == .enterCode)
  #expect(store[KeptClient.deviceID] == kept)
}

/// A store that cannot remove the enrolment reports it; the flow has still
/// started over and closed its connection.
@Test @MainActor func aFailedRemovalIsReported() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept], refusesRemovals: true)
  let lastController = MemoryLastController(KeptClient.deviceID)
  let flow = relaunched(KeptClient(.accepts, resuming: kept), store, lastController)
  await flow.connect()
  await #expect(throws: MemoryEnrolmentStore.Refused.self) { try await flow.forgetController() }
  #expect(flow.state == .enterCode)
  #expect(store[KeptClient.deviceID] == kept)
  await #expect(throws: MemoryEnrolmentStore.Refused.self) {
    try await flow.forgetAllControllers()
  }
}

@Test @MainActor func forgettingAllControllersClearsEveryEnrolment() async throws {
  let store = MemoryEnrolmentStore([KeptClient.deviceID: kept, "other": kept])
  let lastController = MemoryLastController(KeptClient.deviceID)
  let addresses = MemoryAddresses([KeptClient.deviceID: "192.0.2.7", "other": "192.0.2.8"])
  let flow = SetupFlow(
    factory: Factory(client: KeptClient(.accepts), resumed: KeptClient(.accepts, resuming: kept)),
    store: store, transportFactory: { Transport() }, clock: OpenWindowClock(),
    lastController: lastController, addresses: addresses)
  #expect(flow.state == .connecting)
  try await flow.forgetAllControllers()
  #expect(flow.state == .enterCode)
  #expect(store.isEmpty)
  #expect(addresses.load(deviceID: "other") == nil)
  #expect(lastController.load() == nil)
}

/// Pairs, then holds its enrolment save until released.
private actor GatedKeepClient: ControllerClient {
  private(set) var isKeeping = false
  private var release: CheckedContinuation<Void, Never>?
  func restore(from store: any EnrolmentStore) async {}
  func isEnrolled() async -> Bool { false }
  func keep(in store: any EnrolmentStore) async throws {
    isKeeping = true
    await withCheckedContinuation { release = $0 }
    try store.save(KeptClient.paired, deviceID: KeptClient.deviceID)
  }
  func releaseKeep() {
    release?.resume()
    release = nil
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    ControllerSummary(deviceID: KeptClient.deviceID)
  }
  func pair() async throws(SetupFailure) {}
  func hello() async throws(SetupFailure) -> SessionReport { SessionReport(reportsWiFi: false) }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings { throw .protocolError }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan { throw .protocolError }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus { throw .protocolError }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  { throw .protocolError }
  func setTime(_ date: Date) async throws(SetupFailure) {}
  func close() async {}
}
private struct GatedFactory: ControllerClientFactory {
  let client: GatedKeepClient
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { client }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? { nil }
}

/// A forget while the new enrolment is being saved waits for the save, so
/// the enrolment does not come back after the removal.
@Test @MainActor func forgettingDuringTheSaveRemovesTheSavedEnrolment() async throws {
  let client = GatedKeepClient()
  let store = MemoryEnrolmentStore()
  let flow = SetupFlow(
    factory: GatedFactory(client: client), store: store, transportFactory: { Transport() },
    clock: OpenWindowClock())
  try flow.submitCode("valid")
  await flow.connect()
  #expect(flow.state == .openWindow)
  let pairing = Task { await flow.confirmWindowOpened() }
  while await !client.isKeeping { await Task.yield() }
  let forgetting = Task { try await flow.forgetController() }
  for _ in 0..<50 { await Task.yield() }
  await client.releaseKeep()
  try await forgetting.value
  await pairing.value
  #expect(flow.state == .enterCode)
  #expect(store.isEmpty)
}
