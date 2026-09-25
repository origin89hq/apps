import Foundation
import Testing

@testable import SetupKit

private actor Transport: FrameTransport {
  private(set) var closes = 0
  private(set) var opens = 0
  /// Every later open fails with this, like a controller that stays away.
  var openFailure: TransportError?
  func failOpens(with error: TransportError?) { openFailure = error }
  func open() async throws(TransportError) {
    opens += 1
    if let openFailure { throw openFailure }
  }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async { closes += 1 }
}

/// A controller that reports Wi-Fi, answering scans and status reads from
/// scripts; the last answer repeats.
private actor WiFiClient: ControllerClient {
  enum Call: Sendable, Equatable {
    case discover, pair, hello, read, write, time
    case scan(refresh: Bool)
    case status
  }
  let reportsWiFi: Bool
  var scans: [NetworkScan]
  var statuses: [WiFiStatus]
  var scanFailure: SetupFailure?
  var statusFailure: SetupFailure?
  var helloFailure: SetupFailure?
  private(set) var calls: [Call] = []
  /// The next scan or status read waits for `release()`, like a reply still
  /// on its way.
  var holdScan = false
  var holdStatus = false
  private var held: CheckedContinuation<Void, Never>?
  var isHolding: Bool { held != nil }
  let settings: NetworkSettings

  init(
    reportsWiFi: Bool = true, scans: [NetworkScan] = [], statuses: [WiFiStatus] = [],
    // No network held: after Pair the person chooses one.
    settings: NetworkSettings = NetworkSettings(
      version: 7, ssid: nil, passphraseSet: false, country: "CA", hostname: "unit")
  ) {
    self.reportsWiFi = reportsWiFi
    self.scans = scans
    self.statuses = statuses
    self.settings = settings
  }
  func failScans(with failure: SetupFailure) { scanFailure = failure }
  func failStatuses(with failure: SetupFailure?) { statusFailure = failure }
  func failHello(with failure: SetupFailure?) { helloFailure = failure }
  func holdNextScan() { holdScan = true }
  func holdNextStatus() { holdStatus = true }
  func release() {
    held?.resume()
    held = nil
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append(.discover)
    return ControllerSummary(deviceID: "abcd")
  }
  private var enrolled = false
  func restore(from store: any EnrolmentStore) async {}
  func isEnrolled() async -> Bool { enrolled }
  func keep(in store: any EnrolmentStore) async throws {}
  func pair() async throws(SetupFailure) {
    calls.append(.pair)
    enrolled = true
  }
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append(.hello)
    if let helloFailure { throw helloFailure }
    return SessionReport(reportsWiFi: reportsWiFi)
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    calls.append(.read)
    return settings
  }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  {
    calls.append(.write)
    written = expectedVersion
    return expectedVersion + 1
  }
  /// The `expected_version` of the last write.
  private(set) var written: UInt32?
  func setTime(_ date: Date) async throws(SetupFailure) { calls.append(.time) }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan {
    calls.append(.scan(refresh: refresh))
    if holdScan {
      holdScan = false
      await withCheckedContinuation { held = $0 }
    }
    // A cancelled read ends the connection, as `BluetoothTransport` does.
    if Task.isCancelled { throw .connectionDropped }
    if let scanFailure { throw scanFailure }
    return scans.count > 1 ? scans.removeFirst() : scans[0]
  }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus {
    calls.append(.status)
    if holdStatus {
      holdStatus = false
      await withCheckedContinuation { held = $0 }
    }
    if Task.isCancelled { throw .connectionDropped }
    if let statusFailure { throw statusFailure }
    return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
  }
  func close() async {}
}

private struct Factory: ControllerClientFactory {
  let client: WiFiClient
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { client }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? { nil }
}

/// Poll sleeps pass at once and move the clock; the 120-second pairing window
/// waits until the test ends.
@MainActor private final class PollClock: SetupClock {
  var now: Duration = .zero
  private var window: CheckedContinuation<Void, any Error>?
  func sleep(until deadline: Duration) async throws {
    if deadline - now <= .seconds(10) {
      now = deadline
      await Task.yield()
      try Task.checkCancellation()
      return
    }
    try await withCheckedThrowingContinuation { window = $0 }
  }
  func finish() {
    window?.resume(throwing: CancellationError())
    window = nil
  }
}

