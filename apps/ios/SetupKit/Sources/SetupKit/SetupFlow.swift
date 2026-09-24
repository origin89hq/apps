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
/// A launch after an enrolment reconnects to that controller with Discover and
/// Hello and reads its network, whether or not a network was written, until
/// the person starts over or the kept enrolment stops working.
///
/// On a controller that reports Wi-Fi (P-216) the flow also reads what its
/// radio hears while the network is edited, and watches the join after a
/// write. Both run in one background task that every other step stops and
/// awaits first, so two requests never share the connection. Once the write
/// is accepted, a join watch that loses the connection leaves setup written
/// with no verdict; it never fails the flow.
///
/// When the join reports an address, the flow moves the session to Wi-Fi:
/// it opens a WebSocket there with the kept enrolment, runs Discover and
/// Hello, and only then closes Bluetooth, so the session is never without a
/// link. The address is kept per controller, and a later connect tries it
/// before Bluetooth. Discover decides each time whether it is still this
/// controller (P-225). When Wi-Fi cannot be used the session stays on, or
/// falls back to, Bluetooth, and `wifiUnavailable` says why.
@MainActor @Observable public final class SetupFlow {
  /// After a write, what the radio did with it.
  public enum JoinWatch: Sendable, Equatable {
    case idle, waiting
    case joined(address: String)
    case failed(JoinFailure)
    /// The radio gave no verdict on this write in time.
    case noAnswer
    /// The connection ended before a verdict. The write stands; the controller
    /// may drop Bluetooth while its radio joins.
    case connectionLost
  }
  /// A running scan is read again this often, and given up after `scanLimit`.
  static let pollInterval: Duration = .seconds(2)
  static let scanLimit: Duration = .seconds(20)
  /// How long a write's join is watched.
  static let joinLimit: Duration = .seconds(60)

  /// The link a session runs over.
  public enum Link: Sendable, Equatable {
    case bluetooth
    case wifi(address: String)
  }
  /// Why the session stayed on or fell back to Bluetooth after trying Wi-Fi.
  public enum WiFiUnavailable: Sendable, Equatable {
    /// No connection, or it dropped before Hello: typically the phone is on
    /// another network or on cellular.
    case notReachable
    case localNetworkDenied
    /// Another controller answered at the address; it is forgotten.
    case otherController
    /// The controller answered but the session failed there.
    case refused

