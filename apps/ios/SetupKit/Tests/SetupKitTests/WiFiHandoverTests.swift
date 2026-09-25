import Foundation
import Testing

@testable import SetupKit

private let deviceID = "0123456789abcdef0123456789abcdef"
private let address = "192.168.1.42"

private actor LinkTransport: FrameTransport {
  enum Kind: Sendable { case bluetooth, wifi }
  nonisolated let kind: Kind
  private(set) var opens = 0
  private(set) var closes = 0
  var openFailure: TransportError?
  init(_ kind: Kind) { self.kind = kind }
  func failOpens(with error: TransportError?) { openFailure = error }
  func open() async throws(TransportError) {
    opens += 1
    if let openFailure { throw openFailure }
  }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async { closes += 1 }
}

/// An enrolled controller; which link it answers on is the factory's choice.
private actor LinkClient: ControllerClient {
  enum Call: Sendable, Equatable { case discover, hello, read, write, status, time }
  private(set) var calls: [Call] = []
  var discovered: Result<ControllerSummary, SetupFailure> = .success(
    ControllerSummary(deviceID: deviceID))
  var helloFailure: SetupFailure?
  var timeFailure: SetupFailure?
  var statusFailure: SetupFailure?
  var writeFailure: SetupFailure?
  var joinedAt: String?
  /// The section `readNetwork` answers.
  var held = settings

  init(joinedAt: String? = nil) { self.joinedAt = joinedAt }
  func answerDiscover(_ result: Result<ControllerSummary, SetupFailure>) { discovered = result }
  func failHello(with failure: SetupFailure?) { helloFailure = failure }
  func failTime(with failure: SetupFailure?) { timeFailure = failure }
  func failStatus(with failure: SetupFailure?) { statusFailure = failure }
  func failWrite(with failure: SetupFailure?) { writeFailure = failure }
  func hold(_ settings: NetworkSettings) { held = settings }
  func restore(from store: any EnrolmentStore) async {}
  func isEnrolled() async -> Bool { true }
  func keep(in store: any EnrolmentStore) async throws {}
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append(.discover)
    return try discovered.get()
  }
  func pair() async throws(SetupFailure) {}
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append(.hello)
    if let helloFailure { throw helloFailure }
    return SessionReport(reportsWiFi: true)
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    calls.append(.read)
    return held
  }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan {
    NetworkScan(progress: .none, networks: nil)
  }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus {
    calls.append(.status)
    if let statusFailure { throw statusFailure }
    return WiFiStatus(
      section: 8, radio: (version: 8, state: joinedAt.map { .joined(address: $0) } ?? .joining))
  }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  {
    calls.append(.write)
    if let writeFailure { throw writeFailure }
    return expectedVersion + 1
  }
  func setTime(_ date: Date) async throws(SetupFailure) {
    calls.append(.time)
    if let timeFailure { throw timeFailure }
  }
  func close() async {}
}

private let settings = NetworkSettings(
  version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")
private let change = NetworkChange(
  ssid: "cabin", passphrase: "correct horse", country: "CA", hostname: "unit")

/// Bluetooth sessions go to `bluetooth`; WebSocket sessions to `wifi`, or to
/// nothing when no enrolment is kept for them.
private final class Factory: ControllerClientFactory, @unchecked Sendable {
  let bluetooth: LinkClient
  let wifi: LinkClient?
  private let lock = NSLock()
  private var wifiSessions = 0
  var wifiClients: Int { lock.withLock { wifiSessions } }
  init(bluetooth: LinkClient, wifi: LinkClient?) {
    self.bluetooth = bluetooth
    self.wifi = wifi
  }
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { bluetooth }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    guard let transport = transport as? LinkTransport else { return nil }
    switch transport.kind {
    case .bluetooth: return bluetooth
    case .wifi:
      lock.withLock { wifiSessions += 1 }
      return wifi
    }
  }
}

final class MemoryAddresses: ControllerAddressStore, @unchecked Sendable {
  private let lock = NSLock()
  private var addresses: [String: String]
  init(_ addresses: [String: String] = [:]) { self.addresses = addresses }
  func load(deviceID: String) -> String? { lock.withLock { addresses[deviceID] } }
  func save(_ address: String?, deviceID: String) {
    lock.withLock { addresses[deviceID] = address }
  }
  func removeAll() { lock.withLock { addresses.removeAll() } }
}

