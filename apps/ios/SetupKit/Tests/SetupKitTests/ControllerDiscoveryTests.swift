import Foundation
import Testing

@testable import SetupKit

private let deviceID = "0123456789abcdef0123456789abcdef"
private let otherID = "fedcba9876543210fedcba9876543210"
private let kept = "192.168.1.42"
private let leased = "192.168.1.77"
private let impostor = "192.168.1.90"

@Test(arguments: [
  (["id": deviceID], true),
  (["id": deviceID, "vers": "2", "note": ""], true),
  (["id": otherID], false),
  (["id": deviceID.uppercased()], false),
  (["vers": "2"], false),
  ([:], false),
])
func aTXTRecordNamesTheControllerOnlyUnderItsKey(txt: [String: String], names: Bool) {
  #expect(NetworkControllerBrowser.advertises(txt, deviceID: deviceID, key: "id") == names)
}

private actor AddressTransport: FrameTransport {
  /// Nil for Bluetooth.
  nonisolated let address: String?
  private(set) var opens = 0
  var openFailure: TransportError?
  init(_ address: String?, failure: TransportError? = nil) {
    self.address = address
    openFailure = failure
  }
  func failOpens(with error: TransportError?) { openFailure = error }
  func open() async throws(TransportError) {
    opens += 1
    if let openFailure { throw openFailure }
  }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async {}
}

/// The controller as one link sees it: `answering` is the `device_id` that
/// answers Discover there.
private actor AddressClient: ControllerClient {
  enum Call: Sendable, Equatable { case discover, hello, read, write, status }
  private(set) var calls: [Call] = []
  let answering: String
  let joinedAt: String?
  init(answering: String = deviceID, joinedAt: String? = nil) {
    self.answering = answering
    self.joinedAt = joinedAt
  }
  func restore(from store: any EnrolmentStore) async {}
  func isEnrolled() async -> Bool { true }
  func keep(in store: any EnrolmentStore) async throws {}
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append(.discover)
    guard answering == deviceID else { throw .controllerMismatch }
    return ControllerSummary(deviceID: answering)
  }
  func pair() async throws(SetupFailure) {}
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append(.hello)
    return SessionReport(reportsWiFi: true)
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    calls.append(.read)
    return settings
  }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan {
    NetworkScan(progress: .none, networks: nil)
  }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus {
    calls.append(.status)
    return WiFiStatus(
      section: 8, radio: (version: 8, state: joinedAt.map { .joined(address: $0) } ?? .joining))
  }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  {
    calls.append(.write)
    return expectedVersion + 1
  }
  func setTime(_ date: Date) async throws(SetupFailure) {}
  func close() async {}
}

private let settings = NetworkSettings(
  version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")

/// Bluetooth reaches `bluetooth`; a WebSocket reaches the client at its address.
private final class Factory: ControllerClientFactory, @unchecked Sendable {
  let bluetooth: AddressClient
  let byAddress: [String: AddressClient]
  init(bluetooth: AddressClient, byAddress: [String: AddressClient]) {
    self.bluetooth = bluetooth
    self.byAddress = byAddress
  }
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { bluetooth }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    guard let transport = transport as? AddressTransport else { return nil }
    guard let address = transport.address else { return bluetooth }
    return byAddress[address]
  }
}

@MainActor private final class FakeBrowser: ControllerBrowser {
  var found: [String]
  private(set) var asked: [String] = []
  init(_ found: [String]) { self.found = found }
  func addresses(advertising deviceID: String) async -> [String] {
    asked.append(deviceID)
    return found
  }
}

@MainActor private final class ImmediateClock: SetupClock {
  var now: Duration = .zero
  func sleep(until deadline: Duration) async throws {
    now = deadline
    await Task.yield()
    try Task.checkCancellation()
  }
}

@MainActor private struct Site {
  let flow: SetupFlow
  let browser: FakeBrowser
  let addresses: MemoryAddresses
  let bluetooth: AddressTransport
  /// The addresses WebSocket transports were made for, in order.
  let dialled: Dialled
}
@MainActor private final class Dialled {
  var addresses: [String] = []
}

/// A launch that reconnects from the kept enrolment. `unreachable` addresses
/// fail to open; every other one reaches the client `controllers` names.
@MainActor private func launch(
  controllers: [String: AddressClient], browsed: [String], kept keptAddress: String?,
  unreachable: Set<String> = [], bluetooth: AddressClient = AddressClient()
) -> Site {
  let bluetoothTransport = AddressTransport(nil)
  let browser = FakeBrowser(browsed)
  let addresses = MemoryAddresses(keptAddress.map { [deviceID: $0] } ?? [:])
  let dialled = Dialled()
  let flow = SetupFlow(
    factory: Factory(bluetooth: bluetooth, byAddress: controllers), store: NoEnrolmentStore(),
    transportFactory: { bluetoothTransport }, clock: ImmediateClock(),
    lastController: MemoryLastController(deviceID),
    webSocketFactory: { address in
      dialled.addresses.append(address)
      return AddressTransport(address, failure: unreachable.contains(address) ? .unreachable : nil)
    },
    addresses: addresses, browser: browser)
  return Site(
    flow: flow, browser: browser, addresses: addresses, bluetooth: bluetoothTransport,
    dialled: dialled)
}

