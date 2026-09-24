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
///
/// A `Pair` that succeeds leaves its enrolment in the store, and a later
/// launch that scans the same controller's code greets it with `Hello` and no
/// pairing window (P-222). When the kept enrolment is for another epoch or the
/// controller refuses it, the flow pairs with the scanned code, and the new
/// enrolment replaces the old one.
///
/// On a controller that reports Wi-Fi (P-216) the flow also reads what its
/// radio hears while the network is edited, and watches the join after a
/// write. Both run in one background task that every other step stops and
/// awaits first, so two requests never share the connection.
@MainActor @Observable public final class SetupFlow {
  /// After a write, what the radio did with it.
  public enum JoinWatch: Sendable, Equatable {
    case idle, waiting
    case joined(address: String)
    case failed(JoinFailure)
    /// The radio gave no verdict on this write in time.
    case noAnswer
  }
  /// A running scan is read again this often, and given up after `scanLimit`.
  static let pollInterval: Duration = .seconds(2)
  static let scanLimit: Duration = .seconds(20)
  /// How long a write's join is watched.
  static let joinLimit: Duration = .seconds(60)

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
  /// Whether the controller answers Wi-Fi scan and status reads (P-216).
  public private(set) var reportsWiFi = false
  /// The latest scan answer this session read.
  public private(set) var scan: NetworkScan?
  public private(set) var isScanning = false
  public private(set) var join: JoinWatch = .idle
  /// A kept enrolment could not be used, so this phone pairs again.
  public private(set) var keptEnrolmentLost = false
  /// The network version this session wrote, kept across Time failures.
  public var writtenVersion: UInt32? {
    if case .written(let version) = resume { version } else { nil }
  }
  private let factory: any ControllerClientFactory
  private let store: any EnrolmentStore
  private let transportFactory: @MainActor @Sendable () -> any FrameTransport
  private let clock: any SetupClock
  private var transport: (any FrameTransport)?
  private var client: (any ControllerClient)?
  /// True from the moment `open()` is called until the one `close()` for it.
  private var transportActive = false
  private var resume: Resume = .pair
  /// Set by a new code: the next connect first looks for a kept enrolment.
  private var restorePending = false
  private var generation = 0
  private var isConnecting = false
  private var deadlineTask: Task<Void, Never>?
  /// The scan or join watch in flight, the only request not awaited in line.
  private var backgroundTask: Task<Void, Never>?

  public init(
    factory: any ControllerClientFactory,
    store: any EnrolmentStore,
    transportFactory: @escaping @MainActor @Sendable () -> any FrameTransport,
    clock: any SetupClock = SystemSetupClock()
  ) {
    self.factory = factory
    self.store = store
    self.transportFactory = transportFactory
    self.clock = clock
  }

  public func submitCode(_ code: String) throws(SetupCodeError) {
    guard state == .enterCode else { return }
    let transport = transportFactory()
    client = try factory.client(setupCode: code, transport: transport)
    self.transport = transport
    resume = .pair
    restorePending = true
    state = .connecting
  }

  /// Open the connection. Before enrolment the next step is the pairing
  /// window; after it, or with a kept enrolment, a new session resumes where
  /// the last one stopped. Every connect starts with no excluded peers.
  public func connect() async {
    guard state == .connecting, !isConnecting, let transport, let client else { return }
    isConnecting = true
    let operation = generation
    defer { if generation == operation { isConnecting = false } }
    if restorePending {
      restorePending = false
      await client.restore(from: store)
      guard generation == operation else { return }
    }
    let greets = await client.isEnrolled()
    guard generation == operation else { return }
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
    if resume == .pair, !greets {
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
      await keep(client)
      guard generation == operation else { return }
      guard clock.now < deadline else {
        state = .failed(.windowClosed, .openWindow)
        await close()
        return
      }
      deadlineTask?.cancel()
      resume = .readNetwork
      state = .greeting
      let report = try await client.hello()
      guard generation == operation else { return }
      reportsWiFi = report.reportsWiFi
      await readNetwork()
    } catch {
      guard generation == operation else { return }
      deadlineTask?.cancel()
      await fail(error)
    }
  }

  /// Keep the enrolment `Pair` just produced, replacing any older one.
  private func keep(_ client: any ControllerClient) async {
    // A phone that cannot keep it still finishes setup, and pairs again on
    // its next launch.
    try? await client.keep(in: store)
  }