/// Poll sleeps pass at once.
@MainActor private final class ImmediateClock: SetupClock {
  var now: Duration = .zero
  func sleep(until deadline: Duration) async throws {
    now = deadline
    await Task.yield()
    try Task.checkCancellation()
  }
}

/// DNS-SD answers that a test changes as the controller comes and goes.
@MainActor private final class FakeBrowser: ControllerBrowser {
  var found: [String] = []
  private(set) var browses = 0
  func addresses(advertising deviceID: String) async -> [String] {
    browses += 1
    return found
  }
}

@MainActor private struct Bench {
  let flow: SetupFlow
  let bluetooth: LinkTransport
  let webSocket: LinkTransport
  let factory: Factory
  let addresses: MemoryAddresses
  /// The addresses WebSocket transports were made for.
  let dialled: Dialled
}
@MainActor private final class Dialled {
  var addresses: [String] = []
}

/// A launch that reconnects to the controller from its kept enrolment.
@MainActor private func launch(
  bluetooth: LinkClient = LinkClient(joinedAt: address), wifi: LinkClient? = LinkClient(),
  addresses: MemoryAddresses = MemoryAddresses(), browser: FakeBrowser? = nil
) -> Bench {
  let bluetoothTransport = LinkTransport(.bluetooth)
  let webSocket = LinkTransport(.wifi)
  let factory = Factory(bluetooth: bluetooth, wifi: wifi)
  let dialled = Dialled()
  let flow = SetupFlow(
    factory: factory, store: NoEnrolmentStore(), transportFactory: { bluetoothTransport },
    clock: ImmediateClock(), lastController: MemoryLastController(deviceID),
    webSocketFactory: { address in
      dialled.addresses.append(address)
      return webSocket
    },
    addresses: addresses, browser: browser)
  return Bench(
    flow: flow, bluetooth: bluetoothTransport, webSocket: webSocket, factory: factory,
    addresses: addresses, dialled: dialled)
}

@MainActor private func settle(_ done: () -> Bool) async {
  for _ in 0..<10_000 where !done() { await Task.yield() }
}

/// Connect over Bluetooth, write, and let the join watch and the switch run.
@MainActor private func writeAndJoin(_ bench: Bench) async {
  await bench.flow.connect()
  #expect(bench.flow.state == .editingNetwork(settings))
  #expect(bench.flow.link == .bluetooth)
  await bench.flow.writeNetwork(change)
  #expect(bench.flow.state == .written(8))
  await settle {
    bench.flow.join != .waiting && !bench.flow.isSwitchingToWiFi
      && bench.flow.link != .bluetooth || bench.flow.wifiUnavailable != nil
  }
}

@Test @MainActor func aJoinMovesTheSessionToWiFiAndClosesBluetooth() async throws {
  let wifi = LinkClient()
  let bench = launch(wifi: wifi)
  await writeAndJoin(bench)
  #expect(bench.flow.join == .joined(address: address))
  #expect(bench.flow.link == .wifi(address: address))
  #expect(bench.flow.wifiUnavailable == nil)
  #expect(bench.dialled.addresses == [address])
  #expect(await bench.webSocket.opens == 1)
  #expect(await wifi.calls == [.discover, .hello])
  #expect(await bench.bluetooth.closes == 1)
  #expect(bench.addresses.load(deviceID: deviceID) == address)

  // The clock and Done go over Wi-Fi.
  await bench.flow.setTime()
  #expect(bench.flow.state == .finished(version: 8, timeSet: true))
  #expect(await wifi.calls == [.discover, .hello, .time])
  #expect(await !bench.factory.bluetooth.calls.contains(.time))
  #expect(await bench.webSocket.closes == 1)
  #expect(bench.flow.link == nil)
}