private let cabin = HeardNetwork(
  ssid: "cabin", rssi: -48, security: .wpa3Personal, band: .ghz24, channel: 6)
private let running = NetworkScan(progress: .running, networks: nil)
private let complete = NetworkScan(progress: .complete, networks: [cabin], unlisted: 2)

@MainActor private func editing(
  _ client: WiFiClient, _ clock: PollClock, lastController: MemoryLastController? = nil
) async throws -> (SetupFlow, Transport) {
  let transport = Transport()
  let flow = SetupFlow(
    factory: Factory(client: client), store: NoEnrolmentStore(), transportFactory: { transport },
    clock: clock, lastController: lastController)
  try flow.submitCode("valid")
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .editingNetwork(client.settings))
  return (flow, transport)
}

/// Let the background task run until `done` holds, bounded.
@MainActor private func settle(_ done: () -> Bool) async {
  for _ in 0..<10_000 where !done() { await Task.yield() }
}

@Test @MainActor func aRefreshIsReadAgainUntilTheScanCompletes() async throws {
  let client = WiFiClient(scans: [running, running, complete])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  #expect(flow.reportsWiFi)
  flow.scanNetworks()
  #expect(flow.isScanning)
  await settle { !flow.isScanning }
  #expect(flow.scan == complete)
  #expect(
    await client.calls.suffix(3) == [
      .scan(refresh: true), .scan(refresh: false), .scan(refresh: false),
    ])
  #expect(flow.state == .editingNetwork(client.settings))
}

@Test @MainActor func aScanThatNeverCompletesIsGivenUp() async throws {
  let client = WiFiClient(scans: [running])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  flow.scanNetworks()
  await settle { !flow.isScanning }
  #expect(flow.scan == running)
  // One read at 0 s and one every 2 s up to the 20 s limit.
  let scans = await client.calls.filter { if case .scan = $0 { true } else { false } }
  #expect(scans.count == 11)
  #expect(clock.now == .seconds(20))
}

@Test @MainActor func aRefusedRefreshKeepsTheHeldList() async throws {
  let refused = NetworkScan(progress: .complete, refused: .tooSoon, networks: [cabin])
  let client = WiFiClient(scans: [refused])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  flow.scanNetworks()
  await settle { !flow.isScanning }
  #expect(flow.scan?.refused == .tooSoon)
  #expect(flow.scan?.networks == [cabin])
  #expect(await client.calls.last == .scan(refresh: true))
}

@Test @MainActor func aControllerWithoutBit8IsNeverScanned() async throws {
  let client = WiFiClient(reportsWiFi: false)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  #expect(!flow.reportsWiFi)
  flow.scanNetworks()
  #expect(!flow.isScanning)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  #expect(flow.join == .idle)
  #expect(await client.calls == [.discover, .pair, .hello, .read, .write])
}

@Test @MainActor func aLostConnectionWhileScanningFailsTheFlow() async throws {
  let client = WiFiClient(scans: [running])
  await client.failScans(with: .connectionDropped)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  flow.scanNetworks()
  await settle { if case .failed = flow.state { true } else { false } }
  #expect(flow.state == .failed(.connectionDropped, .connecting))
  #expect(await transport.closes == 1)
}

@Test @MainActor func aWriteLetsTheScanRequestInFlightFinish() async throws {
  let client = WiFiClient(
    scans: [running],
    statuses: [WiFiStatus(section: 8, radio: (version: 8, state: .joined(address: "10.0.0.2")))])
  await client.holdNextScan()
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  flow.scanNetworks()
  for _ in 0..<10_000 where await !client.isHolding { await Task.yield() }
  #expect(await client.isHolding)
  let write = Task {
    await flow.writeNetwork(
      NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  }
  // The write waits for the scan's answer instead of cancelling its read.
  for _ in 0..<100 { await Task.yield() }
  #expect(await client.calls.last == .scan(refresh: true))
  await client.release()
  await write.value
  #expect(flow.state == .written(8))
  #expect(await transport.closes == 0)
  // One scan, answered, then the write; the join watch reads status after it.
  #expect(
    await client.calls.filter { $0 != .status }.suffix(2) == [.scan(refresh: true), .write])
}

