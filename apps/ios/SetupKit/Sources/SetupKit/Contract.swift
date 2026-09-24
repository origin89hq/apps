import Foundation

public enum TransportError: Error, Sendable, Equatable {
  case unreachable, dropped, timedOut
  /// A peer was found, but its link was not ready before the open timeout.
  case notReady
  /// The app may not reach the local network (a WebSocket only).
  case localNetworkDenied
}
/// One KM43 message per opaque frame.
public protocol FrameTransport: Sendable {
  func open() async throws(TransportError)
  func send(_ frame: Data) async throws(TransportError)
  func receive() async throws(TransportError) -> Data
  func close() async
}
/// A transport whose peers look alike until Discover. KM43 over BLE is one:
/// the advertisement, name and address do not identify the controller.
public protocol PeerExcludingTransport: FrameTransport {
  /// Skip the connected peer on later opens. Call it before `close()`.
  func excludeConnectedPeer() async
  /// Allow every peer again.
  func clearExcludedPeers() async
}
public enum SetupCodeError: Error, Sendable, Equatable { case malformed }
public enum SetupFailure: Error, Sendable, Equatable {
  case windowClosed, wrongProof, tableFull, staleVersion, invalidConfig, controllerMismatch
  /// The controller refused the enrolment kept from an earlier launch.
  case enrolmentRefused
  /// The controller was factory reset after this session paired.
  case controllerReset
  case bluetoothUnavailable
  /// A controller was found, but its Bluetooth link was not ready in time.
  case linkNotReady
  case connectionDropped, timedOut, protocolError, timeRejected, timeNeedsButton

