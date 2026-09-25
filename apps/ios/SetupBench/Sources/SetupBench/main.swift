import Foundation
import SetupCore
import SetupKit

// setup-bench: the app's setup flow against a real controller, over this
// Mac's Bluetooth. Each run prints a timeline of flow steps on stdout and
// streams the flow's own log (subsystem com.origin89.apps) on stderr.

let usage = """
  usage: setup-bench <command> [options]

    pair [--window-open]   Pair with the controller whose code is in $ORIGIN89_SETUP_CODE
                           and read its network. Without --window-open it waits for Enter
                           once the pairing window is open on the panel.
    read                   Continue from the kept enrolment and read the network section.
    scan                   Read, then run a Wi-Fi scan to its end.
    write --ssid NAME [--country CC] [--hostname NAME] [--watch SECONDS]
                           Read, then write the network with the passphrase in
                           $ORIGIN89_WIFI_PASSPHRASE, and watch the join (default 60 s).
    hold --seconds N       Read, stay connected and idle for N seconds, then send a request.

  options:
    --device ID            The controller's device_id; defaults to the last one paired.
    --code-env NAME        Read the setup code from $NAME instead.
    --passphrase-env NAME  Read the passphrase from $NAME instead.
    --bluetooth-only       Never use Wi-Fi. Otherwise a write that joins moves the session
                           to the controller's address, and later commands try the kept
                           address first; this Mac must be on the controller's network.
    --no-log               Do not stream the flow's log on stderr.

  The setup code and the passphrase are never taken as arguments. Without the
  environment variable, each is read from a file in ~/Library/Application Support/
  Origin89 Bench: setup-code and wifi-passphrase. Enrolments and controller
  addresses are kept there too.
  Keep that directory readable only by you.
  """

/// Where the bench keeps enrolments and the last controller it paired.
enum BenchFiles {
  static var directory: URL {
    URL.applicationSupportDirectory.appending(path: "Origin89 Bench", directoryHint: .isDirectory)
  }
  static var lastDevice: URL { directory.appending(path: "last-device") }

  /// `$variable`, or else the first line of `file` in the bench directory.
  static func secret(_ variable: String, file: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[variable] { return value }
    let url = directory.appending(path: file)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.split(whereSeparator: \.isNewline).first.map(String.init)
  }

  static func ensureDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory.appending(path: "enrolments", directoryHint: .isDirectory),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
}