@Test @MainActor func settingTheTimeLetsTheStatusReadInFlightFinish() async throws {
  let client = WiFiClient(statuses: [WiFiStatus(section: 8, radio: (version: 8, state: .joining))])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  await client.holdNextStatus()
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  for _ in 0..<10_000 where await !client.isHolding { await Task.yield() }
  #expect(await client.isHolding)
  let time = Task { await flow.setTime(Date(timeIntervalSince1970: 1_700_000_000)) }
  for _ in 0..<100 { await Task.yield() }
  #expect(await client.calls.last == .status)
  await client.release()
  await time.value
  #expect(flow.state == .finished(version: 8, timeSet: true))
  #expect(await client.calls.suffix(2) == [.status, .time])
  // Only the close that finishes setup.
  #expect(await transport.closes == 1)
}

/// A network section the controller never wrote, or holds damaged (P-108).
private let unwritten = NetworkSettings(
  version: 0, ssid: nil, passphraseSet: false, country: nil, hostname: nil)
/// P-218: with no network there is no country, so the radio cannot scan.
private let radioOff = NetworkScan(progress: .none, refused: .radioOff, networks: nil)
private let joinedFirst = WiFiStatus(
  section: 1, radio: (version: 1, state: .joined(address: "10.0.0.2")))

@Test @MainActor func anUnwrittenSectionIsWrittenAgainstVersion0() async throws {
  let client = WiFiClient(scans: [radioOff], statuses: [joinedFirst], settings: unwritten)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  #expect(flow.network == unwritten)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(await client.written == 0)
  #expect(flow.state == .written(1))
  #expect(await transport.closes == 0)
}

@Test @MainActor func anUnwrittenSectionCannotKeepAPassphrase() async throws {
  let client = WiFiClient(settings: unwritten)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  // No SSID and no passphrase are held, so a write without one is refused here.
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: nil, country: "CA", hostname: "unit"))
  #expect(flow.state == .failed(.invalidConfig, .editingNetwork))
  #expect(await !client.calls.contains(.write))
  await flow.retry()
  #expect(flow.state == .editingNetwork(unwritten))
}

@Test @MainActor func aRadioOffRefusalLeavesTheNetworkToBeTyped() async throws {
  let client = WiFiClient(scans: [radioOff], statuses: [joinedFirst], settings: unwritten)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  flow.scanNetworks()
  await settle { !flow.isScanning }
  // One refused refresh, no polling, and the flow stays on the network.
  #expect(flow.scan == radioOff)
  #expect(await client.calls.last == .scan(refresh: true))
  #expect(flow.state == .editingNetwork(unwritten))
  #expect(await transport.closes == 0)
  await flow.writeNetwork(
    NetworkChange(ssid: "typed", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(1))
}

@Test @MainActor func aWriteWaitsForTheScanAndThenWatchesTheJoin() async throws {
  let client = WiFiClient(
    scans: [running, complete],
    statuses: [
      WiFiStatus(section: 8, radio: nil),
      WiFiStatus(section: 8, radio: (version: 7, state: .joined(address: "10.0.0.2"))),
      WiFiStatus(section: 8, radio: (version: 8, state: .joining)),
      WiFiStatus(section: 8, radio: (version: 8, state: .joined(address: "192.168.1.42"))),
    ])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  flow.scanNetworks()
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  #expect(!flow.isScanning)
  #expect(flow.join == .waiting)
  await settle { flow.join != .waiting }
  // The earlier version's success is not this write's verdict.
  #expect(flow.join == .joined(address: "192.168.1.42"))
  let calls = await client.calls
  let write = try #require(calls.firstIndex(of: .write))
  #expect(!calls[write...].contains { if case .scan = $0 { true } else { false } })
  #expect(calls.filter { $0 == .status }.count == 4)
}

@Test @MainActor func aWrongPasswordIsReportedAndTheNetworkCanBeChanged() async throws {
  let client = WiFiClient(statuses: [
    WiFiStatus(section: 8, radio: (version: 8, state: .failed(.authFailed)))
  ])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "wrong horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  #expect(flow.join == .failed(.authFailed))
  await flow.changeNetwork()
  #expect(flow.state == .editingNetwork(client.settings))
  #expect(flow.join == .idle)
  #expect(await client.calls.filter { $0 == .read }.count == 2)
}

@Test @MainActor func noVerdictInTimeIsReported() async throws {
  let client = WiFiClient(statuses: [
    WiFiStatus(section: 8, radio: (version: 8, state: .joining))
  ])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  #expect(flow.join == .noAnswer)
  #expect(clock.now == .seconds(60))
}

@Test @MainActor func forgettingTheNetworkWatchesNothing() async throws {
  let client = WiFiClient()
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: nil, passphrase: nil, country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  #expect(flow.join == .idle)
  #expect(await client.calls.last == .write)
}

@Test @MainActor func settingTheTimeStopsTheWatchFirst() async throws {
  let client = WiFiClient(statuses: [
    WiFiStatus(section: 8, radio: (version: 8, state: .joining))
  ])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.join == .waiting)
  await flow.setTime(Date(timeIntervalSince1970: 1_700_000_000))
  #expect(flow.state == .finished(version: 8, timeSet: true))
  #expect(await client.calls.last == .time)
  #expect(await transport.closes == 1)
  #expect(flow.join == .idle)
}