  /// Discover and Hello on a new connection with the retained or kept
  /// enrolment, then continue from `resume`.
  private func openSession(_ operation: Int) async {
    guard let client else { return }
    do {
      state = .discovering
      let discovered = try await discover(client, operation)
      guard generation == operation else { return }
      controller = discovered
      // A kept enrolment for another epoch (P-222): pair on this connection.
      guard await client.isEnrolled() else {
        guard generation == operation else { return }
        keptEnrolmentLost = true
        state = .openWindow
        return
      }
      guard generation == operation else { return }
      state = .greeting
      let report = try await client.hello()
      guard generation == operation else { return }
      reportsWiFi = report.reportsWiFi
    } catch {
      guard generation == operation else { return }
      await fail(error)
      return
    }
    switch resume {
    // A kept enrolment's first session goes on to the network, as Pair does.
    case .pair, .readNetwork:
      resume = .readNetwork
      await readNetwork()
    case .written(let version):
      state = .written(version)
      if join == .waiting { watchJoin(version) }
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
    await stopBackground()
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
      // A cleared network has nothing to join.
      if reportsWiFi, change.ssid != nil { watchJoin(version) }
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }
  /// The optional signed Time. Success finishes setup and closes the
  /// connection. A refusal keeps the session for another try; a lost
  /// connection, a timeout or a bad reply ends it, and retry reconnects.
  public func setTime(_ date: Date = Date()) async {
    await stopBackground()
    guard case .written(let version) = state, let client else { return }
    if !transportActive {
      state = .connecting
      await connect()
      guard state == .written(version), transportActive else { return }
      // The reconnect may have resumed the join watch; it goes before Time.
      await stopBackground()
      guard state == .written(version) else { return }
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
  /// Ask the controller what its radio hears. A refresh starts a scan unless
  /// the controller refuses (P-218); while it runs the list is read again
  /// every `pollInterval`, up to `scanLimit`. Only while the network is
  /// edited, on a controller that reports Wi-Fi.
  public func scanNetworks(refresh: Bool = true) {
    guard case .editingNetwork = state, reportsWiFi, backgroundTask == nil, let client else {
      return
    }
    let operation = generation
    isScanning = true
    backgroundTask = Task { [weak self] in
      await self?.runScan(client, refresh: refresh, operation)
    }
  }

  private func runScan(_ client: any ControllerClient, refresh: Bool, _ operation: Int) async {
    defer {
      if generation == operation {
        isScanning = false
        backgroundTask = nil
      }
    }
    var refresh = refresh
    let deadline = clock.now + Self.scanLimit
    do {
      while true {
        let answer = try await client.scanWiFi(refresh: refresh)
        guard generation == operation else { return }
        scan = answer
        guard answer.progress == .running, !Task.isCancelled, clock.now < deadline else { return }
        refresh = false
        do { try await clock.sleep(until: clock.now + Self.pollInterval) } catch { return }
        guard !Task.isCancelled, generation == operation else { return }
      }
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }

  /// Read the radio's status every `pollInterval` until it has a verdict on
  /// `version` or `joinLimit` passes.
  private func watchJoin(_ version: UInt32) {
    guard reportsWiFi, backgroundTask == nil, let client else { return }
    let operation = generation
    join = .waiting
    backgroundTask = Task { [weak self] in
      await self?.runWatch(client, version, operation)
    }
  }

  private func runWatch(_ client: any ControllerClient, _ version: UInt32, _ operation: Int) async {
    defer { if generation == operation { backgroundTask = nil } }
    let deadline = clock.now + Self.joinLimit
    do {
      while true {
        let status = try await client.wifiStatus()
        guard generation == operation else { return }
        switch status.state(for: version) {
        case .joined(let address):
          join = .joined(address: address)
          return
        case .failed(let reason):
          join = .failed(reason)
          return
        // Off, joining, or a report on another version: no verdict yet.
        case .off, .joining, nil: break
        }
        guard !Task.isCancelled else { return }
        guard clock.now < deadline else {
          join = .noAnswer
          return
        }
        do { try await clock.sleep(until: clock.now + Self.pollInterval) } catch { return }
        guard !Task.isCancelled, generation == operation else { return }
      }
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }

  /// Watch the join of the written network again, reconnecting if needed.
  public func watchJoinAgain() async {
    guard case .written(let version) = state, reportsWiFi else { return }
    if !transportActive {
      join = .waiting
      state = .connecting
      await connect()
      return
    }
    watchJoin(version)
  }

  /// Leave a written network to choose another: read the section again,
  /// reconnecting if needed.
  public func changeNetwork() async {
    guard case .written = state else { return }
    await stopBackground()
    guard case .written = state else { return }
    join = .idle
    resume = .readNetwork
    if transportActive {
      await readNetwork()
    } else {
      state = .connecting
      await connect()
    }
  }

  /// Stop the scan or join watch and wait for its request to finish.
  private func stopBackground() async {
    guard let task = backgroundTask else { return }
    task.cancel()
    await task.value
    backgroundTask = nil
    isScanning = false
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
    reportsWiFi = false
    scan = nil
    join = .idle
    resume = .pair
    restorePending = false
    keptEnrolmentLost = false
    state = .enterCode
  }

  /// End whatever is in flight and close the connection once.
  private func close() async {
    generation += 1
    deadlineTask?.cancel()
    backgroundTask?.cancel()
    backgroundTask = nil
    isScanning = false
    if join == .waiting { join = .idle }
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
    case .enrolmentRefused:
      keptEnrolmentLost = true
      target = .openWindow
    case .controllerReset: target = .enterCode
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
    case .windowClosed, .tableFull, .enrolmentRefused: .openWindow
    case .controllerReset: .enterCode
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
