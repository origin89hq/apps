import Foundation
import Testing

@testable import SetupKit

/// Counts connections so tests can hold the flow to one at a time.
private actor FakeTransport: FrameTransport {
  let failure: TransportError?
  private(set) var opens = 0
  private(set) var closes = 0
  private(set) var mostOpen = 0
  init(failure: TransportError? = nil) { self.failure = failure }
  func open() async throws(TransportError) {
    #expect(opens == closes, "opened while a connection was still open")
    if let failure { throw failure }
    opens += 1
    mostOpen = max(mostOpen, opens - closes)
  }
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async { closes += 1 }
}
private actor FakeClient: ControllerClient {
  enum Step: Sendable { case discover, pair, hello, read, write, time }
  let refusal: SetupFailure?
  let step: Step
  var failuresLeft: Int
  var calls: [Step] = []
  var lastChange: NetworkChange?
  var closed = false
  var holdPair = false
  var pairContinuation: CheckedContinuation<Void, Never>?
  var holdHello = false
  var holdEnrolled = false
  var enrolledContinuation: CheckedContinuation<Void, Never>?
  /// Waiting for a held `isEnrolled` or `hello` to start.
  private var holdWaiters: [CheckedContinuation<Void, Never>] = []
  var helloContinuation: CheckedContinuation<Void, Never>?
  var writtenVersion: UInt32?
  var enrolled = false
  let settings = NetworkSettings(
    version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")
  init(
    _ refusal: SetupFailure? = nil, at step: Step = .pair, holdPair: Bool = false,
    times: Int = .max
  ) {
    self.refusal = refusal
    self.step = step
    self.holdPair = holdPair
    self.failuresLeft = times
  }
  private func record(_ step: Step) throws(SetupFailure) {
    calls.append(step)
    if self.step == step, let refusal, failuresLeft > 0 {
      failuresLeft -= 1
      throw refusal
    }
  }
  func discover() async throws(SetupFailure) -> ControllerSummary {
    try record(.discover)
    return ControllerSummary(deviceID: "abcd")
  }
  func restore(from store: any EnrolmentStore) async {}
  func holdEnrolledCheck() { holdEnrolled = true }
  /// Returns once a held `isEnrolled` or `hello` is waiting.
  func held() async {
    if enrolledContinuation != nil || helloContinuation != nil { return }
    await withCheckedContinuation { holdWaiters.append($0) }
  }
  private func wakeHoldWaiters() {
    for waiter in holdWaiters { waiter.resume() }
    holdWaiters = []
  }
  func releaseEnrolledCheck() {
    enrolledContinuation?.resume()
    enrolledContinuation = nil
  }
  func isEnrolled() async -> Bool {
    if holdEnrolled {
      holdEnrolled = false
      await withCheckedContinuation {
        enrolledContinuation = $0
        wakeHoldWaiters()
      }
    }
    return enrolled
  }
  func keep(in store: any EnrolmentStore) async throws {}
  func pair() async throws(SetupFailure) {
    try record(.pair)
    // A held Pair is abandoned by close() before its reply arrives.
    if holdPair { await withCheckedContinuation { pairContinuation = $0 } } else { enrolled = true }
  }
  func holdHellos() { holdHello = true }
  func hello() async throws(SetupFailure) -> SessionReport {
    try record(.hello)
    if holdHello {
      await withCheckedContinuation {
        helloContinuation = $0
        wakeHoldWaiters()
      }
    }
    return SessionReport(reportsWiFi: false)
  }
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan {
    Issue.record("scanned a controller that does not report Wi-Fi")
    throw .protocolError
  }
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus {
    Issue.record("read the status of a controller that does not report Wi-Fi")
    throw .protocolError
  }
  func readNetwork() async throws(SetupFailure) -> NetworkSettings {
    try record(.read)
    return settings
  }
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  {
    try record(.write)
    lastChange = change
    writtenVersion = expectedVersion
    return 8
  }
  func setTime(_ date: Date) async throws(SetupFailure) { try record(.time) }
  func close() async {
    closed = true
    pairContinuation?.resume()
    pairContinuation = nil
    helloContinuation?.resume()
    helloContinuation = nil
    enrolledContinuation?.resume()
    enrolledContinuation = nil
  }
}
private struct Factory: ControllerClientFactory {
  let fake: FakeClient
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  {
    guard setupCode == "valid" else { throw .malformed }
    return fake
  }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? { nil }
}
@MainActor private final class TestClock: SetupClock {
  var now: Duration = .zero
  var sleeper: CheckedContinuation<Void, any Error>?
  func sleep(until deadline: Duration) async throws {
    if now >= deadline { return }
    try await withCheckedThrowingContinuation { sleeper = $0 }
  }
  func advance() {
    now = .seconds(120)
    sleeper?.resume()
    sleeper = nil
  }
  func finish() {
    sleeper?.resume(throwing: CancellationError())
    sleeper = nil
  }
}
@MainActor private func makeFlow(
  _ client: FakeClient, clock: TestClock, transport: FakeTransport = FakeTransport()
) async throws -> SetupFlow {
  let flow = SetupFlow(
    factory: Factory(fake: client), store: NoEnrolmentStore(), transportFactory: { transport },
    clock: clock)
  try flow.submitCode("valid")
  #expect(flow.state == .connecting)
  await flow.connect()
  #expect(flow.state == .openWindow)
  return flow
}
@Test @MainActor func happyPath() async throws {
  let client = FakeClient()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  await flow.confirmWindowOpened()
  #expect(flow.state == .editingNetwork(client.settings))
  await flow.writeNetwork(
    NetworkChange(ssid: "home", passphrase: nil, country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  #expect(await client.writtenVersion == 7)
  await flow.setTime(Date(timeIntervalSince1970: 1_700_000_000))
  #expect(flow.state == .finished(version: 8, timeSet: true))
  #expect(await client.calls == [.discover, .pair, .hello, .read, .write, .time])
}
@Test @MainActor func pairingRefusals() async throws {
  let cases: [(SetupFailure, SetupFlow.RetryTarget)] = [
    (.windowClosed, .openWindow), (.wrongProof, .enterCode), (.tableFull, .openWindow),
    (.controllerMismatch, .enterCode), (.timedOut, .connecting),
    (.protocolError, .connecting),
  ]
  for (failure, target) in cases {
    let client = FakeClient(failure)
    let clock = TestClock()
    let flow = try await makeFlow(client, clock: clock)
    await flow.confirmWindowOpened()
    #expect(flow.state == .failed(failure, target))
    #expect(await client.calls == [.discover, .pair])
    await flow.retry()
    switch target {
    case .enterCode:
      #expect(flow.state == .enterCode)
      #expect(await client.closed)
    case .openWindow: #expect(flow.state == .openWindow)
    case .connecting: #expect(flow.state == .openWindow)
    default: Issue.record("Unexpected retry target")
    }
    clock.finish()
  }
}
@Test @MainActor func writeRefusals() async throws {
  for failure in [SetupFailure.staleVersion, .invalidConfig] {
    let client = FakeClient(failure, at: .write)
    let clock = TestClock()
    let flow = try await makeFlow(client, clock: clock)
    await flow.confirmWindowOpened()
    await flow.writeNetwork(
      NetworkChange(ssid: "home", passphrase: nil, country: "CA", hostname: "unit"))
    #expect(
      flow.state == .failed(failure, failure == .staleVersion ? .readingNetwork : .editingNetwork))
    await flow.retry()
    #expect(flow.state == .editingNetwork(client.settings))
    let reads = await client.calls.filter { $0 == .read }.count
    #expect(reads == (failure == .staleVersion ? 2 : 1))
    clock.finish()
  }
}
@Test @MainActor func droppedWhileReading() async throws {
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(FakeClient(.connectionDropped, at: .read), clock: clock)
  await flow.confirmWindowOpened()
  #expect(flow.state == .failed(.connectionDropped, .connecting))
}
@Test @MainActor func expiredWhilePairPending() async throws {
  let client = FakeClient(holdPair: true)
  let clock = TestClock()
  let flow = try await makeFlow(client, clock: clock)
  let run = Task { await flow.confirmWindowOpened() }
  for _ in 0..<1000 {
    if await client.pairContinuation != nil { break }
    await Task.yield()
  }
  #expect(flow.state == .pairing)
  clock.advance()
  await run.value
  #expect(flow.state == .failed(.windowClosed, .openWindow))
  #expect(await client.closed)
  #expect(await client.calls == [.discover, .pair])
}
@Test @MainActor func malformedCode() {
  let flow = SetupFlow(
    factory: Factory(fake: FakeClient()), store: NoEnrolmentStore(),
    transportFactory: { FakeTransport() })
  #expect(throws: SetupCodeError.malformed) { try flow.submitCode("bad") }
  #expect(flow.state == .enterCode)
}
@Test @MainActor func changedSSIDRequiresPassphrase() async throws {
  let client = FakeClient()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  await flow.confirmWindowOpened()
  let change = NetworkChange(ssid: "new", passphrase: nil, country: "CA", hostname: "unit")
  await flow.writeNetwork(change)
  #expect(flow.state == .failed(.invalidConfig, .editingNetwork))
  #expect(await client.calls == [.discover, .pair, .hello, .read])
  await flow.retry()
  await flow.writeNetwork(
    NetworkChange(ssid: "new", passphrase: "", country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
}

@Test @MainActor func optionalTimeRefusalPreservesWrittenNetwork() async throws {
  let client = FakeClient(.timeNeedsButton, at: .time)
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  await flow.confirmWindowOpened()
  await flow.writeNetwork(
    NetworkChange(ssid: "home", passphrase: nil, country: "CA", hostname: "unit"))
  await flow.setTime()
  #expect(flow.state == .failed(.timeNeedsButton, .written(8)))
  await flow.retry()
  #expect(flow.state == .written(8))
}

@Test @MainActor func resetDuringPairIgnoresLateCompletion() async throws {
  let client = FakeClient(holdPair: true)
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  let run = Task { await flow.confirmWindowOpened() }
  for _ in 0..<1000 {
    if await client.pairContinuation != nil { break }
    await Task.yield()
  }
  await flow.reset()
  await run.value
  #expect(flow.state == .enterCode)
  #expect(flow.controller == nil)
  #expect(await client.calls == [.discover, .pair])
}

@Test @MainActor func bluetoothUnavailableDuringConnection() async throws {
  let flow = SetupFlow(
    factory: Factory(fake: FakeClient()), store: NoEnrolmentStore(),
    transportFactory: { FakeTransport(failure: .unreachable) }
  )
  try flow.submitCode("valid")
  #expect(flow.state == .connecting)
  await flow.connect()
  #expect(flow.state == .failed(.bluetoothUnavailable, .connecting))
  await flow.retry()
  #expect(flow.state == .failed(.bluetoothUnavailable, .connecting))
}

/// A controller was found but its link never became ready: not reported as
/// Bluetooth being unavailable.
@Test @MainActor func aLinkThatIsNotReadyIsReportedAsSuch() async throws {
  let flow = SetupFlow(
    factory: Factory(fake: FakeClient()), store: NoEnrolmentStore(),
    transportFactory: { FakeTransport(failure: .notReady) }
  )
  try flow.submitCode("valid")
  await flow.connect()
  #expect(flow.state == .failed(.linkNotReady, .connecting))
}

// MARK: - Network clear (review finding 1)

@Test @MainActor func clearingAnExistingNetworkReachesTheClient() async throws {
  let client = FakeClient()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  await flow.confirmWindowOpened()
  let clear = NetworkChange(ssid: nil, passphrase: nil, country: "CA", hostname: "unit")
  await flow.writeNetwork(clear)
  #expect(flow.state == .written(8))
  #expect(await client.lastChange == clear)
  #expect(await client.writtenVersion == 7)
}

@Test func networkChangeValidation() {
  let held = NetworkSettings(
    version: 7, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")
  let none = NetworkSettings(
    version: 7, ssid: "home", passphraseSet: false, country: "CA", hostname: "unit")
  func change(_ ssid: String?, _ passphrase: String?) -> NetworkChange {
    NetworkChange(ssid: ssid, passphrase: passphrase, country: "CA", hostname: "unit")
  }
  #expect(change(nil, nil).isValid(comparedTo: held))
  #expect(!change(nil, "secret-pass").isValid(comparedTo: held))
  #expect(change("home", nil).isValid(comparedTo: held))
  #expect(!change("home", nil).isValid(comparedTo: none))
  #expect(!change("other", nil).isValid(comparedTo: held))
  #expect(change("other", "secret-pass").isValid(comparedTo: held))
}

// MARK: - Time after a lost session (review finding 2)

@MainActor private func writtenFlow(
  _ client: FakeClient, clock: TestClock, transport: FakeTransport
) async throws -> SetupFlow {
  let flow = try await makeFlow(client, clock: clock, transport: transport)
  await flow.confirmWindowOpened()
  await flow.writeNetwork(
    NetworkChange(ssid: "home", passphrase: nil, country: "CA", hostname: "unit"))
  #expect(flow.state == .written(8))
  return flow
}

@Test @MainActor func timeRetryReconnectsWithoutPairing() async throws {
  for failure in [SetupFailure.connectionDropped, .timedOut, .protocolError] {
    let client = FakeClient(failure, at: .time, times: 1)
    let transport = FakeTransport()
    let clock = TestClock()
    let flow = try await writtenFlow(client, clock: clock, transport: transport)
    await flow.setTime()
    #expect(flow.state == .failed(failure, .connecting))
    #expect(flow.writtenVersion == 8)
    #expect(await transport.closes == 1, "the failed session's connection is closed")

    await flow.retry()
    #expect(flow.state == .written(8))
    #expect(await transport.opens == 2)
    await flow.setTime()
    #expect(flow.state == .finished(version: 8, timeSet: true))
    #expect(
      await client.calls == [
        .discover, .pair, .hello, .read, .write, .time, .discover, .hello, .time,
      ])
    #expect(await transport.closes == 2)
    #expect(await transport.mostOpen == 1)
    clock.finish()
  }
}

@Test @MainActor func timeRefusalKeepsTheSession() async throws {
  let client = FakeClient(.timeRejected, at: .time, times: 1)
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await writtenFlow(client, clock: clock, transport: transport)
  await flow.setTime()
  #expect(flow.state == .failed(.timeRejected, .written(8)))
  #expect(await transport.closes == 0)
  await flow.retry()
  await flow.setTime()
  #expect(flow.state == .finished(version: 8, timeSet: true))
  #expect(await transport.opens == 1)
  #expect(await transport.closes == 1)
}

// MARK: - Connection limit: close exactly once, never two open

@Test @MainActor func doneAfterWrittenClosesOnce() async throws {
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await writtenFlow(FakeClient(), clock: clock, transport: transport)
  await flow.finish()
  #expect(flow.state == .finished(version: 8, timeSet: false))
  await flow.finish()
  await flow.reset()
  #expect(await transport.opens == 1)
  #expect(await transport.closes == 1)
}

@Test @MainActor func timeSuccessClosesOnce() async throws {
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await writtenFlow(FakeClient(), clock: clock, transport: transport)
  await flow.setTime()
  #expect(flow.state == .finished(version: 8, timeSet: true))
  await flow.reset()
  #expect(await transport.closes == 1)
}

@Test @MainActor func terminalFailuresCloseOnce() async throws {
  let cases: [(SetupFailure, FakeClient.Step)] = [
    (.connectionDropped, .read), (.protocolError, .hello), (.timedOut, .pair),
    (.wrongProof, .pair), (.windowClosed, .pair), (.tableFull, .pair),
    (.controllerMismatch, .discover),
  ]
  for (failure, step) in cases {
    let transport = FakeTransport()
    let clock = TestClock()
    let flow = try await makeFlow(
      FakeClient(failure, at: step), clock: clock, transport: transport)
    await flow.confirmWindowOpened()
    guard case .failed(failure, _) = flow.state else {
      Issue.record("\(failure) at \(step): \(flow.state)")
      continue
    }
    await flow.reset()
    #expect(await transport.opens == 1, "\(failure)")
    #expect(await transport.closes == 1, "\(failure)")
    clock.finish()
  }
}

@Test @MainActor func windowExpiryClosesOnce() async throws {
  let client = FakeClient(holdPair: true)
  let transport = FakeTransport()
  let clock = TestClock()
  let flow = try await makeFlow(client, clock: clock, transport: transport)
  let run = Task { await flow.confirmWindowOpened() }
  for _ in 0..<1000 {
    if await client.pairContinuation != nil { break }
    await Task.yield()
  }
  clock.advance()
  await run.value
  #expect(flow.state == .failed(.windowClosed, .openWindow))
  #expect(await transport.closes == 1)
  await flow.retry()
  #expect(flow.state == .openWindow)
  #expect(await transport.opens == 2)
  #expect(await transport.mostOpen == 1)
  clock.finish()
}

@Test @MainActor func resetClosesOnce() async throws {
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(FakeClient(), clock: clock, transport: transport)
  await flow.confirmWindowOpened()
  await flow.reset()
  await flow.reset()
  #expect(flow.state == .enterCode)
  #expect(await transport.closes == 1)
}

@Test @MainActor func backgroundWhileEditingClosesAndResumesWithoutPairing() async throws {
  let client = FakeClient()
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock, transport: transport)
  await flow.confirmWindowOpened()
  await flow.suspend()
  #expect(flow.state == .suspended)
  await flow.suspend()
  #expect(await transport.closes == 1)
  await flow.retry()
  #expect(flow.state == .editingNetwork(client.settings))
  #expect(await client.calls == [.discover, .pair, .hello, .read, .discover, .hello, .read])
  #expect(await transport.opens == 2)
  #expect(await transport.mostOpen == 1)
}

@Test @MainActor func backgroundWithTheWindowStepSuspendsAndReturnsToIt() async throws {
  let client = FakeClient()
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock, transport: transport)
  await flow.suspend()
  #expect(flow.state == .suspended)
  #expect(await transport.closes == 1)
  await flow.retry()
  #expect(flow.state == .openWindow)
  #expect(await client.calls.isEmpty)
  #expect(await transport.opens == 2)
  #expect(await transport.mostOpen == 1)
}

@Test @MainActor func backgroundBeforeAConnectOpensSuspendsIt() async throws {
  let client = FakeClient()
  let transport = FakeTransport()
  let flow = SetupFlow(
    factory: Factory(fake: client), store: NoEnrolmentStore(),
    transportFactory: { transport }, clock: TestClock())
  try flow.submitCode("valid")
  await client.holdEnrolledCheck()
  let run = Task { await flow.connect() }
  await client.held()
  await flow.suspend()
  // Closing releases the check; without a close the connect would go on.
  await client.releaseEnrolledCheck()
  await run.value
  #expect(flow.state == .suspended)
  #expect(await transport.opens == 0)
  await flow.retry()
  #expect(flow.state == .openWindow)
  #expect(await transport.opens == 1)
}

@Test @MainActor func backgroundDuringPairSuspendsAndAbandonsIt() async throws {
  let client = FakeClient(holdPair: true)
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await makeFlow(client, clock: clock)
  let run = Task { await flow.confirmWindowOpened() }
  for _ in 0..<1000 {
    if await client.pairContinuation != nil { break }
    await Task.yield()
  }
  #expect(flow.state == .pairing)
  await flow.suspend()
  await run.value
  #expect(flow.state == .suspended)
  #expect(await client.closed)
  #expect(await client.calls == [.discover, .pair])
}

@Test @MainActor func backgroundDuringAReconnectAfterWritingKeepsTheResult() async throws {
  let client = FakeClient()
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await writtenFlow(client, clock: clock, transport: transport)
  await flow.suspend()
  await client.holdHellos()
  let run = Task { await flow.setTime() }
  await client.held()
  #expect(flow.state == .greeting)
  await flow.suspend()
  await run.value
  #expect(flow.state == .written(8))
  #expect(!(await client.calls.contains(.time)))
  let opens = await transport.opens
  #expect(await transport.closes == opens)
  #expect(await transport.mostOpen == 1)
}

@Test @MainActor func backgroundAfterWritingKeepsTheResultAndReconnectsForTime() async throws {
  let client = FakeClient()
  let transport = FakeTransport()
  let clock = TestClock()
  defer { clock.finish() }
  let flow = try await writtenFlow(client, clock: clock, transport: transport)
  await flow.suspend()
  #expect(flow.state == .written(8))
  #expect(await transport.closes == 1)
  await flow.setTime()
  #expect(flow.state == .finished(version: 8, timeSet: true))
  #expect(await client.calls.suffix(3) == [.discover, .hello, .time])
  #expect(await transport.opens == 2)
  #expect(await transport.closes == 2)
  #expect(await transport.mostOpen == 1)
}

@Test @MainActor func backgroundBeforeConnectingOpensNothing() async throws {
  let transport = FakeTransport()
  let flow = SetupFlow(
    factory: Factory(fake: FakeClient()), store: NoEnrolmentStore(),
    transportFactory: { transport }, clock: TestClock())
  await flow.suspend()
  try flow.submitCode("valid")
  await flow.suspend()
  #expect(flow.state == .connecting)
  #expect(await transport.opens == 0)
  #expect(await transport.closes == 0)
}