private let joining8 = WiFiStatus(section: 8, radio: (version: 8, state: .joining))
private let joined8 = WiFiStatus(
  section: 8, radio: (version: 8, state: .joined(address: "192.168.1.42")))

/// Board A, 2026-09-24: the write landed, then the link dropped during the
/// join watch and the app said setup stopped. The write stands instead.
@Test(arguments: [SetupFailure.connectionDropped, .timedOut, .protocolError])
@MainActor func aLinkLostDuringTheJoinWatchKeepsTheWrite(_ failure: SetupFailure) async throws {
  let client = WiFiClient(statuses: [joining8])
  await client.failStatuses(with: failure)
  let clock = PollClock()
  defer { clock.finish() }
  let lastController = MemoryLastController()
  let (flow, transport) = try await editing(client, clock, lastController: lastController)
  #expect(lastController.load() == "abcd")
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  #expect(flow.state == .written(8))
  #expect(flow.join == .connectionLost)
  #expect(flow.writtenVersion == 8)
  #expect(await transport.closes == 1)
  // A relaunch still reconnects to the controller.
  #expect(lastController.load() == "abcd")
}

@Test @MainActor func doneFinishesAfterTheLinkIsLost() async throws {
  let client = WiFiClient(statuses: [joining8])
  await client.failStatuses(with: .connectionDropped)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  await transport.failOpens(with: .unreachable)
  await flow.finish()
  #expect(flow.state == .finished(version: 8, timeSet: false))
  // No reconnect and no second close.
  #expect(await transport.opens == 1)
  #expect(await transport.closes == 1)
}

@Test @MainActor func checkAgainReconnectsAndReadsTheJoin() async throws {
  let client = WiFiClient(statuses: [joined8])
  await client.failStatuses(with: .connectionDropped)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  #expect(flow.join == .connectionLost)
  await client.failStatuses(with: nil)
  await flow.watchJoinAgain()
  #expect(flow.state == .written(8))
  await settle { flow.join != .waiting }
  #expect(flow.join == .joined(address: "192.168.1.42"))
  #expect(await transport.opens == 2)
  // A new session, then the status, with no second read or write.
  #expect(await client.calls.suffix(3) == [.discover, .hello, .status])
  #expect(await client.calls.filter { $0 == .write }.count == 1)
}

@Test(arguments: [TransportError.unreachable, .timedOut, .dropped])
@MainActor func aCheckAgainThatCannotReconnectStaysWritten(_ error: TransportError) async throws {
  let client = WiFiClient(statuses: [joining8])
  await client.failStatuses(with: .connectionDropped)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, transport) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  await transport.failOpens(with: error)
  await flow.watchJoinAgain()
  #expect(flow.state == .written(8))
  #expect(flow.join == .connectionLost)
  #expect(await transport.opens == 2)
  await flow.finish()
  #expect(flow.state == .finished(version: 8, timeSet: false))
}

