import Foundation
import Observation

@MainActor public protocol SetupClock {
  var now: Duration { get }
  func sleep(until deadline: Duration) async throws
}
@MainActor public struct SystemSetupClock: SetupClock {
  private let clock = ContinuousClock()
  private let origin = ContinuousClock.now
  public init() {}
  public var now: Duration { origin.duration(to: clock.now) }
  public func sleep(until deadline: Duration) async throws {
    try await clock.sleep(until: origin.advanced(by: deadline))
  }
}

/// The setup flow over one controller.
///
/// A controller accepts at most two connections, so the flow owns the
/// transport and holds it only while a step needs it: every path that ends
/// or pauses setup closes it, and a reconnect closes the previous connection
/// before opening the next. When Discover finds another controller, a
/// transport that can exclude peers skips it and connects again. Once
/// enrolled, a reconnect runs Discover and Hello again with the enrolment the
/// client keeps; it never pairs twice.
@MainActor @Observable public final class SetupFlow {
  public enum RetryTarget: Sendable, Equatable {
    case enterCode, connecting, openWindow, readingNetwork, editingNetwork
    case written(UInt32)
  }
  public enum State: Sendable, Equatable {
    case enterCode, connecting, openWindow, discovering, pairing, greeting, readingNetwork
    case editingNetwork(NetworkSettings)
    case writingNetwork
    case written(UInt32)
    case settingTime
    /// Setup is over and the connection is closed. `timeSet` says whether the
    /// optional clock write landed.
    case finished(version: UInt32, timeSet: Bool)
    case failed(SetupFailure, RetryTarget)
  }
  /// Where a new session continues after a reconnect.
  private enum Resume: Equatable {
    case pair, readNetwork
    case written(UInt32)
  }
  public private(set) var state: State = .enterCode
  public private(set) var controller: ControllerSummary?
  public private(set) var network: NetworkSettings?
  /// The network version this session wrote, kept across Time failures.
  public var writtenVersion: UInt32? {
    if case .written(let version) = resume { version } else { nil }
  }
  private let factory: any ControllerClientFactory
  private let transportFactory: @MainActor @Sendable () -> any FrameTransport
  private let clock: any SetupClock
  private var transport: (any FrameTransport)?
  private var client: (any ControllerClient)?
  /// True from the moment `open()` is called until the one `close()` for it.
  private var transportActive = false
  private var resume: Resume = .pair
  private var generation = 0
  private var isConnecting = false
  private var deadlineTask: Task<Void, Never>?

  public init(
    factory: any ControllerClientFactory,
    transportFactory: @escaping @MainActor @Sendable () -> any FrameTransport,
    clock: any SetupClock = SystemSetupClock()
  ) {
    self.factory = factory
    self.transportFactory = transportFactory
    self.clock = clock
  }

  public func submitCode(_ code: String) throws(SetupCodeError) {
    guard state == .enterCode else { return }
    let transport = transportFactory()
    client = try factory.client(setupCode: code, transport: transport)
    self.transport = transport
    resume = .pair
    state = .connecting
  }

  /// Open the connection. Before enrolment the next step is the pairing
  /// window; after it, a new session resumes where the last one stopped.
  /// Every connect starts with no excluded peers.
  public func connect() async {
    guard state == .connecting, !isConnecting, let transport else { return }
    isConnecting = true
    let operation = generation
    defer { if generation == operation { isConnecting = false } }
    await closeTransport()
    await (transport as? any PeerExcludingTransport)?.clearExcludedPeers()
    transportActive = true
    do {
      try await transport.open()
    } catch {
      // A failed open leaves nothing connected.
      if generation == operation { transportActive = false }
      guard generation == operation else { return }
      await fail(Self.failure(error))
      return
    }
    guard generation == operation else {
      await closeTransport()
      return
    }
    if resume == .pair {
      state = .openWindow
    } else {
      isConnecting = false
      await openSession(operation)
    }
  }

