import Foundation
import Testing

@testable import SetupKit

private let identifiers = BluetoothIdentifiers(service: "1234", rx: "1235", tx: "1236")
/// Models look-alike peripherals in range: `start` connects to the first one
/// not excluded, and a scan that finds none never reports anything.
@MainActor final class FakeDriver: BluetoothDriver {
  var event: ((BluetoothEvent) -> Void)?
  var maximumWriteLength = 20
  var canSend = true
  var profile = BluetoothProfile(
    serviceCount: 1, rxCount: 1, txCount: 1,
    rxWritesWithoutResponse: true, txNotifies: true)
  var peripherals = [UUID()]
  private(set) var peer: UUID?
  /// The exclusion set of every scan, in order.
  private(set) var scans: [Set<UUID>] = []
  private(set) var connections = 0
  private(set) var mostConnections = 0
  var writes: [Data] = []
  var subscriptions = 0
  var disconnected = false
  var autoSubscribe = true
  var blockAfterWrite = false
  func start(identifiers: BluetoothIdentifiers, excluding: Set<UUID>) {
    scans.append(excluding)
    guard let found = peripherals.first(where: { !excluding.contains($0) }) else { return }
    peer = found
    connections += 1
    mostConnections = max(mostConnections, connections)
    event?(.profile(profile))
  }
  func subscribe() {
    subscriptions += 1
    if autoSubscribe { event?(.subscribed) }
  }
  func write(_ value: Data) {
    writes.append(value)
    if blockAfterWrite { canSend = false }
  }
  func disconnect() {
    disconnected = true
    if peer != nil { connections -= 1 }
    peer = nil
  }
}
/// Test-only mutable codec state is guarded by a lock, matching the synchronous Sendable seam.
final class FakeCodec: FragmentCodec, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Data] = []
  private var resets = 0
  let malformed: Bool
  init(malformed: Bool = false) { self.malformed = malformed }
  var resetCount: Int { lock.withLock { resets } }
  func reset() {
    lock.withLock {
      storage.removeAll()
      resets += 1
    }
  }
  func fragments(for message: Data, valueLimit: Int) throws(TransportError) -> [Data] {
    guard valueLimit == 20 else { throw .dropped }
    return [Data([1]), Data([2]), Data([3])]
  }
  func receive(fragment: Data, nowMs: UInt64) throws(TransportError) -> Data? {
    if malformed { throw .dropped }
    return lock.withLock {
      storage.append(fragment)
      return storage.count == 2 ? Data(storage.flatMap { $0 }) : nil
    }
  }
}
@Test @MainActor func bluetoothOpenWaitsForSubscription() async throws {
  let driver = FakeDriver()
  driver.autoSubscribe = false
  let transport = BluetoothTransport(identifiers: identifiers, codec: FakeCodec(), driver: driver)
  let opening = Task { try await transport.open() }
  for _ in 0..<1000 {
    if driver.subscriptions == 1 { break }
    await Task.yield()
  }
  #expect(driver.subscriptions == 1)
  await #expect(throws: TransportError.dropped) { try await transport.send(Data([1])) }
  driver.event?(.subscribed)
  try await opening.value
  try await transport.send(Data([1]))
  #expect(driver.writes == [Data([1]), Data([2]), Data([3])])
  await transport.close()
}
@Test @MainActor func bluetoothRejectsMissingAmbiguousAndWrongProperties() async {
  for profile in [
    BluetoothProfile(
      serviceCount: 0, rxCount: 1, txCount: 1, rxWritesWithoutResponse: true, txNotifies: true),
    BluetoothProfile(
      serviceCount: 1, rxCount: 0, txCount: 1, rxWritesWithoutResponse: true, txNotifies: true),
    BluetoothProfile(
      serviceCount: 1, rxCount: 1, txCount: 2, rxWritesWithoutResponse: true, txNotifies: true),
    BluetoothProfile(
      serviceCount: 1, rxCount: 1, txCount: 1, rxWritesWithoutResponse: false, txNotifies: true),
    BluetoothProfile(
      serviceCount: 1, rxCount: 1, txCount: 1, rxWritesWithoutResponse: true, txNotifies: false),
  ] {
    let driver = FakeDriver()
    driver.profile = profile
    let transport = BluetoothTransport(identifiers: identifiers, codec: FakeCodec(), driver: driver)
    await #expect(throws: TransportError.unreachable) { try await transport.open() }
    #expect(driver.subscriptions == 0)
    #expect(driver.disconnected)
  }
}
@Test @MainActor func bluetoothSendRespectsBackpressure() async throws {
  let driver = FakeDriver()
  driver.blockAfterWrite = true
  let transport = BluetoothTransport(identifiers: identifiers, codec: FakeCodec(), driver: driver)
  try await transport.open()
  let sending = Task { try await transport.send(Data([99])) }
  for expected in 1...3 {
    for _ in 0..<1000 {
      if driver.writes.count == expected { break }
      await Task.yield()
    }
    #expect(driver.writes.count == expected)
    driver.event?(.writable)
    await Task.yield()
    #expect(driver.writes.count == expected)
    driver.canSend = true
    driver.event?(.writable)
  }
  try await sending.value
  #expect(driver.writes == [Data([1]), Data([2]), Data([3])])
  await transport.close()
}
@Test @MainActor func bluetoothReassemblesNotifications() async throws {
  let driver = FakeDriver()
  let transport = BluetoothTransport(identifiers: identifiers, codec: FakeCodec(), driver: driver)
  try await transport.open()
  driver.event?(.value(Data([7])))
  driver.event?(.value(Data([8])))
  #expect(try await transport.receive() == Data([7, 8]))
  await transport.close()
}
@Test @MainActor func bluetoothDropsMalformedAndDisconnectedFrames() async throws {
  for malformed in [true, false] {
    let driver = FakeDriver()
    let codec = FakeCodec(malformed: malformed)
    let transport = BluetoothTransport(identifiers: identifiers, codec: codec, driver: driver)
    try await transport.open()
    let reading = Task { try await transport.receive() }
    await Task.yield()
    driver.event?(malformed ? .value(Data([7])) : .disconnected)
    await #expect(throws: TransportError.dropped) { try await reading.value }
    #expect(driver.disconnected)
    #expect(codec.resetCount == 2)
  }
}
@Test @MainActor func bluetoothOpenAndReceiveTimeouts() async throws {
  let driver = FakeDriver()
  driver.autoSubscribe = false
  let transport = BluetoothTransport(
    identifiers: identifiers, codec: FakeCodec(), driver: driver, timeout: .milliseconds(10))
  // Found and connected, but never subscribed: not reported as Bluetooth being off.
  await #expect(throws: TransportError.notReady) { try await transport.open() }
  driver.autoSubscribe = true
  try await transport.open()
  await #expect(throws: TransportError.timedOut) { try await transport.receive() }
  #expect(driver.disconnected)
}
@Test @MainActor func bluetoothOpenThatFindsNoPeripheralIsUnreachable() async {
  let driver = FakeDriver()
  driver.peripherals = []
  let transport = BluetoothTransport(
    identifiers: identifiers, codec: FakeCodec(), driver: driver, timeout: .milliseconds(10))
  await #expect(throws: TransportError.unreachable) { try await transport.open() }
  #expect(driver.scans.count == 1)
}

