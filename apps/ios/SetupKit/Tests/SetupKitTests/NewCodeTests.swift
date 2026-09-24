import Foundation
import Testing

@testable import SetupKit

/// The controller an earlier launch enrolled with, and the one a new code names.
private let earlier = "11111111111111111111111111111111"
private let scanned = "22222222222222222222222222222222"
private let earlierAddress = "192.168.1.40"
private let earlierKept = Data([0x01, 0x11])

private actor Transport: FrameTransport {
  let openFailure: TransportError?
  init(openFailure: TransportError? = nil) { self.openFailure = openFailure }
  func open() async throws(TransportError) {
    if let openFailure { throw openFailure }
  }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async {}
}

/// One controller, reached with the enrolment the store keeps for it or with
/// its setup code.
private actor Controller: ControllerClient {
  enum Call: Sendable, Equatable { case discover, pair, hello, read }
  let deviceID: String
  let refusesHello: Bool
  let pairFailure: SetupFailure?
  private(set) var enrolled: Bool
  private(set) var calls: [Call] = []
  /// `enrolled` for a client resumed from a kept enrolment.
  init(
    _ deviceID: String, enrolled: Bool = false, refusesHello: Bool = false,
    pairFailure: SetupFailure? = nil
  ) {
    self.deviceID = deviceID
    self.enrolled = enrolled
    self.refusesHello = refusesHello
    self.pairFailure = pairFailure
  }
  func restore(from store: any EnrolmentStore) async {
    if store.load(deviceID: deviceID) != nil { enrolled = true }
  }
  func isEnrolled() async -> Bool { enrolled }
  func keep(in store: any EnrolmentStore) async throws {
    try store.save(Data([0x01, 0x22]), deviceID: deviceID)
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    calls.append(.discover)
    return ControllerSummary(deviceID: deviceID)
  }
  func pair() async throws(SetupFailure) {
    calls.append(.pair)
    if let pairFailure { throw pairFailure }
    enrolled = true
  }
  func hello() async throws(SetupFailure) -> SessionReport {
    calls.append(.hello)
    if refusesHello {
      enrolled = false
      throw .enrolmentRefused
    }
    return SessionReport(reportsWiFi: false)
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    calls.append(.read)
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

/// The code names `scanned`; a kept enrolment resumes `earlier`.
private final class Factory: ControllerClientFactory, @unchecked Sendable {
  let earlier: Controller
  let scanned: Controller
  private let lock = NSLock()
  private var resumes: [String] = []
  /// Every `device_id` a client was resumed for, in order.
  var resumed: [String] { lock.withLock { resumes } }
  init(earlier: Controller, scanned: Controller) {
    self.earlier = earlier
    self.scanned = scanned
  }
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { scanned }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    lock.withLock { resumes.append(deviceID) }
    return store.load(deviceID: deviceID) == nil ? nil : earlier
  }
}

@MainActor private final class Dialled {
  var addresses: [String] = []
}

/// The pairing window never closes in these tests.
@MainActor private struct OpenWindowClock: SetupClock {
  var now: Duration { .zero }
  func sleep(until deadline: Duration) async throws { throw CancellationError() }
}

private struct Bench {
  let flow: SetupFlow
  let factory: Factory
  let store: MemoryEnrolmentStore
  let lastController: MemoryLastController
  let dialled: Dialled
}

/// A launch that resumes `earlier`, whose kept enrolment it refuses, so the
/// person is sent to scan a code. Wi-Fi to `earlier` is tried and unreachable.
@MainActor private func refusedResume(scanned: Controller, keptForScanned: Data? = nil) async
  -> Bench
{
  let factory = Factory(
    earlier: Controller(earlier, enrolled: true, refusesHello: true), scanned: scanned)
  var kept = [earlier: earlierKept]
  kept[scanned.deviceID] = keptForScanned
  let store = MemoryEnrolmentStore(kept)
  let lastController = MemoryLastController(earlier)
  let dialled = Dialled()
  let flow = SetupFlow(
    factory: factory, store: store, transportFactory: { Transport() }, clock: OpenWindowClock(),
    lastController: lastController,
    webSocketFactory: { address in
      dialled.addresses.append(address)
      return Transport(openFailure: .unreachable)
    },
    addresses: MemoryAddresses([earlier: earlierAddress]))
  #expect(flow.state == .connecting)
  await flow.connect()
  #expect(flow.state == .failed(.enrolmentRefused, .enterCode))
  #expect(flow.controller == ControllerSummary(deviceID: earlier))
  await flow.retry()
  #expect(flow.state == .enterCode)
  return Bench(
    flow: flow, factory: factory, store: store, lastController: lastController, dialled: dialled)
}

/// Issue #23: a code scanned after the earlier controller was left behind
/// reached for that controller's enrolment and address. The code's own
/// kept enrolment greets its controller, and nothing of the earlier one is used.
@Test @MainActor func aNewCodeUsesNothingFromTheEarlierController() async throws {
  let scanned = Controller(scanned)
  let bench = await refusedResume(scanned: scanned, keptForScanned: Data([0x01, 0x22]))
  #expect(bench.dialled.addresses == [earlierAddress])
  #expect(bench.factory.resumed == [earlier, earlier])

  try bench.flow.submitCode("code")
  #expect(bench.flow.controller == nil)
  #expect(!bench.flow.keptEnrolmentLost)
  await bench.flow.connect()
  #expect(bench.flow.state == .editingNetwork(scannedSettings))
  #expect(bench.flow.controller == ControllerSummary(deviceID: scanned.deviceID))
  #expect(bench.dialled.addresses == [earlierAddress], "no Wi-Fi to the earlier controller")
  #expect(bench.factory.resumed == [earlier, earlier])
  #expect(await scanned.calls == [.discover, .hello, .read])
  #expect(bench.lastController.load() == scanned.deviceID)
}

/// A code for a controller with nothing kept pairs, and its enrolment is
/// added only once Pair succeeds; the earlier controller's stays.
@Test @MainActor func aNewCodeWithNothingKeptPairsBeforeKeepingAnything() async throws {
  let scanned = Controller(scanned)
  let bench = await refusedResume(scanned: scanned)
  try bench.flow.submitCode("code")
  await bench.flow.connect()
  #expect(bench.flow.state == .openWindow)
  #expect(bench.store[scanned.deviceID] == nil)
  await bench.flow.confirmWindowOpened()
  #expect(bench.flow.state == .editingNetwork(scannedSettings))
  #expect(await scanned.calls == [.discover, .pair, .hello, .read])
  #expect(bench.store[scanned.deviceID] == Data([0x01, 0x22]))
  #expect(bench.store[earlier] == earlierKept)
  #expect(bench.lastController.load() == scanned.deviceID)
}

/// A refused Pair keeps nothing for the new controller and leaves the
/// earlier controller's enrolment where it was.
@Test @MainActor func aRefusedPairWithANewCodeKeepsNothing() async throws {
  let scanned = Controller(scanned, pairFailure: .tableFull)
  let bench = await refusedResume(scanned: scanned)
  try bench.flow.submitCode("code")
  await bench.flow.connect()
  await bench.flow.confirmWindowOpened()
  #expect(bench.flow.state == .failed(.tableFull, .openWindow))
  #expect(bench.store[scanned.deviceID] == nil)
  #expect(bench.store[earlier] == earlierKept)
}

private let scannedSettings = NetworkSettings(
  version: 1, ssid: nil, passphraseSet: false, country: nil, hostname: nil)