/// A `device_id` as the controller reports it: 32 lowercase hexadecimal
/// characters, safe as a file name.
func isDeviceID(_ text: String) -> Bool {
  text.utf8.count == 32
    && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

/// Enrolments as files, one per `device_id`, mode 0600. For bench
/// controllers; the app keeps its enrolments in the Keychain.
struct FileEnrolmentStore: EnrolmentStore {
  struct InvalidDeviceID: Error {}

  private func file(_ deviceID: String) -> URL? {
    guard isDeviceID(deviceID) else { return nil }
    return BenchFiles.directory.appending(path: "enrolments").appending(path: deviceID)
  }
  func load(deviceID: String) -> Data? {
    guard let url = file(deviceID) else { return nil }
    return try? Data(contentsOf: url)
  }
  func save(_ enrolment: Data, deviceID: String) throws {
    guard let url = file(deviceID) else { throw InvalidDeviceID() }
    try BenchFiles.ensureDirectory()
    try enrolment.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func remove(deviceID: String) throws {
    guard let url = file(deviceID) else { throw InvalidDeviceID() }
    try removeIfPresent(url)
  }
  func removeAll() throws {
    try removeIfPresent(BenchFiles.directory.appending(path: "enrolments"))
  }
}

func removeIfPresent(_ url: URL) throws {
  do {
    try FileManager.default.removeItem(at: url)
  } catch CocoaError.fileNoSuchFile {
    // Nothing was kept.
  }
}

/// Controller addresses as files, one per `device_id`, next to the enrolments.
struct FileControllerAddresses: ControllerAddressStore {
  private func file(_ deviceID: String) -> URL? {
    guard isDeviceID(deviceID) else { return nil }
    return BenchFiles.directory.appending(path: "addresses").appending(path: deviceID)
  }
  func load(deviceID: String) -> String? {
    guard let url = file(deviceID), let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
  }
  func save(_ address: String?, deviceID: String) {
    guard let url = file(deviceID) else { return }
    guard let address else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(address.utf8).write(to: url, options: [.atomic])
  }
  func removeAll() {
    try? removeIfPresent(BenchFiles.directory.appending(path: "addresses"))
  }
}

/// The controller to continue with, as a relaunch of the app would find it.
final class BenchLastController: LastControllerStore, @unchecked Sendable {
  private let lock = NSLock()
  private var deviceID: String?
  init(_ deviceID: String?) { self.deviceID = deviceID }
  func load() -> String? { lock.withLock { deviceID } }
  func save(_ deviceID: String?) { lock.withLock { self.deviceID = deviceID } }
}

struct BenchError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Command-line options: `--name value` pairs and bare `--flag`s.
struct Options {
  let command: String
  private var values: [String: String] = [:]
  private var flags: Set<String> = []

  init(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw BenchError(usage) }
    self.command = command
    var rest = arguments.dropFirst()
    let bare: Set<String> = ["window-open", "no-log", "bluetooth-only"]
    while let argument = rest.popFirst() {
      guard argument.hasPrefix("--") else { throw BenchError("unexpected \(argument)\n\n\(usage)") }
      let name = String(argument.dropFirst(2))
      if bare.contains(name) {
        flags.insert(name)
      } else if let value = rest.popFirst() {
        values[name] = value
      } else {
        throw BenchError("--\(name) needs a value")
      }
    }
  }
  subscript(name: String) -> String? { values[name] }
  func has(_ flag: String) -> Bool { flags.contains(flag) }
  func seconds(_ name: String, default fallback: Int) throws -> Duration {
    guard let text = values[name] else { return .seconds(fallback) }
    guard let seconds = Int(text), seconds > 0 else {
      throw BenchError("--\(name) is a whole number of seconds")
    }
    return .seconds(seconds)
  }
}

/// Timestamped lines on stdout, measured from the start of the run.
@MainActor final class Timeline {
  private let start = ContinuousClock.now
  func say(_ text: String) {
    let elapsed = start.duration(to: .now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    print(String(format: "+%8.3fs ", seconds) + text)
    fflush(stdout)
  }
}

/// The flow's own log for this process, streamed on stderr.
func streamLog() -> Process {
  let stream = Process()
  stream.executableURL = URL(filePath: "/usr/bin/log")
  stream.arguments = [
    "stream", "--style", "compact", "--level", "debug", "--predicate",
    "subsystem == \"com.origin89.apps\" AND processID == \(ProcessInfo.processInfo.processIdentifier)",
  ]
  stream.standardOutput = FileHandle.standardError
  return stream
}

func label(_ state: SetupFlow.State) -> String {
  switch state {
  case .editingNetwork(let settings): "editingNetwork(version \(settings.version))"
  case .failed(let failure, let target): "failed(\(failure), retry \(target)): \(failure.message)"
  case .enterCode, .connecting, .openWindow, .discovering, .pairing, .greeting, .readingNetwork,
    .writingNetwork, .written, .settingTime, .finished, .suspended:
    "\(state)"
  }
}

@MainActor struct Bench {
  let options: Options
  let timeline = Timeline()
  let store = FileEnrolmentStore()

  func flow(resuming deviceID: String?) -> SetupFlow {
    var webSocket: (@MainActor @Sendable (String) -> (any FrameTransport)?)?
    if !options.has("bluetooth-only") { webSocket = { WebSocketTransport.km43(address: $0) } }
    return SetupFlow(
      factory: RustControllerClientFactory(
        label: "Origin89 bench \(Host.current().localizedName ?? "Mac")"),
      store: store,
      transportFactory: { BluetoothTransport(identifiers: .km43, codec: RustFragmentCodec()) },
      lastController: BenchLastController(deviceID),
      webSocketFactory: webSocket,
      addresses: FileControllerAddresses())
  }

  /// Print state, join and scan changes until `done` holds or `limit` passes.
  func watch(_ flow: SetupFlow, for limit: Duration, until done: (SetupFlow) -> Bool) async {
    let deadline = ContinuousClock.now + limit
    var seen = (label(flow.state), "\(flow.join)", flow.isScanning, link(flow))
    while !done(flow), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
      let now = (label(flow.state), "\(flow.join)", flow.isScanning, link(flow))
      if now.0 != seen.0 { timeline.say("state \(now.0)") }
      if now.1 != seen.1 { timeline.say("join \(now.1)") }
      if now.2 != seen.2 { timeline.say(now.2 ? "scan running" : "scan stopped") }
      if now.3 != seen.3 { timeline.say("link \(now.3)") }
      seen = now
    }
  }

  func link(_ flow: SetupFlow) -> String {
    let link = flow.link.map { "\($0)" } ?? "closed"
    if flow.isSwitchingToWiFi { return "\(link), opening Wi-Fi" }
    guard let unavailable = flow.wifiUnavailable else { return link }
    return "\(link); Wi-Fi unavailable (\(unavailable)): \(unavailable.message)"
  }

  func run() async throws {
    switch options.command {
    case "pair": try await pair()
    case "read":
      let (flow, settings) = try await resumed()
      report(settings)
      await flow.reset()
    case "scan": try await scan()
    case "write": try await write()
    case "hold": try await hold()
    case "help": print(usage)
    default: throw BenchError(usage)
    }
  }

  func pair() async throws {
    let name = options["code-env"] ?? "ORIGIN89_SETUP_CODE"
    guard let code = BenchFiles.secret(name, file: "setup-code") else {
      throw BenchError("no setup code in $\(name) or the setup-code file")
    }
    let flow = flow(resuming: nil)
    do { try flow.submitCode(code) } catch { throw BenchError("the setup code is malformed") }
    timeline.say("connecting")
    await flow.connect()
    if flow.state == .openWindow {
      if !options.has("window-open") {
        timeline.say("open the pairing window on the panel, then press Enter")
        _ = readLine()
      }
      await flow.confirmWindowOpened()
    }
    guard case .editingNetwork(let settings) = flow.state, let deviceID = flow.controller?.deviceID
    else { throw BenchError("pairing stopped: \(label(flow.state))") }
    try BenchFiles.ensureDirectory()
    try Data(deviceID.utf8).write(to: BenchFiles.lastDevice, options: [.atomic])
    timeline.say("paired with \(deviceID)")
    report(settings)
    await flow.reset()
  }

  /// Continue from the kept enrolment to the network section.
  func resumed() async throws -> (SetupFlow, NetworkSettings) {
    let deviceID =
      try options["device"]
      ?? (try? String(contentsOf: BenchFiles.lastDevice, encoding: .utf8))
      ?? { throw BenchError("no controller: run pair, or pass --device") }()
    guard isDeviceID(deviceID) else { throw BenchError("\(deviceID) is not a device_id") }
    let flow = flow(resuming: deviceID)
    guard flow.state == .connecting else {
      throw BenchError("no kept enrolment for \(deviceID): run pair first")
    }
    timeline.say("continuing with \(deviceID)")
    await flow.connect()
    guard case .editingNetwork(let settings) = flow.state else {
      throw BenchError("stopped: \(label(flow.state))")
    }
    timeline.say(
      "state \(label(flow.state)), reports Wi-Fi \(flow.reportsWiFi), link \(link(flow))")
    return (flow, settings)
  }

  func report(_ settings: NetworkSettings) {
    timeline.say(
      "network version \(settings.version), ssid \(settings.ssid ?? "none"), passphrase held \(settings.passphraseSet), country \(settings.country ?? "none"), hostname \(settings.hostname ?? "none")"
    )
  }

  func scan() async throws {
    let (flow, settings) = try await resumed()
    report(settings)
    flow.scanNetworks()
    await watch(flow, for: .seconds(30)) { !$0.isScanning }
    if let scan = flow.scan {
      timeline.say(
        "scan \(scan.progress), refused \(scan.refused.map { "\($0)" } ?? "no"), unlisted \(scan.unlisted)"
      )
      for network in scan.networks ?? [] {
        timeline.say(
          "  \(network.ssid)  \(network.rssi) dBm  \(network.security)  \(network.band) ch \(network.channel)"
        )
      }
    }
    await flow.reset()
  }

  func write() async throws {
    guard let ssid = options["ssid"] else { throw BenchError("write needs --ssid") }
    let name = options["passphrase-env"] ?? "ORIGIN89_WIFI_PASSPHRASE"
    let passphrase = BenchFiles.secret(name, file: "wifi-passphrase")
    let watchFor = try options.seconds("watch", default: 60)
    let (flow, settings) = try await resumed()
    report(settings)
    var draft = NetworkDraft(
      ssid: ssid, settings: settings, region: Locale.current.region?.identifier)
    draft.passphrase = passphrase ?? ""
    if let country = options["country"] { draft.country = country }
    if let hostname = options["hostname"] { draft.hostname = hostname }
    if let problem = draft.problem(against: settings) {
      await flow.reset()
      throw BenchError("not written: \(problem.message)")
    }
    timeline.say("writing \(ssid), country \(draft.country), hostname \(draft.hostname)")
    await flow.writeNetwork(draft.change)
    timeline.say("state \(label(flow.state))")
    guard case .written = flow.state else {
      await flow.reset()
      throw BenchError("write stopped")
    }
    await watch(flow, for: watchFor) { flow in
      if case .failed = flow.state { return true }
      switch flow.join {
      // A join is followed by the switch to Wi-Fi.
      case .joined:
        return options.has("bluetooth-only")
          || (!flow.isSwitchingToWiFi && (flow.link != .bluetooth || flow.wifiUnavailable != nil))
      case .failed, .noAnswer, .connectionLost: return true
      case .idle, .waiting: return false
      }
    }
    timeline.say("final state \(label(flow.state)), join \(flow.join), link \(link(flow))")
    await flow.reset()
  }

  func hold() async throws {
    let idle = try options.seconds("seconds", default: 60)
    let (flow, _) = try await resumed()
    timeline.say("holding the connection idle for \(idle)")
    try? await Task.sleep(for: idle)
    timeline.say("sending a request after the hold")
    if flow.reportsWiFi {
      flow.scanNetworks(refresh: false)
      await watch(flow, for: .seconds(20)) { !$0.isScanning }
    } else {
      timeline.say("the controller does not report Wi-Fi: no request to send")
    }
    timeline.say("state \(label(flow.state))")
    await flow.reset()
  }
}

let options: Options
do { options = try Options(Array(CommandLine.arguments.dropFirst())) } catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
let log = options.has("no-log") ? nil : streamLog()
try? log?.run()
// Let the stream attach before the first line is logged.
try? await Task.sleep(for: .milliseconds(500))
let bench = Bench(options: options)
var status: Int32 = 0
do { try await bench.run() } catch {
  bench.timeline.say("error: \(error)")
  status = 1
}
// Let the stream print the last lines.
try? await Task.sleep(for: .milliseconds(500))
log?.terminate()
exit(status)
