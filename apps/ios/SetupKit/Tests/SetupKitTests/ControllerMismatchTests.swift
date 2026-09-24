import Foundation
import Testing

@testable import SetupKit

/// Answers Discover as the controller the setup code names only when the
/// driver is connected to `right`.
@MainActor private final class PeerClient: ControllerClient {
  let driver: FakeDriver
  let right: UUID?
  private(set) var discovers = 0
  init(driver: FakeDriver, right: UUID?) {
    self.driver = driver
    self.right = right
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    discovers += 1
    guard let peer = driver.peer, peer == right else { throw .controllerMismatch }
    return ControllerSummary(deviceID: "abcd")
  }
  func pair() async throws(SetupFailure) {}
  func hello() async throws(SetupFailure) -> SessionReport { SessionReport(reportsWiFi: false) }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan { throw .protocolError }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus { throw .protocolError }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    NetworkSettings(version: 1, ssid: nil, passphraseSet: false, country: nil, hostname: nil)
  }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  { expectedVersion + 1 }
  func setTime(_ date: Date) async throws(SetupFailure) {}
  func close() async {}
}
private struct PeerFactory: ControllerClientFactory {
  let client: PeerClient
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { client }
}
/// The pairing window never closes in these tests.
@MainActor private struct OpenWindowClock: SetupClock {
  var now: Duration { .zero }
  func sleep(until deadline: Duration) async throws { throw CancellationError() }
}

@MainActor private func mismatchFlow(peripherals: [UUID], right: UUID?) throws -> (
  SetupFlow, FakeDriver, PeerClient
) {
  let driver = FakeDriver()
  driver.peripherals = peripherals
  let transport = BluetoothTransport(
    identifiers: BluetoothIdentifiers(service: "1234", rx: "1235", tx: "1236"),
    codec: FakeCodec(), driver: driver, timeout: .milliseconds(20))
  let client = PeerClient(driver: driver, right: right)
  let flow = SetupFlow(
    factory: PeerFactory(client: client), transportFactory: { transport },
    clock: OpenWindowClock())
  try flow.submitCode("km43:1:code")
  return (flow, driver, client)
}

@Test @MainActor func wrongControllerIsSkippedForTheRightOne() async throws {
  let (wrong, right) = (UUID(), UUID())
  let (flow, driver, client) = try mismatchFlow(peripherals: [wrong, right], right: right)
  await flow.connect()
  #expect(flow.state == .openWindow)
  await flow.confirmWindowOpened()
  #expect(
    flow.state
      == .editingNetwork(
        NetworkSettings(version: 1, ssid: nil, passphraseSet: false, country: nil, hostname: nil)))
  #expect(driver.peer == right)
  #expect(driver.scans == [[], [wrong]])
  #expect(driver.mostConnections == 1)
  #expect(client.discovers == 2)
}

@Test @MainActor func onlyWrongControllersFailAsMismatchAfterTheOpenTimeout() async throws {
  let (first, second) = (UUID(), UUID())
  let (flow, driver, client) = try mismatchFlow(peripherals: [first, second], right: nil)
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .failed(.controllerMismatch, .connecting))
  #expect(driver.scans == [[], [first], [first, second]])
  #expect(driver.connections == 0)
  #expect(driver.mostConnections == 1)
  #expect(client.discovers == 2)
}

@Test @MainActor func retryAfterMismatchClearsExclusions() async throws {
  let wrong = UUID()
  let (flow, driver, _) = try mismatchFlow(peripherals: [wrong], right: nil)
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .failed(.controllerMismatch, .connecting))
  await flow.retry()
  #expect(flow.state == .openWindow)
  #expect(driver.scans == [[], [wrong], []])
  #expect(driver.peer == wrong)
  #expect(driver.mostConnections == 1)
}

/// The pairing window closes a few milliseconds in, while the flow is
/// reconnecting past a wrong controller (the reopen waits for the 20 ms open
/// timeout).
@MainActor private struct ShortWindowClock: SetupClock {
  var now: Duration { .zero }
  func sleep(until deadline: Duration) async throws { try await Task.sleep(for: .milliseconds(5)) }
}

@Test @MainActor func windowClosingDuringMismatchReconnectLetsRetryConnect() async throws {
  let wrong = UUID()
  let driver = FakeDriver()
  driver.peripherals = [wrong]
  let transport = BluetoothTransport(
    identifiers: BluetoothIdentifiers(service: "1234", rx: "1235", tx: "1236"),
    codec: FakeCodec(), driver: driver, timeout: .milliseconds(20))
  let client = PeerClient(driver: driver, right: nil)
  let flow = SetupFlow(
    factory: PeerFactory(client: client), transportFactory: { transport },
    clock: ShortWindowClock())
  try flow.submitCode("km43:1:code")
  await flow.connect()
  await flow.confirmWindowOpened()
  #expect(flow.state == .failed(.windowClosed, .openWindow))
  #expect(driver.connections == 0)
  await flow.retry()
  #expect(flow.state == .openWindow)
  #expect(driver.connections == 1)
  #expect(driver.mostConnections == 1)
}