  public var message: String {
    switch self {
    case .timeRejected:
      "The controller refused this time because it is outside its accepted window."
    case .timeNeedsButton: "Press the panel button to allow this earlier time, then try again."
    case .windowClosed: "Open the pairing window on the controller and try again."
    case .wrongProof: "The setup code was refused. Check the code printed on this controller."
    case .tableFull: "The controller has no room for another paired client."
    case .staleVersion: "The network settings changed. Read them again before saving."
    case .invalidConfig:
      "The controller refused these network settings. Check the fields and try again."
    case .controllerMismatch:
      "Another controller answered. Move closer to the controller whose code you scanned and try again."
    case .enrolmentRefused:
      "The controller no longer accepts this phone's pairing. Open the pairing window to pair again."
    case .controllerReset:
      "The controller was reset since this phone paired. Scan its setup code to pair again."
    case .bluetoothUnavailable:
      "Bluetooth is unavailable or the controller was not found. Check Bluetooth permission and move closer."
    case .linkNotReady:
      "A controller was found, but its Bluetooth connection did not become ready in time. Move closer and try again."
    case .connectionDropped: "The connection to the controller was lost. Reconnect to it."
    case .timedOut: "The controller did not respond in time. Try connecting again."
    case .protocolError:
      "The controller sent an unexpected or invalid response. Reconnect to try again."
    }
  }
}
public struct ControllerSummary: Sendable, Equatable {
  public var deviceID: String
  public init(deviceID: String) { self.deviceID = deviceID }
}
public struct NetworkSettings: Sendable, Equatable {
  public var version: UInt32
  public var ssid: String?
  public var passphraseSet: Bool
  public var country: String?
  public var hostname: String?
  public init(
    version: UInt32, ssid: String?, passphraseSet: Bool, country: String?, hostname: String?
  ) {
    self.version = version
    self.ssid = ssid
    self.passphraseSet = passphraseSet
    self.country = country
    self.hostname = hostname
  }
}
public struct NetworkChange: Sendable, Equatable {
  public var ssid: String?
  public var passphrase: String?
  public var country: String
  public var hostname: String
  public init(ssid: String?, passphrase: String?, country: String, hostname: String) {
    self.ssid = ssid
    self.passphrase = passphrase
    self.country = country
    self.hostname = hostname
  }
  /// Whether this write can succeed against `settings`. No SSID clears the
  /// network and carries no passphrase. With an SSID, an absent passphrase
  /// keeps the held one, which P-107 allows only for the same SSID.
  public func isValid(comparedTo settings: NetworkSettings) -> Bool {
    guard let ssid else { return passphrase == nil }
    return passphrase != nil || (ssid == settings.ssid && settings.passphraseSet)
  }
}
/// Where enrolments are kept between launches, one per controller `device_id`
/// (P-222). What goes in is the encoded enrolment the core hands over, never a
/// setup code.
public protocol EnrolmentStore: Sendable {
  /// The enrolment kept for `deviceID`, or nil when there is none or it cannot
  /// be read.
  func load(deviceID: String) -> Data?
  /// Keep `enrolment` for `deviceID`, replacing any older entry.
  func save(_ enrolment: Data, deviceID: String) throws
}
public protocol ControllerClient: Sendable {
  /// Take the enrolment `store` kept for this controller, before the first
  /// `discover()`. One that is missing or unreadable leaves the client pairing.
  func restore(from store: any EnrolmentStore) async
  /// Whether the next session greets instead of pairing: enrolled, or holding
  /// a kept enrolment the controller has not refused.
  func isEnrolled() async -> Bool
  /// After `pair()`, keep the enrolment in `store`.
  func keep(in store: any EnrolmentStore) async throws
  func discover() async throws(SetupFailure) -> ControllerSummary
  func pair() async throws(SetupFailure)
  func hello() async throws(SetupFailure) -> SessionReport
  func readNetwork() async throws(SetupFailure) -> NetworkSettings
  /// `WifiScan`; only after a `Hello` whose report says `reportsWiFi` (P-216).
  func scanWiFi(refresh: Bool) async throws(SetupFailure) -> NetworkScan
  /// `WifiStatus`; only after a `Hello` whose report says `reportsWiFi` (P-216).
  func wifiStatus() async throws(SetupFailure) -> WiFiStatus
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  func setTime(_ date: Date) async throws(SetupFailure)
  func close() async
}
public protocol ControllerClientFactory: Sendable {
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  /// A client that continues setup with `deviceID` from the enrolment `store`
  /// kept, without the setup code (P-222). It greets with `Hello` and cannot
  /// pair. Nil when nothing usable is kept.
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)?
}
/// The controller this phone last enrolled with. The next launch reconnects to
/// it from the kept enrolment, before and after its network is written,
/// instead of asking for the code again.
public protocol LastControllerStore: Sendable {
  func load() -> String?
  /// Remember `deviceID`, or forget it with nil.
  func save(_ deviceID: String?)
}
/// The last controller in user defaults. Only the `device_id` is kept here,
/// never a key or the setup code.
public struct DefaultsLastController: LastControllerStore {
  private let key: String
  public init(key: String = "setup.lastController") { self.key = key }
  public func load() -> String? { UserDefaults.standard.string(forKey: key) }
  public func save(_ deviceID: String?) { UserDefaults.standard.set(deviceID, forKey: key) }
}

/// The controller's address on the site network, one per controller
/// `device_id`, as its authenticated `WifiStatus` last reported it. A candidate
/// only: Discover checks it before use (P-225).
public protocol ControllerAddressStore: Sendable {
  func load(deviceID: String) -> String?
  /// Remember `address` for `deviceID`, or forget it with nil.
  func save(_ address: String?, deviceID: String)
}
/// Controller addresses in user defaults.
public struct DefaultsControllerAddresses: ControllerAddressStore {
  private let prefix: String
  public init(prefix: String = "setup.address.") { self.prefix = prefix }
  public func load(deviceID: String) -> String? {
    UserDefaults.standard.string(forKey: prefix + deviceID)
  }
  public func save(_ address: String?, deviceID: String) {
    UserDefaults.standard.set(address, forKey: prefix + deviceID)
  }
}

/// Implemented by the km43 Rust core. One instance per connection.
public protocol FragmentCodec: AnyObject, Sendable {
  func reset()
  func fragments(for message: Data, valueLimit: Int) throws(TransportError) -> [Data]
  func receive(fragment: Data, nowMs: UInt64) throws(TransportError) -> Data?
}
public struct BluetoothIdentifiers: Sendable {
  public var service: String
  public var rx: String
  public var tx: String
  public init(service: String, rx: String, tx: String) {
    self.service = service
    self.rx = rx
    self.tx = tx
  }
}