    public var message: String {
      switch self {
      case .notReachable:
        "This phone could not reach the controller over Wi-Fi, so it stays on Bluetooth. The phone must be on the same network as the controller."
      case .localNetworkDenied:
        "Origin89 is not allowed to use the local network, so it stays on Bluetooth. Turn on Local Network for Origin89 in Settings, then try again."
      case .otherController:
        "Another controller answered at this controller's address, so the phone stays on Bluetooth."
      case .refused:
        "The controller did not accept this phone over Wi-Fi, so it stays on Bluetooth."
      }
    }
  }
  /// A WebSocket session: its own transport and client, with the enrolment
  /// the store keeps.
  private struct WiFiLink: Sendable {
    var address: String
    var transport: any FrameTransport
    var client: any ControllerClient
  }
  /// A WebSocket session that answered Discover and Hello.
  private struct WiFiSession: Sendable {
    var link: WiFiLink
    var found: ControllerSummary
    var report: SessionReport
  }

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
  public private(set) var state: State = .enterCode {
    didSet {
      guard state != oldValue else { return }
      SetupLog.flow.info(
        "\(oldValue.logLabel, privacy: .public) -> \(self.state.logLabel, privacy: .public)")
    }
  }
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
  /// This launch reconnected to the last controller from the kept enrolment,
  /// without the setup code.
  public private(set) var resumed = false
  /// Why Wi-Fi was not used, from the last attempt; nil once it works.
  public private(set) var wifiUnavailable: WiFiUnavailable?
  /// A WebSocket session is being opened.
  public private(set) var isSwitchingToWiFi = false
  /// The link the open session runs over; nil when none is open.
  public var link: Link? {
    guard transportActive else { return nil }
    if let wifi { return .wifi(address: wifi.address) }
    return .bluetooth
  }
  /// The network version this session wrote, kept across Time failures.
  public var writtenVersion: UInt32? {
    if case .written(let version) = resume { version } else { nil }
  }
  private let factory: any ControllerClientFactory
  private let store: any EnrolmentStore
  private let lastController: (any LastControllerStore)?
  private let transportFactory: @MainActor @Sendable () -> any FrameTransport
  /// A WebSocket transport for an address, nil for one it cannot reach.
  private let webSocketFactory: (@MainActor @Sendable (String) -> (any FrameTransport)?)?
  private let addresses: (any ControllerAddressStore)?
  private let clock: any SetupClock
  /// The Bluetooth transport and the client over it. Pairing always runs here.
  private var transport: (any FrameTransport)?
  private var client: (any ControllerClient)?
  /// Set while the session runs over Wi-Fi instead.
  private var wifi: WiFiLink?
  /// The controller a relaunch reconnects to, before Discover names it.
  private var lastDeviceID: String?
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
    clock: any SetupClock = SystemSetupClock(),
    lastController: (any LastControllerStore)? = nil,
    webSocketFactory: (@MainActor @Sendable (String) -> (any FrameTransport)?)? = nil,
    addresses: (any ControllerAddressStore)? = nil
  ) {
    self.factory = factory
    self.store = store
    self.transportFactory = transportFactory
    self.webSocketFactory = webSocketFactory
    self.addresses = addresses
    self.clock = clock
    self.lastController = lastController
    reconnectToLastController()
  }

  /// Reconnect to the controller an earlier launch enrolled with: with its
  /// kept enrolment the flow waits in `connecting`, and `connect()` goes to
  /// the network. Without one the setup code is needed, so nothing is kept.
  private func reconnectToLastController() {
    guard let lastController, let deviceID = lastController.load() else { return }
    let transport = transportFactory()
    guard let client = factory.client(resuming: deviceID, from: store, transport: transport) else {
      SetupLog.flow.notice("the last controller has no kept enrolment: the code is needed")
      lastController.save(nil)
      return
    }
    SetupLog.flow.info("reconnecting to the last controller from its kept enrolment")
    self.transport = transport
    self.client = client
    lastDeviceID = deviceID
    resume = .readNetwork
    resumed = true
    state = .connecting
  }

  /// Enrolled with the controller: a relaunch reconnects to it.
  private func rememberController() {
    guard let deviceID = controller?.deviceID else { return }
    lastController?.save(deviceID)
  }

  /// A code is a person choosing its controller: nothing from an earlier
  /// controller carries over, and a kept enrolment is used only when it is
  /// for the controller the code names (P-222).
  public func submitCode(_ code: String) throws(SetupCodeError) {
    guard state == .enterCode else { return }
    let transport = transportFactory()
    client = try factory.client(setupCode: code, transport: transport)
    self.transport = transport
    forgetController()
    resumed = false
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
    SetupLog.flow.info(
      "connecting: enrolled \(greets, privacy: .public), resume \(String(describing: self.resume), privacy: .public)"
    )
    await closeTransport()
    await (transport as? any PeerExcludingTransport)?.clearExcludedPeers()
    if greets, let deviceID = controller?.deviceID ?? lastDeviceID,
      let address = candidateAddress(for: deviceID)
    {
      // Active from here, so a suspend during the attempt ends it.
      transportActive = true
      let opened = await openWiFi(to: address, deviceID: deviceID, operation)
      guard generation == operation else {
        if let opened { await Self.close(opened.link) }
        return
      }
      if let opened {
        wifi = opened.link
        isConnecting = false
        controller = opened.found
        await proceed(opened.report, operation)
        return
      }
      transportActive = false
      SetupLog.flow.notice("Wi-Fi is unavailable: connecting over Bluetooth")
    }
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
      rememberController()
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
        SetupLog.flow.notice("the kept enrolment is for another epoch: pairing again")
        keptEnrolmentLost = true
        state = .openWindow
        return
      }
      guard generation == operation else { return }
      state = .greeting
      let report = try await client.hello()
      guard generation == operation else { return }
      await proceed(report, operation)
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }

  /// Continue from `resume` after a Hello on a new connection.
  private func proceed(_ report: SessionReport, _ operation: Int) async {
    reportsWiFi = report.reportsWiFi
    switch resume {
    // A kept enrolment's first session goes on to the network, as Pair does.
    case .pair, .readNetwork:
      rememberController()
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
        SetupLog.flow.notice(
          "another controller answered Discover: skipping it and connecting again")
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
    guard let client = session else { return }
    let operation = generation
    state = .readingNetwork
    do {
      let settings = try await client.readNetwork()
      guard generation == operation else { return }
      SetupLog.flow.info(
        "network section version \(settings.version, privacy: .public), network held \(settings.ssid != nil, privacy: .public), country held \(settings.country != nil, privacy: .public)"
      )
      network = settings
      state = .editingNetwork(settings)
    } catch {
      guard generation == operation else { return }
      await fail(error)
    }
  }
  public func writeNetwork(_ change: NetworkChange) async {
    await stopBackground()
    guard case .editingNetwork(let settings) = state, let client = session else { return }
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
    guard case .written(let version) = state else { return }
    if !transportActive {
      state = .connecting
      await connect()
      guard state == .written(version), transportActive else { return }
      // The reconnect may have resumed the join watch; it goes before Time.
      await stopBackground()
      guard state == .written(version) else { return }
    }
    // The reconnect or a switch to Wi-Fi may have changed the session.
    guard let client = session else { return }
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
    guard case .editingNetwork = state, reportsWiFi, backgroundTask == nil, let client = session
    else {
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
        let answer = try await Self.uninterrupted { [refresh] () async throws(SetupFailure) in
          try await client.scanWiFi(refresh: refresh)
        }
        guard generation == operation else { return }
        SetupLog.flow.info(
          "scan \(String(describing: answer.progress), privacy: .public), refused \(String(describing: answer.refused), privacy: .public), \(answer.networks?.count ?? 0, privacy: .public) networks listed"
        )
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
    guard reportsWiFi, backgroundTask == nil, let client = session else { return }
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
        let status = try await Self.uninterrupted { () async throws(SetupFailure) in
          try await client.wifiStatus()
        }
        guard generation == operation else { return }
        SetupLog.flow.info(
          "Wi-Fi status: section \(status.section, privacy: .public), radio on version \(status.radio.map { String($0.version) } ?? "none", privacy: .public)"
        )
        switch status.state(for: version) {
        case .joined(let address):
          join = .joined(address: address)
          if let deviceID = controller?.deviceID {
            addresses?.save(address, deviceID: deviceID)
          }
          await switchToWiFi(address, operation)
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
      SetupLog.flow.notice(
        "the join watch stopped: \(String(describing: error), privacy: .public); version \(version, privacy: .public) stays written"
      )
      // Before closing, so the watch never reads as idle in between.
      join = .connectionLost
      await close()
    }
  }

  /// Watch the join of the written network again, reconnecting if needed. A
  /// reconnect that fails in a way a retry would reconnect from returns to
  /// the written network with no verdict.
  public func watchJoinAgain() async {
    guard case .written(let version) = state, reportsWiFi else { return }
    if !transportActive {
      join = .waiting
      state = .connecting
      await connect()
      if case .failed(_, .connecting) = state, writtenVersion == version {
        state = .written(version)
        join = .connectionLost
      }
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

  /// Try Wi-Fi again after it was unavailable, while Bluetooth holds the
  /// session.
  public func retryWiFi() async {
    switch state {
    case .editingNetwork, .written: break
    default: return
    }
    guard wifiUnavailable != nil, wifi == nil, transportActive else { return }
    await stopBackground()
    guard wifi == nil, transportActive, backgroundTask == nil,
      let deviceID = controller?.deviceID, let address = candidateAddress(for: deviceID)
    else { return }
    let operation = generation
    let task = Task { [weak self] in
      await self?.switchToWiFi(address, operation)
      if self?.generation == operation { self?.backgroundTask = nil }
    }
    backgroundTask = task
    await task.value
  }

  /// Move the open Bluetooth session to Wi-Fi at `address`. The WebSocket
  /// opens while Bluetooth still holds; the controller takes two connections,
  /// so both fit for the moment of the switch. Only then does Bluetooth close.
  /// Runs as the background task, to its end even when stopped, so the next
  /// step waits and then has one link.
  private func switchToWiFi(_ address: String, _ operation: Int) async {
    guard wifi == nil, transportActive, let deviceID = controller?.deviceID else { return }
    // Its own task, so stopping the background task does not cut it short.
    let opened = await Task { [weak self] in
      await self?.openWiFi(to: address, deviceID: deviceID, operation)
    }.value
    guard let opened else {
      SetupLog.flow.notice("staying on Bluetooth")
      return
    }
    guard generation == operation, transportActive, wifi == nil else {
      await Self.close(opened.link)
      return
    }
    let bluetoothClient = client
    let bluetoothTransport = transport
    wifi = opened.link
    reportsWiFi = opened.report.reportsWiFi
    SetupLog.flow.info("the session moved to Wi-Fi: closing Bluetooth")
    await bluetoothClient?.close()
    await bluetoothTransport?.close()
  }

  /// Open a WebSocket to `address` and run Discover and Hello there with the
  /// enrolment the store keeps. Nil when that fails, with the reason in
  /// `wifiUnavailable` and the WebSocket closed; Bluetooth is left alone.
  private func openWiFi(to address: String, deviceID: String, _ operation: Int) async
    -> WiFiSession?
  {
    guard let transport = webSocketFactory?(address) else { return nil }
    guard let client = factory.client(resuming: deviceID, from: store, transport: transport) else {
      SetupLog.flow.notice("no kept enrolment to use over Wi-Fi")
      return nil
    }
    SetupLog.flow.info("opening a session over Wi-Fi")
    isSwitchingToWiFi = true
    defer { isSwitchingToWiFi = false }
    do {
      try await transport.open()
    } catch {
      if generation == operation { wifiUnavailable = Self.unavailable(error) }
      return nil
    }
    do throws(SetupFailure) {
      guard generation == operation else { throw .connectionDropped }
      let found = try await client.discover()
      // Kept for another epoch: Bluetooth pairs again or asks for the code.
      guard await client.isEnrolled() else { throw .controllerReset }
      let report = try await client.hello()
      guard generation == operation else { throw .connectionDropped }
      wifiUnavailable = nil
      return WiFiSession(
        link: WiFiLink(address: address, transport: transport, client: client), found: found,
        report: report)
    } catch {
      await client.close()
      await transport.close()
      guard generation == operation else { return nil }
      SetupLog.flow.notice(
        "the Wi-Fi session failed: \(String(describing: error), privacy: .public)")
      if error == .controllerMismatch { addresses?.save(nil, deviceID: deviceID) }
      wifiUnavailable = Self.unavailable(error)
      return nil
    }
  }

  /// Where to try Wi-Fi: the address the join just reported, or the one kept.
  private func candidateAddress(for deviceID: String) -> String? {
    guard webSocketFactory != nil else { return nil }
    if case .joined(let address) = join { return address }
    return addresses?.load(deviceID: deviceID)
  }

  /// The client of the open session: over Wi-Fi when switched, else Bluetooth.
  private var session: (any ControllerClient)? { wifi?.client ?? client }

  private static func close(_ link: WiFiLink) async {
    await link.client.close()
    await link.transport.close()
  }

  /// A scan or status read run to its answer even when the background task
  /// is cancelled. The transport ends the connection when a read is
  /// cancelled, so a stop waits for the request in flight and the loop ends
  /// after it; the next step then has the connection to itself.
  private static func uninterrupted<Value: Sendable>(
    _ request: @escaping @Sendable () async throws(SetupFailure) -> Value
  ) async throws(SetupFailure) -> Value {
    let result = await Task { () async -> Result<Value, SetupFailure> in
      do throws(SetupFailure) {
        return .success(try await request())
      } catch {
        return .failure(error)
      }
    }.value
    return try result.get()
  }

  /// Stop the scan or join watch and wait for its request to finish.
  private func stopBackground() async {
    guard let task = backgroundTask else { return }
    SetupLog.flow.debug("stopping the Wi-Fi scan or join watch after its request in flight")
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
    SetupLog.flow.notice("the app left the foreground: closing the connection")
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
    SetupLog.flow.info("retrying from \(String(describing: target), privacy: .public)")
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
    forgetController()
    resume = .pair
    restorePending = false
    resumed = false
    lastController?.save(nil)
    state = .enterCode
  }

  /// Drop what this flow learned about the controller it last reached.
  private func forgetController() {
    controller = nil
    lastDeviceID = nil
    network = nil
    reportsWiFi = false
    scan = nil
    join = .idle
    keptEnrolmentLost = false
    wifiUnavailable = nil
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
    await session?.close()
    await closeTransport()
  }
  /// Close the open link. A Wi-Fi session ends here; the next connect tries
  /// Wi-Fi again, then Bluetooth.
  private func closeTransport() async {
    guard transportActive else { return }
    transportActive = false
    if let wifi {
      self.wifi = nil
      await Self.close(wifi)
    } else {
      await transport?.close()
    }
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
      // A resumed session has no setup code to pair again with.
      target = resumed ? .enterCode : .openWindow
    case .controllerReset: target = .enterCode
    case .windowClosed, .tableFull: target = .openWindow
    case .staleVersion:
      target = .readingNetwork
      keepConnection = true
    case .invalidConfig:
      target = network == nil ? .openWindow : .editingNetwork
      keepConnection = network != nil
    case .bluetoothUnavailable, .linkNotReady, .connectionDropped, .timedOut, .protocolError:
      target = .connecting
    }
    SetupLog.flow.error(
      "stopped: \(String(describing: failure), privacy: .public); the connection is \(keepConnection ? "kept" : "closed", privacy: .public)"
    )
    if !keepConnection { await close() }
    state = .failed(failure, target)
    if target == .enterCode {
      client = nil
      lastController?.save(nil)
    }
  }
  /// The retry target once a failure's connection is gone.
  private func target(forLost failure: SetupFailure) -> RetryTarget {
    switch failure {
    case .windowClosed, .tableFull, .enrolmentRefused: .openWindow
    case .controllerReset: .enterCode
    default: .connecting
    }
  }
  /// A Bluetooth open or reconnect that failed.
  private static func failure(_ error: TransportError) -> SetupFailure {
    switch error {
    case .unreachable: .bluetoothUnavailable
    case .dropped: .connectionDropped
    case .timedOut: .timedOut
    case .notReady: .linkNotReady
    // Not a Bluetooth failure; no Bluetooth transport reports it.
    case .localNetworkDenied: .connectionDropped
    }
  }
  private static func unavailable(_ error: TransportError) -> WiFiUnavailable {
    switch error {
    case .localNetworkDenied: .localNetworkDenied
    case .unreachable, .dropped, .timedOut, .notReady: .notReachable
    }
  }
  private static func unavailable(_ failure: SetupFailure) -> WiFiUnavailable {
    switch failure {
    case .controllerMismatch: .otherController
    case .connectionDropped, .timedOut, .bluetoothUnavailable, .linkNotReady: .notReachable
    case .windowClosed, .wrongProof, .tableFull, .staleVersion, .invalidConfig, .enrolmentRefused,
      .controllerReset, .protocolError, .timeRejected, .timeNeedsButton:
      .refused
    }
  }
}

extension SetupFlow.State {
  /// The state for a log, without the network's SSID, country or hostname.
  var logLabel: String {
    switch self {
    case .editingNetwork(let settings): "editingNetwork(version \(settings.version))"
    case .failed(let failure, let target): "failed(\(failure), retry \(target))"
    case .enterCode, .connecting, .openWindow, .discovering, .pairing, .greeting,
      .readingNetwork, .writingNetwork, .written, .settingTime, .finished:
      "\(self)"
    }
  }
}
