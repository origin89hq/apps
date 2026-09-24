import Foundation
import Testing

@testable import SetupKit

private actor Transport: FrameTransport {
  private(set) var closes = 0
  func open() async throws(TransportError) {}
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
  private(set) var calls: [Call] = []
  let settings = NetworkSettings(
    version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")

  init(reportsWiFi: Bool = true, scans: [NetworkScan] = [], statuses: [WiFiStatus] = []) {
    self.reportsWiFi = reportsWiFi
    self.scans = scans
    self.statuses = statuses
  }
  func failScans(with failure: SetupFailure) { scanFailure = failure }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append(.discover)
    return ControllerSummary(deviceID: "abcd")
  }
  func pair() async throws(SetupFailure) { calls.append(.pair) }
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append(.hello)
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
    return expectedVersion + 1
  }
  func setTime(_ date: Date) async throws(SetupFailure) { calls.append(.time) }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan {
    calls.append(.scan(refresh: refresh))
    if let scanFailure { throw scanFailure }
    return scans.count > 1 ? scans.removeFirst() : scans[0]
  }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus {
    calls.append(.status)
    return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
  }
  func close() async {}
}

private struct Factory: ControllerClientFactory {
  let client: WiFiClient
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { client }
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

@MainActor private func editing(_ client: WiFiClient, _ clock: PollClock) async throws
  -> (SetupFlow, Transport)
{
  let transport = Transport()
  let flow = SetupFlow(
    factory: Factory(client: client), transportFactory: { transport }, clock: clock)
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