@Test(arguments: [
  (TransportError.unreachable, SetupFlow.WiFiUnavailable.notReachable),
  (.timedOut, .notReachable),
  (.localNetworkDenied, .localNetworkDenied),
])
@MainActor func aWiFiThePhoneCannotReachStaysOnBluetooth(
  error: TransportError, reason: SetupFlow.WiFiUnavailable
) async throws {
  let bench = launch()
  await bench.webSocket.failOpens(with: error)
  await writeAndJoin(bench)
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == reason)
  #expect(bench.flow.state == .written(8))
  #expect(await bench.bluetooth.closes == 0)
  // The reported address stays a candidate for later.
  #expect(bench.addresses.load(deviceID: deviceID) == address)

  // The phone joins the network: the retry switches.
  await bench.webSocket.failOpens(with: nil)
  await bench.flow.retryWiFi()
  #expect(bench.flow.link == .wifi(address: address))
  #expect(bench.flow.wifiUnavailable == nil)
  #expect(await bench.bluetooth.closes == 1)
}

@Test @MainActor func anotherControllerAtTheAddressIsAMismatchAndTheAddressIsForgotten()
  async throws
{
  let wifi = LinkClient()
  await wifi.answerDiscover(.failure(.controllerMismatch))
  let bench = launch(wifi: wifi)
  await writeAndJoin(bench)
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == .otherController)
  #expect(await wifi.calls == [.discover])
  #expect(await bench.webSocket.closes == 1)
  #expect(bench.addresses.load(deviceID: deviceID) == nil)
  #expect(bench.flow.state == .written(8))
}

@Test @MainActor func aHelloRefusedOverWiFiStaysOnBluetooth() async throws {
  let wifi = LinkClient()
  await wifi.failHello(with: .enrolmentRefused)
  let bench = launch(wifi: wifi)
  await writeAndJoin(bench)
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == .refused)
  #expect(await bench.webSocket.closes == 1)
  #expect(bench.flow.state == .written(8))
}

/// Without a kept enrolment there is nothing to greet with over Wi-Fi.
@Test @MainActor func noKeptEnrolmentStaysOnBluetoothWithoutDialling() async throws {
  let bench = launch(wifi: nil)
  await writeAndJoin(bench)
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == nil)
  #expect(await bench.webSocket.opens == 0)
  #expect(bench.factory.wifiClients == 1)
}

@Test @MainActor func aLaterLaunchConnectsOverWiFiFirst() async throws {
  let bluetooth = LinkClient()
  let wifi = LinkClient()
  let bench = launch(
    bluetooth: bluetooth, wifi: wifi, addresses: MemoryAddresses([deviceID: address]))
  #expect(bench.flow.state == .connecting)
  await bench.flow.connect()
  #expect(bench.flow.state == .editingNetwork(settings))
  #expect(bench.flow.link == .wifi(address: address))
  #expect(await wifi.calls == [.discover, .hello, .read])
  #expect(await bench.bluetooth.opens == 0)
  #expect(await bluetooth.calls.isEmpty)
}

@Test @MainActor func aLaterLaunchOffTheNetworkFallsBackToBluetooth() async throws {
  let bluetooth = LinkClient()
  let bench = launch(bluetooth: bluetooth, addresses: MemoryAddresses([deviceID: address]))
  await bench.webSocket.failOpens(with: .unreachable)
  await bench.flow.connect()
  #expect(bench.flow.state == .editingNetwork(settings))
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == .notReachable)
  #expect(await bluetooth.calls == [.discover, .hello, .read])
}

/// Discover stays the identity check at a kept address (P-225): a mismatch
/// there is not this controller, and Bluetooth finds it.
@Test @MainActor func aLaterLaunchFindingAnotherControllerFallsBackAndForgets() async throws {
  let wifi = LinkClient()
  await wifi.answerDiscover(.failure(.controllerMismatch))
  let bench = launch(wifi: wifi, addresses: MemoryAddresses([deviceID: address]))
  await bench.flow.connect()
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == .otherController)
  #expect(bench.addresses.load(deviceID: deviceID) == nil)
  #expect(bench.flow.state == .editingNetwork(settings))
}