  public func confirmWindowOpened() async {
    guard state == .openWindow, let client else { return }
    generation += 1
    let operation = generation
    let deadline = clock.now + .seconds(120)
    deadlineTask = Task { [weak self, clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      guard !Task.isCancelled, let self, self.generation == operation else { return }
      self.state = .failed(.windowClosed, .openWindow)
      await self.close()
    }
    do {
      state = .discovering
      let discovered = try await discover(client, operation)
      guard generation == operation else { return }
      controller = discovered
      state = .pairing
      try await client.pair()
      guard generation == operation else { return }
      guard clock.now < deadline else {
        state = .failed(.windowClosed, .openWindow)
        await close()
        return
      }
      deadlineTask?.cancel()
      resume = .readNetwork
      state = .greeting
      try await client.hello()
      guard generation == operation else { return }
      await readNetwork()
    } catch {
      guard generation == operation else { return }
      deadlineTask?.cancel()
      await fail(error)
    }
  }

  /// Discover and Hello on a new connection with the retained enrolment,
  /// then continue from `resume`.
  private func openSession(_ operation: Int) async {
    guard let client else { return }
    do {
      state = .discovering
      let discovered = try await discover(client, operation)
      guard generation == operation else { return }
      controller = discovered
      state = .greeting
      try await client.hello()
      guard generation == operation else { return }
    } catch {
      guard generation == operation else { return }
      await fail(error)
      return
    }
    switch resume {
    case .pair: state = .openWindow
    case .readNetwork: await readNetwork()
    case .written(let version): state = .written(version)
    }
  }

  /// Discover on the open connection. The advertisement does not identify
  /// the controller, so when another one answers, an excluding transport
  /// skips it and connects again, one connection at a time. The open
  /// timeout bounds the search: no other peer ends it as a mismatch.
  private func discover(_ client: any ControllerClient, _ operation: Int) async throws(SetupFailure)
    -> ControllerSummary
  {
    while true {
      do {
        return try await client.discover()
      } catch {
        guard error == .controllerMismatch, generation == operation,
          let transport = transport as? any PeerExcludingTransport
        else { throw error }
        await transport.excludeConnectedPeer()
        await client.close()
        await closeTransport()
        guard generation == operation else { throw error }
        // The state stays on discovering, so the window countdown keeps running.
        isConnecting = true
        transportActive = true
        do {
          try await transport.open()
        } catch {
          guard generation == operation else { throw .connectionDropped }
          isConnecting = false
          transportActive = false
          throw error == .unreachable ? .controllerMismatch : Self.failure(error)
        }
        guard generation == operation else {
          await closeTransport()
          throw .connectionDropped
        }
        isConnecting = false
      }
    }
  }

  private func readNetwork() async {
    guard let client else { return }
    let operation = generation
    state = .readingNetwork
    do {
      let settings = try await client.readNetwork()
      guard generation == operation else { return }
      network = settings
      state = .editingNetwork(settings)
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }
  public func writeNetwork(_ change: NetworkChange) async {
    guard case .editingNetwork(let settings) = state, let client else { return }
    guard change.isValid(comparedTo: settings) else {
      state = .failed(.invalidConfig, .editingNetwork)
      return
    }
    let operation = generation
    state = .writingNetwork
    do {
      let version = try await client.writeNetwork(change, expectedVersion: settings.version)
      guard generation == operation else { return }
      resume = .written(version)
      state = .written(version)
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }
  /// The optional signed Time. Success finishes setup and closes the
  /// connection. A refusal keeps the session for another try; a lost
  /// connection, a timeout or a bad reply ends it, and retry reconnects.
  public func setTime(_ date: Date = Date()) async {
    guard case .written(let version) = state, let client else { return }
    if !transportActive {
      state = .connecting
      await connect()
      guard state == .written(version), transportActive else { return }
    }
    let operation = generation
    state = .settingTime
    do {
      try await client.setTime(date)
      guard generation == operation else { return }
      await close()
      state = .finished(version: version, timeSet: true)
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }
  /// The person is done: close the connection and finish.
  public func finish() async {
    guard let version = writtenVersion else { return }
    switch state {
    case .written, .failed:
      await close()
      state = .finished(version: version, timeSet: false)
    default: return
    }
  }
  /// The app left the foreground: give the connection back. A written
  /// network stays written; anything in progress resumes through retry.
  public func suspend() async {
    guard transportActive else { return }
    await close()
    switch state {
    case .written, .settingTime:
      if let version = writtenVersion { state = .written(version) }
    case .enterCode, .finished, .failed(_, .enterCode):
      break
    case .failed(let failure, _):
      state = .failed(failure, target(forLost: failure))
    default:
      state = .failed(.connectionDropped, .connecting)
    }
  }
  public func retry() async {
    guard case .failed(_, let target) = state else { return }
    switch target {
    case .enterCode: state = .enterCode
    case .connecting, .openWindow:
      state = .connecting
      await connect()
    case .readingNetwork: await readNetwork()
    case .written(let version): state = .written(version)
    case .editingNetwork:
      if let network { state = .editingNetwork(network) }
    }
  }
  public func reset() async {
    await close()
    transport = nil
    isConnecting = false
    client = nil
    controller = nil
    network = nil
    resume = .pair
    state = .enterCode
  }

  /// End whatever is in flight and close the connection once.
  private func close() async {
    generation += 1
    deadlineTask?.cancel()
    isConnecting = false
    await client?.close()
    await closeTransport()
  }
  private func closeTransport() async {
    guard transportActive, let transport else { return }
    transportActive = false
    await transport.close()
  }

  private func fail(_ failure: SetupFailure) async {
    let target: RetryTarget
    var keepConnection = false
    switch failure {
    case .timeRejected, .timeNeedsButton:
      target = writtenVersion.map(RetryTarget.written) ?? .connecting
      keepConnection = writtenVersion != nil
    case .wrongProof: target = .enterCode
    case .controllerMismatch:
      // Retrying connects again with no excluded peers.
      target = transport is any PeerExcludingTransport ? .connecting : .enterCode
    case .windowClosed, .tableFull: target = .openWindow
    case .staleVersion:
      target = .readingNetwork
      keepConnection = true
    case .invalidConfig:
      target = network == nil ? .openWindow : .editingNetwork
      keepConnection = network != nil
    case .bluetoothUnavailable, .connectionDropped, .timedOut, .protocolError:
      target = .connecting
    }
    if !keepConnection { await close() }
    state = .failed(failure, target)
    if target == .enterCode { client = nil }
  }
  /// The retry target once a failure's connection is gone.
  private func target(forLost failure: SetupFailure) -> RetryTarget {
    switch failure {
    case .windowClosed, .tableFull: .openWindow
    default: .connecting
    }
  }
  private static func failure(_ error: TransportError) -> SetupFailure {
    switch error {
    case .unreachable: .bluetoothUnavailable
    case .dropped: .connectionDropped
    case .timedOut: .timedOut
    }
  }
}