@Test @MainActor func bluetoothDisconnectUnblocksBackpressure() async throws {
  let driver = FakeDriver()
  driver.canSend = false
  let codec = FakeCodec()
  let transport = BluetoothTransport(identifiers: identifiers, codec: codec, driver: driver)
  try await transport.open()
  let sending = Task { try await transport.send(Data([1])) }
  await Task.yield()
  driver.event?(.disconnected)
  await #expect(throws: TransportError.dropped) { try await sending.value }
  #expect(driver.writes.isEmpty)
  #expect(codec.resetCount == 2)
}

@Test @MainActor func bluetoothCancelledReadClosesConnection() async throws {
  let driver = FakeDriver()
  let transport = BluetoothTransport(identifiers: identifiers, codec: FakeCodec(), driver: driver)
  try await transport.open()
  let reading = Task { try await transport.receive() }
  await Task.yield()
  reading.cancel()
  await #expect(throws: TransportError.dropped) { try await reading.value }
  await transport.close()
  #expect(driver.disconnected)
}

/// The open timer's sleep ends while the main actor is busy, and the
/// subscription lands before the timer body runs. The stale timer must not
/// drop the connection that just opened.
@Test @MainActor func bluetoothTimerCancelledAfterSleepKeepsConnection() async throws {
  let driver = FakeDriver()
  driver.autoSubscribe = false
  let transport = BluetoothTransport(
    identifiers: identifiers, codec: FakeCodec(), driver: driver, timeout: .milliseconds(10))
  let opening = Task { try await transport.open() }
  for _ in 0..<1000 {
    if driver.subscriptions == 1 { break }
    await Task.yield()
  }
  #expect(driver.subscriptions == 1)
  // Hold the main actor past the timeout so the timer body is queued behind it.
  block(for: 0.1)
  driver.event?(.subscribed)
  try await opening.value
  for _ in 0..<100 { await Task.yield() }
  try await Task.sleep(for: .milliseconds(20))
  #expect(!driver.disconnected)
  try await transport.send(Data([1]))
  #expect(driver.writes == [Data([1]), Data([2]), Data([3])])
  await transport.close()
}
/// Blocks the calling thread without yielding, unlike `Task.sleep`.
private func block(for seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
