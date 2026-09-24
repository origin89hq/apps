import Foundation

enum WebSocketEvent {
  case ready
  /// No path to the controller yet. `localNetworkDenied` when the app may not
  /// reach the local network; the permission prompt can still be up.
  case waiting(localNetworkDenied: Bool)
  case message(Data)
  /// A text frame: KM43 sends binary frames only (P-034).
  case textMessage
  /// The message handed to `send` left.
  case sent
  case closed
}
@MainActor protocol WebSocketDriver: AnyObject {
  var event: ((WebSocketEvent) -> Void)? { get set }
  /// Connect and upgrade; binary frames of at most `maximumMessage` bytes.
  func start(url: URL, maximumMessage: Int)
  /// One binary frame; `.sent` or `.closed` follows.
  func send(_ message: Data)
  func cancel()
}

/// Why the transport ended a WebSocket connection, for the log.
enum WebSocketEnd: String {
  case closedByFlow = "closed by the setup flow"
  case openTimedOut = "no upgraded connection before the open timeout"
  case localNetworkDenied = "local network access is denied"
  case noPath = "no path to the address"
  case readTimedOut = "no reply before the read timeout"
  case writeTimedOut = "a frame was not sent before the write timeout"
  case cancelled = "the request waiting on it was cancelled"
  case textFrame = "a text frame arrived"
  case peerClosed = "the connection closed"
  case backlog = "too many unread messages"
  case sendRefused = "a frame could not be sent"
}

/// KM43 over a WebSocket on the site network: one message per binary frame
/// (P-034). The address is a candidate until Discover answers on it (P-225).
@MainActor public final class WebSocketTransport: FrameTransport {
  private let url: URL
  private let maximumMessage: Int
  private let driver: any WebSocketDriver
  private let timeout: Duration
  private var connected = false
  private var generation = 0
  private var messages: [Data] = []
  /// The open is waiting with local network access denied.
  private var localNetworkDenied = false
  private var opening: CheckedContinuation<Void, any Error>?
  private var reading: CheckedContinuation<Data, any Error>?
  private var writing: CheckedContinuation<Void, any Error>?
  private var openTimer: Task<Void, Never>?
  private var readTimer: Task<Void, Never>?
  private var writeTimer: Task<Void, Never>?

  public convenience init(url: URL, maximumMessage: Int) {
    self.init(url: url, maximumMessage: maximumMessage, driver: NetworkWebSocketDriver())
  }
  init(
    url: URL, maximumMessage: Int, driver: any WebSocketDriver, timeout: Duration = .seconds(10)
  ) {
    self.url = url
    self.maximumMessage = maximumMessage
    self.driver = driver
    self.timeout = timeout
    driver.event = { [weak self] event in self?.handle(event) }
  }
  public func open() async throws(TransportError) {
    guard !Task.isCancelled else { throw .dropped }
    if connected { return }
    guard opening == nil else { throw .unreachable }
    localNetworkDenied = false
    let operation = generation
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          opening = continuation
          openTimer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, let self else { return }
            if self.localNetworkDenied {
              self.terminate(.localNetworkDenied, .localNetworkDenied)
            } else {
              self.terminate(.unreachable, .openTimedOut)
            }
          }
          driver.start(url: url, maximumMessage: maximumMessage)
        }
      } onCancel: {
        Task { @MainActor in
          if self.generation == operation { self.terminate(.dropped, .cancelled) }
        }
      }
    } catch { throw (error as? TransportError) ?? .unreachable }
  }
  public func send(_ frame: Data) async throws(TransportError) {
    guard !Task.isCancelled, connected, writing == nil else { throw .dropped }
    guard !frame.isEmpty, frame.count <= maximumMessage else {
      terminate(.dropped, .sendRefused)
      throw .dropped
    }
    let operation = generation
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          writing = continuation
          writeTimer = timer(error: .timedOut, .writeTimedOut)
          driver.send(frame)
        }
      } onCancel: {
        Task { @MainActor in
          if self.generation == operation { self.terminate(.dropped, .cancelled) }
        }
      }
    } catch { throw (error as? TransportError) ?? .dropped }
  }
  public func receive() async throws(TransportError) -> Data {
    guard !Task.isCancelled, connected, reading == nil else { throw .dropped }
    if !messages.isEmpty { return messages.removeFirst() }
    let operation = generation
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          reading = continuation
          readTimer = timer(error: .timedOut, .readTimedOut)
        }
      } onCancel: {
        Task { @MainActor in
          if self.generation == operation { self.terminate(.dropped, .cancelled) }
        }
      }
    } catch { throw (error as? TransportError) ?? .dropped }
  }
  public func close() async { terminate(.dropped, .closedByFlow) }

  private func timer(error: TransportError, _ end: WebSocketEnd) -> Task<Void, Never> {
    Task { [weak self, timeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard !Task.isCancelled else { return }
      self?.terminate(error, end)
    }
  }
  private func handle(_ event: WebSocketEvent) {
    switch event {
    case .ready:
      guard opening != nil else { return }
      connected = true
      openTimer?.cancel()
      openTimer = nil
      opening?.resume()
      opening = nil
    case .waiting(let denied):
      guard opening != nil else { return }
      // Denied access may be the permission prompt still up: wait for the
      // open timeout. Any other wait means no path now.
      if denied {
        localNetworkDenied = true
      } else {
        terminate(.unreachable, .noPath)
      }
    case .message(let message):
      guard connected else { return }
      if let reading {
        self.reading = nil
        readTimer?.cancel()
        readTimer = nil
        reading.resume(returning: message)
      } else {
        guard messages.count < 8 else {
          terminate(.dropped, .backlog)
          return
        }
        messages.append(message)
      }
    case .textMessage: terminate(.dropped, .textFrame)
    case .sent:
      guard connected, let writing else { return }
      self.writing = nil
      writeTimer?.cancel()
      writeTimer = nil
      writing.resume()
    case .closed: terminate(opening == nil ? .dropped : .unreachable, .peerClosed)
    }
  }
  private func terminate(_ error: TransportError, _ end: WebSocketEnd) {
    if connected || opening != nil {
      let phase = connected ? "connection" : "open"
      if end == .closedByFlow {
        SetupLog.webSocket.info(
          "\(phase, privacy: .public) ended: \(end.rawValue, privacy: .public)")
      } else {
        SetupLog.webSocket.error(
          "\(phase, privacy: .public) ended: \(end.rawValue, privacy: .public)")
      }
    }
    generation += 1
    connected = false
    localNetworkDenied = false
    openTimer?.cancel()
    openTimer = nil
    readTimer?.cancel()
    readTimer = nil
    writeTimer?.cancel()
    writeTimer = nil
    opening?.resume(throwing: error)
    opening = nil
    reading?.resume(throwing: error)
    reading = nil
    writing?.resume(throwing: error)
    writing = nil
    messages.removeAll()
    driver.cancel()
  }
}