/// Both links gone: the failure is Bluetooth's, and it says Wi-Fi was tried.
@Test @MainActor func aLaterLaunchReachingNeitherLinkFails() async throws {
  let bench = launch(addresses: MemoryAddresses([deviceID: address]))
  await bench.webSocket.failOpens(with: .unreachable)
  await bench.bluetooth.failOpens(with: .unreachable)
  await bench.flow.connect()
  #expect(bench.flow.state == .failed(.bluetoothUnavailable, .connecting))
  #expect(bench.flow.wifiUnavailable == .notReachable)
  #expect(bench.flow.link == nil)
}

/// The Wi-Fi session drops mid-step: the retry tries Wi-Fi again first, and
/// reaches the controller over Bluetooth when Wi-Fi stays away.
@Test @MainActor func aDropOverWiFiReconnectsWiFiFirstThenBluetooth() async throws {
  let wifi = LinkClient()
  let bench = launch(wifi: wifi)
  await writeAndJoin(bench)
  #expect(bench.flow.link == .wifi(address: address))
  await wifi.failTime(with: .connectionDropped)
  await bench.flow.setTime()
  #expect(bench.flow.state == .failed(.connectionDropped, .connecting))
  #expect(await bench.webSocket.closes == 1)
  #expect(bench.flow.link == nil)

  await bench.webSocket.failOpens(with: .unreachable)
  await bench.flow.retry()
  #expect(await bench.webSocket.opens == 2)
  #expect(bench.flow.link == .bluetooth)
  #expect(bench.flow.wifiUnavailable == .notReachable)
  #expect(bench.flow.state == .written(8))
}

/// Leaving the foreground during the switch closes both links.
@Test @MainActor func suspendingDuringTheSwitchClosesBothLinks() async throws {
  let bench = launch()
  await bench.flow.connect()
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.isSwitchingToWiFi }
  await bench.flow.suspend()
  await settle { !bench.flow.isSwitchingToWiFi }
  #expect(bench.flow.link == nil)
  #expect(await bench.bluetooth.closes == 1)
  let opens = await bench.webSocket.opens
  #expect(await bench.webSocket.closes == opens)
  #expect(bench.flow.state == .written(8))
}

// MARK: - Bluetooth dropping while the station starts

/// Connect over Bluetooth with the controller not yet on the network.
@MainActor private func editingOverBluetooth(_ bench: Bench) async {
  await bench.flow.connect()
  #expect(bench.flow.state == .editingNetwork(settings))
  #expect(bench.flow.link == .bluetooth)
}

/// The station starting drops Bluetooth before the join is reported: the
/// flow finds the controller over DNS-SD and reads the join over Wi-Fi.
@Test @MainActor func aBluetoothDropDuringTheJoinContinuesOverWiFi() async throws {
  let bluetooth = LinkClient()
  let wifi = LinkClient(joinedAt: address)
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, wifi: wifi, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failStatus(with: .connectionDropped)
  browser.found = [address]
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.join == .joined(address: address) }
  #expect(bench.flow.state == .written(8))
  #expect(bench.flow.link == .wifi(address: address))
  #expect(!bench.flow.isSwitchingToWiFi)
  #expect(await bench.bluetooth.closes == 1)
  #expect(await wifi.calls == [.discover, .hello, .status])
  #expect(bench.addresses.load(deviceID: deviceID) == address)
}

/// With no candidate at all, the search still ends with a reason.
@Test @MainActor func aSearchWithNoCandidateReportsTheControllerUnreachable() async throws {
  let bluetooth = LinkClient()
  let bench = launch(bluetooth: bluetooth, browser: FakeBrowser())
  await editingOverBluetooth(bench)
  await bluetooth.failStatus(with: .connectionDropped)
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.join == .connectionLost && !bench.flow.isSwitchingToWiFi }
  #expect(bench.flow.wifiUnavailable == .notReachable)
  #expect(bench.flow.link == nil)
  #expect(await bench.webSocket.opens == 0)
}

/// Starting over as the search is scheduled leaves nothing open.
@Test @MainActor func resettingBeforeTheSearchStartsLeavesNothingOpen() async throws {
  let bluetooth = LinkClient()
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failStatus(with: .connectionDropped)
  browser.found = [address]
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.join == .waiting && bench.flow.isSwitchingToWiFi }
  await bench.flow.reset()
  for _ in 0..<100 { await Task.yield() }
  #expect(bench.flow.state == .enterCode)
  #expect(bench.flow.link == nil)
  #expect(!bench.flow.isSwitchingToWiFi)
  let opens = await bench.webSocket.opens
  #expect(await bench.webSocket.closes == opens)
}

