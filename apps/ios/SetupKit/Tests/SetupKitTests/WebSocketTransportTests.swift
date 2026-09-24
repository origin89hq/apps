import Foundation
import Testing

@testable import SetupKit

private let url = URL(string: "ws://192.168.1.42:80/km43")!

/// Answers `start` with `onStart`, and records what the transport asks for.
@MainActor private final class FakeSocket: WebSocketDriver {
  var event: ((WebSocketEvent) -> Void)?
  var onStart: [WebSocketEvent] = [.ready]
  var autoSent = true
  private(set) var starts: [(URL, Int)] = []
  private(set) var sent: [Data] = []
  private(set) var cancels = 0
  func start(url: URL, maximumMessage: Int) {
    starts.append((url, maximumMessage))
    for event in onStart { self.event?(event) }
  }
  func send(_ message: Data) {
    sent.append(message)
    if autoSent { event?(.sent) }
  }
  func cancel() { cancels += 1 }
}

@MainActor private func transport(_ socket: FakeSocket, timeout: Duration = .seconds(5))
  -> WebSocketTransport
{
  WebSocketTransport(url: url, maximumMessage: 1024, driver: socket, timeout: timeout)
}

@Test @MainActor func anUpgradedSocketCarriesOneMessagePerFrame() async throws {
  let socket = FakeSocket()
  let link = transport(socket)
  try await link.open()
  #expect(socket.starts.map(\.0) == [url])
  #expect(socket.starts.map(\.1) == [1024])
  try await link.send(Data([1, 2, 3]))
  #expect(socket.sent == [Data([1, 2, 3])])
  socket.event?(.message(Data([4])))
  socket.event?(.message(Data([5])))
  #expect(try await link.receive() == Data([4]))
  #expect(try await link.receive() == Data([5]))
  await link.close()
  #expect(socket.cancels == 1)
  await #expect(throws: TransportError.dropped) { try await link.receive() }
}

/// A path that is not there fails at once; a denied local network waits for
/// the prompt until the open timeout, then says so.
@Test @MainActor func anOpenWithNoPathFailsAndADeniedOneTimesOutAsDenied() async throws {
  let socket = FakeSocket()
  socket.onStart = [.waiting(localNetworkDenied: false)]
  let link = transport(socket)
  await #expect(throws: TransportError.unreachable) { try await link.open() }

  socket.onStart = [.waiting(localNetworkDenied: true)]
  let denied = transport(socket, timeout: .milliseconds(20))
  await #expect(throws: TransportError.localNetworkDenied) { try await denied.open() }

  socket.onStart = []
  let silent = transport(socket, timeout: .milliseconds(20))
  await #expect(throws: TransportError.unreachable) { try await silent.open() }
}

/// The prompt was answered with Allow: the waiting open still succeeds.
@Test @MainActor func aDeniedWaitThatBecomesReadyOpens() async throws {
  let socket = FakeSocket()
  socket.onStart = [.waiting(localNetworkDenied: true), .ready]
  try await transport(socket).open()
}

@Test @MainActor func aTextFrameOrAPeerCloseEndsTheConnection() async throws {
  let socket = FakeSocket()
  let link = transport(socket)
  try await link.open()
  let reading = Task { try await link.receive() }
  await Task.yield()
  socket.event?(.textMessage)
  await #expect(throws: TransportError.dropped) { try await reading.value }
  #expect(socket.cancels == 1)

  try await link.open()
  socket.event?(.closed)
  await #expect(throws: TransportError.dropped) { try await link.send(Data([1])) }
}

@Test @MainActor func aFrameAboveTheMessageBoundIsNotSent() async throws {
  let socket = FakeSocket()
  let link = transport(socket)
  try await link.open()
  await #expect(throws: TransportError.dropped) { try await link.send(Data(count: 1025)) }
  await #expect(throws: TransportError.dropped) { try await link.send(Data()) }
  #expect(socket.sent.isEmpty)
}

@Test @MainActor func unreadMessagesPastTheBacklogEndTheConnection() async throws {
  let socket = FakeSocket()
  let link = transport(socket)
  try await link.open()
  for byte in 0..<9 { socket.event?(.message(Data([UInt8(byte)]))) }
  await #expect(throws: TransportError.dropped) { try await link.receive() }
}

@Test @MainActor func aSendOrReadWithNoAnswerTimesOut() async throws {
  let socket = FakeSocket()
  socket.autoSent = false
  let link = transport(socket, timeout: .milliseconds(20))
  try await link.open()
  await #expect(throws: TransportError.timedOut) { try await link.send(Data([1])) }
  try await link.open()
  await #expect(throws: TransportError.timedOut) { try await link.receive() }
}
