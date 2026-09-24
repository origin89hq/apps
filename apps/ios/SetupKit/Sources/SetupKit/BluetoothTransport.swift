import Foundation

struct BluetoothProfile {
  var serviceCount: Int
  var rxCount: Int
  var txCount: Int
  var rxWritesWithoutResponse: Bool
  var txNotifies: Bool
}
enum BluetoothEvent {
  case profile(BluetoothProfile)
  case subscribed
  case value(Data)
  case writable
  case unavailable
  case disconnected
}
@MainActor protocol BluetoothDriver: AnyObject {
  var event: ((BluetoothEvent) -> Void)? { get set }
  var maximumWriteLength: Int { get }
  var canSend: Bool { get }
  /// The connected peripheral, once a connection is attempted.
  var peer: UUID? { get }
  /// Scan and connect to the first advertising peripheral not in `excluding`.
  func start(identifiers: BluetoothIdentifiers, excluding: Set<UUID>)
  func subscribe()
  func write(_ value: Data)
  func disconnect()
}

/// Why the transport ended a connection, for the log.
enum TransportEnd: String {
  case closedByFlow = "closed by the setup flow"
  case openTimedOut = "no peripheral found before the open timeout"
  case notReady = "a peripheral was found but not subscribed before the open timeout"
  case readTimedOut = "no reply before the read timeout"
  case writeTimedOut = "the peripheral took no write before the write timeout"
  case cancelled = "the request waiting on it was cancelled"
  case profileMismatch = "the GATT profile is not KM43's"
  case unavailable = "Bluetooth or the peripheral is unavailable"
  case peerDisconnected = "the link went down"
  case badFragment = "a fragment did not reassemble"
  case backlog = "too many unread messages"
  case sendRefused = "a frame could not be sent"
}

@MainActor public final class BluetoothTransport: PeerExcludingTransport {
  private let identifiers: BluetoothIdentifiers
  private let codec: any FragmentCodec
  private let driver: any BluetoothDriver
  private let timeout: Duration
  private var connected = false
  private var subscribing = false
  private var sending = false
  private var generation = 0
  private var messages: [Data] = []
  /// Peripherals Discover proved to be another controller in this attempt.
  private var excluded: Set<UUID> = []
  private var opening: CheckedContinuation<Void, any Error>?
  private var reading: CheckedContinuation<Data, any Error>?
  private var writing: CheckedContinuation<Void, any Error>?
  private var openTimer: Task<Void, Never>?
  private var readTimer: Task<Void, Never>?
  private var writeTimer: Task<Void, Never>?

  public convenience init(identifiers: BluetoothIdentifiers, codec: any FragmentCodec) {
    self.init(identifiers: identifiers, codec: codec, driver: CoreBluetoothDriver())
  }
  init(
    identifiers: BluetoothIdentifiers, codec: any FragmentCodec,
    driver: any BluetoothDriver, timeout: Duration = .seconds(15)
  ) {
    self.identifiers = identifiers
    self.codec = codec
    self.driver = driver
    self.timeout = timeout
    driver.event = { [weak self] event in self?.handle(event) }
  }
  public func open() async throws(TransportError) {
    guard !Task.isCancelled else { throw .dropped }
    if connected { return }
    guard opening == nil else { throw .unreachable }
    codec.reset()
    let operation = generation
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          opening = continuation
          openTimer = openTimeout()
          driver.start(identifiers: identifiers, excluding: excluded)
        }
      } onCancel: {
        Task { @MainActor in
          if self.generation == operation { self.terminate(.dropped, .cancelled) }
        }
      }
    } catch { throw (error as? TransportError) ?? .unreachable }
  }
  public func send(_ frame: Data) async throws(TransportError) {
    guard !Task.isCancelled, connected, !sending else { throw .dropped }
    sending = true
    let operation = generation
    defer { if generation == operation { sending = false } }
    do {
      let valueLimit = driver.maximumWriteLength
      let fragments = try codec.fragments(for: frame, valueLimit: valueLimit)
      for fragment in fragments {
        while !driver.canSend {
          guard connected, generation == operation else { throw TransportError.dropped }
          try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
              writing = continuation
              writeTimer = timer(error: .timedOut, .writeTimedOut)
            }
          } onCancel: {
            Task { @MainActor in
              if self.generation == operation { self.terminate(.dropped, .cancelled) }
            }
          }
        }
        guard connected, generation == operation,
          driver.maximumWriteLength >= valueLimit, fragment.count <= valueLimit,
          !Task.isCancelled
        else { throw TransportError.dropped }
        driver.write(fragment)
      }
    } catch {
      if generation == operation {
        terminate((error as? TransportError) ?? .dropped, .sendRefused)
      }
      throw (error as? TransportError) ?? .dropped
    }
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
  public func excludeConnectedPeer() async {
    if let peer = driver.peer { excluded.insert(peer) }
  }
  public func clearExcludedPeers() async { excluded.removeAll() }
  private func timer(error: TransportError, _ end: TransportEnd) -> Task<Void, Never> {
    Task { [weak self, timeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      // An event may have cancelled this timer after the sleep ended.
      guard !Task.isCancelled else { return }
      self?.terminate(error, end)
    }
  }
  /// Ends an open that has no subscribed peripheral in time: none found is
  /// `unreachable`, one found whose link never became ready is `notReady`.
  private func openTimeout() -> Task<Void, Never> {
    Task { [weak self, timeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard !Task.isCancelled, let self else { return }
      if driver.peer == nil {
        terminate(.unreachable, .openTimedOut)
      } else {
        terminate(.notReady, .notReady)
      }
    }
  }
  private func handle(_ event: BluetoothEvent) {
    switch event {
    case .profile(let profile):
      guard opening != nil, !subscribing else { return }
      guard profile.serviceCount == 1, profile.rxCount == 1, profile.txCount == 1,
        profile.rxWritesWithoutResponse, profile.txNotifies
      else {
        terminate(.unreachable, .profileMismatch)
        return
      }
      subscribing = true
      driver.subscribe()
    case .subscribed:
      guard opening != nil, subscribing else { return }
      connected = true
      subscribing = false
      openTimer?.cancel()
      openTimer = nil
      opening?.resume()
      opening = nil
    case .value(let value):
      guard connected else { return }
      do {
        let now = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        if let message = try codec.receive(fragment: value, nowMs: now) {
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
        }
      } catch { terminate(.dropped, .badFragment) }
    case .writable:
      guard connected, driver.canSend else { return }
      writeTimer?.cancel()
      writeTimer = nil
      writing?.resume()
      writing = nil
    case .unavailable: terminate(.unreachable, .unavailable)
    case .disconnected: terminate(opening == nil ? .dropped : .unreachable, .peerDisconnected)
    }
  }
  private func terminate(_ error: TransportError, _ end: TransportEnd) {
    if connected || opening != nil {
      let phase = connected ? "connection" : "open"
      if end == .closedByFlow {
        SetupLog.bluetooth.info(
          "\(phase, privacy: .public) ended: \(end.rawValue, privacy: .public)")
      } else {
        SetupLog.bluetooth.error(
          "\(phase, privacy: .public) ended: \(end.rawValue, privacy: .public)")
      }
    }
    generation += 1
    connected = false
    subscribing = false
    sending = false
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
    codec.reset()
    driver.disconnect()
  }
}