/// A refused enrolment needs the pairing window, which the written screen
/// cannot offer: that failure still stops setup.
@Test @MainActor func aRefusedEnrolmentOnCheckAgainStillStops() async throws {
  let client = WiFiClient(statuses: [joining8])
  await client.failStatuses(with: .connectionDropped)
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  await settle { flow.join != .waiting }
  await client.failHello(with: .enrolmentRefused)
  await flow.watchJoinAgain()
  #expect(flow.state == .failed(.enrolmentRefused, .openWindow))
}

@Test func signalBars() {
  func bars(_ rssi: Int8) -> Int {
    HeardNetwork(ssid: "n", rssi: rssi, security: .wpa2Personal, band: .ghz24, channel: 1).bars
  }
  let rssi: [Int8] = [-40, -60, -61, -75, -76, -100]
  #expect(rssi.map(bars) == [3, 3, 2, 2, 1, 1])
}

@Test func statusIsReadOnlyForTheVersionAsked() {
  let status = WiFiStatus(section: 3, radio: (version: 2, state: .failed(.authFailed)))
  #expect(status.state(for: 2) == .failed(.authFailed))
  #expect(status.state(for: 3) == nil)
  #expect(WiFiStatus(section: 3, radio: nil).state(for: 3) == nil)
}

@Test func onlyWPAPersonalIsJoinable() {
  #expect(NetworkSecurity.wpa2Personal.isJoinable)
  #expect(NetworkSecurity.wpa3Personal.isJoinable)
  #expect(!NetworkSecurity.open.isJoinable)
  #expect(!NetworkSecurity.other.isJoinable)
}

// MARK: - A controller that holds a network when it pairs

private let home = NetworkSettings(
  version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")

/// Pair closes the window and the station joins the network the controller
/// holds: the flow watches that join and writes nothing.
@Test @MainActor func pairingAControllerThatHoldsANetworkWatchesItJoin() async throws {
  let joined7 = WiFiStatus(section: 7, radio: (version: 7, state: .joined(address: "10.0.0.9")))
  let client = WiFiClient(statuses: [joined7], settings: home)
  let clock = PollClock()
  defer { clock.finish() }
  let flow = SetupFlow(
    factory: Factory(client: client), store: NoEnrolmentStore(),
    transportFactory: { Transport() }, clock: clock)
  try flow.submitCode("valid")
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .written(7))
  #expect(flow.joinsHeldNetwork)
  await settle { flow.join != .waiting }
  #expect(flow.join == .joined(address: "10.0.0.9"))
  #expect(await client.calls == [.discover, .pair, .hello, .read, .status])
  // The person may still choose another network.
  await flow.changeNetwork()
  #expect(flow.state == .editingNetwork(home))
}

/// Without Wi-Fi status reads there is no join to watch, and a network held
/// without its passphrase cannot be joined: both go to the network form.
@Test(arguments: [
  (
    true,
    NetworkSettings(version: 7, ssid: "home", passphraseSet: false, country: "CA", hostname: "unit")
  ),
  (false, home),
])
@MainActor func aHeldNetworkThatCannotBeWatchedGoesToTheForm(
  reportsWiFi: Bool, settings: NetworkSettings
) async throws {
  let client = WiFiClient(reportsWiFi: reportsWiFi, settings: settings)
  let clock = PollClock()
  defer { clock.finish() }
  let flow = SetupFlow(
    factory: Factory(client: client), store: NoEnrolmentStore(),
    transportFactory: { Transport() }, clock: clock)
  try flow.submitCode("valid")
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .editingNetwork(settings))
  #expect(!flow.joinsHeldNetwork)
  #expect(flow.join == .idle)
}

/// Once the person writes a network, the written version is theirs.
@Test @MainActor func writingANetworkIsNotTheHeldOne() async throws {
  let client = WiFiClient(statuses: [joining8])
  let clock = PollClock()
  defer { clock.finish() }
  let (flow, _) = try await editing(client, clock)
  #expect(!flow.joinsHeldNetwork)
  await flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  #expect(!flow.joinsHeldNetwork)
}