/// The lease changed: DNS-SD finds the controller at its new address, which
/// is tried first and kept once Hello succeeds there.
@Test @MainActor func anInstanceNamingTheControllerIsTriedBeforeTheKeptAddress() async throws {
  let controller = AddressClient()
  let site = launch(controllers: [leased: controller], browsed: [leased], kept: kept)
  await site.flow.connect()
  #expect(site.browser.asked == [deviceID])
  #expect(site.dialled.addresses == [leased])
  #expect(site.flow.link == .wifi(address: leased))
  #expect(await controller.calls == [.discover, .hello, .read])
  #expect(site.addresses.load(deviceID: deviceID) == leased)
  #expect(site.flow.wifiUnavailable == nil)
  #expect(await site.bluetooth.opens == 0)
}

/// TXT is unauthenticated: an instance another controller answers at fails
/// Discover, is skipped, and does not cost the kept address.
@Test @MainActor func aBrowsedAddressAnotherControllerAnswersIsSkipped() async throws {
  let other = AddressClient(answering: otherID)
  let controller = AddressClient()
  let site = launch(
    controllers: [impostor: other, kept: controller], browsed: [impostor], kept: kept)
  await site.flow.connect()
  #expect(site.dialled.addresses == [impostor, kept])
  #expect(await other.calls == [.discover])
  #expect(site.flow.link == .wifi(address: kept))
  #expect(site.addresses.load(deviceID: deviceID) == kept)
  #expect(site.flow.wifiUnavailable == nil)
}

@Test @MainActor func nothingBrowsedFallsBackToTheKeptAddress() async throws {
  let controller = AddressClient()
  let site = launch(controllers: [kept: controller], browsed: [], kept: kept)
  await site.flow.connect()
  #expect(site.browser.asked == [deviceID])
  #expect(site.dialled.addresses == [kept])
  #expect(site.flow.link == .wifi(address: kept))
}

/// An address found both ways is dialled once, then Bluetooth takes over.
@Test @MainActor func anAddressIsTriedOnceThenBluetooth() async throws {
  let bluetooth = AddressClient()
  let site = launch(
    controllers: [kept: AddressClient()], browsed: [kept], kept: kept, unreachable: [kept],
    bluetooth: bluetooth)
  await site.flow.connect()
  #expect(site.dialled.addresses == [kept])
  #expect(site.flow.link == .bluetooth)
  #expect(site.flow.wifiUnavailable == .notReachable)
  // Unreachable is not a mismatch: the address stays a candidate.
  #expect(site.addresses.load(deviceID: deviceID) == kept)
  #expect(await bluetooth.calls == [.discover, .hello, .read])
}

/// No instance and no kept address: straight to Bluetooth, with no reason to
/// report since nothing was dialled.
@Test @MainActor func noCandidateGoesToBluetoothWithoutDialling() async throws {
  let site = launch(controllers: [:], browsed: [], kept: nil)
  await site.flow.connect()
  #expect(site.browser.asked == [deviceID])
  #expect(site.dialled.addresses.isEmpty)
  #expect(site.flow.link == .bluetooth)
  #expect(site.flow.wifiUnavailable == nil)
  #expect(site.flow.state == .editingNetwork(settings))
}

/// The address the join reported does not answer; retrying Wi-Fi finds the
/// controller over DNS-SD.
@Test @MainActor func retryingWiFiLooksForTheControllerOverDNSSD() async throws {
  let controller = AddressClient()
  let site = launch(
    controllers: [kept: AddressClient(), leased: controller], browsed: [], kept: nil,
    unreachable: [kept], bluetooth: AddressClient(joinedAt: kept))
  await site.flow.connect()
  await site.flow.writeNetwork(
    NetworkChange(ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit"))
  for _ in 0..<10_000 where site.flow.wifiUnavailable == nil || site.flow.isSwitchingToWiFi {
    await Task.yield()
  }
  #expect(site.flow.wifiUnavailable == .notReachable)
  #expect(site.flow.join == .joined(address: kept))
  #expect(site.flow.link == .bluetooth)
  #expect(site.dialled.addresses == [kept])

  site.browser.found = [leased]
  await site.flow.retryWiFi()
  // The reported address first again, then the instance DNS-SD found.
  #expect(site.dialled.addresses == [kept, kept, leased])
  #expect(site.flow.link == .wifi(address: leased))
  #expect(site.addresses.load(deviceID: deviceID) == leased)
  #expect(site.flow.state == .written(8))
}