/// The controller is looked for again until `wifiLimit`, then the join is
/// reported lost with the reason, and a check tries again.
@Test @MainActor func aControllerNotFoundOnWiFiIsReportedAfterTheLimit() async throws {
  let bluetooth = LinkClient()
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failStatus(with: .connectionDropped)
  browser.found = [address]
  await bench.webSocket.failOpens(with: .unreachable)
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.join == .connectionLost && !bench.flow.isSwitchingToWiFi }
  #expect(bench.flow.state == .written(8))
  #expect(bench.flow.link == nil)
  #expect(bench.flow.wifiUnavailable == .notReachable)
  // After the connect's browse, one at 0 s and one every 2 s up to the 30 s limit.
  #expect(browser.browses == 1 + 16)
  #expect(await bench.webSocket.opens == 16)
  #expect(await bench.webSocket.closes == 0)
}

/// Leaving the app during the search ends it with nothing open.
@Test @MainActor func suspendingDuringTheSearchEndsIt() async throws {
  let bluetooth = LinkClient()
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failStatus(with: .connectionDropped)
  await bench.webSocket.failOpens(with: .unreachable)
  await bench.flow.writeNetwork(change)
  await settle { bench.flow.isSwitchingToWiFi }
  await bench.flow.suspend()
  await settle { !bench.flow.isSwitchingToWiFi }
  #expect(bench.flow.link == nil)
  #expect(bench.flow.state == .written(8))
  let browses = browser.browses
  for _ in 0..<100 { await Task.yield() }
  #expect(browser.browses == browses)
}

/// A write whose answer was lost with Bluetooth landed when the section read
/// over Wi-Fi holds it: setup continues from it there.
@Test @MainActor func aLostWriteAnswerIsConfirmedOverWiFi() async throws {
  let bluetooth = LinkClient()
  let wifi = LinkClient(joinedAt: address)
  await wifi.hold(
    NetworkSettings(version: 8, ssid: "cabin", passphraseSet: true, country: "CA", hostname: "unit")
  )
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, wifi: wifi, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failWrite(with: .connectionDropped)
  browser.found = [address]
  await bench.flow.writeNetwork(change)
  #expect(bench.flow.state == .written(8))
  #expect(bench.flow.writtenVersion == 8)
  #expect(bench.flow.link == .wifi(address: address))
  await settle { bench.flow.join == .joined(address: address) }
  #expect(await wifi.calls == [.discover, .hello, .read, .status])
}

/// Over Wi-Fi the section still holds the old network, or the controller is
/// not found: the write did not land as far as this phone knows.
@Test(arguments: [true, false])
@MainActor func anUnconfirmedLostWriteFails(found: Bool) async throws {
  let bluetooth = LinkClient()
  let wifi = LinkClient()
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, wifi: wifi, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failWrite(with: .connectionDropped)
  if found { browser.found = [address] }
  await bench.flow.writeNetwork(change)
  #expect(bench.flow.state == .failed(.connectionDropped, .connecting))
  #expect(bench.flow.writtenVersion == nil)
  #expect(bench.flow.link == nil)
  #expect(await bench.webSocket.closes == (found ? 1 : 0))
  #expect(await wifi.calls == (found ? [.discover, .hello, .read] : []))
}

/// A refusal is the controller's answer, not a lost one: nothing to confirm.
@Test @MainActor func aRefusedWriteIsNotLookedForOverWiFi() async throws {
  let bluetooth = LinkClient()
  let browser = FakeBrowser()
  let bench = launch(bluetooth: bluetooth, browser: browser)
  await editingOverBluetooth(bench)
  await bluetooth.failWrite(with: .staleVersion)
  browser.found = [address]
  await bench.flow.writeNetwork(change)
  #expect(bench.flow.state == .failed(.staleVersion, .readingNetwork))
  #expect(browser.browses == 1)
}
