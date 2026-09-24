import Foundation

public enum TransportError: Error, Sendable, Equatable { case unreachable, dropped, timedOut }
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
  case bluetoothUnavailable, connectionDropped, timedOut, protocolError, timeRejected,
    timeNeedsButton

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
    case .bluetoothUnavailable:
      "Bluetooth is unavailable or the controller was not found. Check Bluetooth permission and move closer."
    case .connectionDropped: "The Bluetooth connection was lost. Reconnect to the controller."
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
public protocol ControllerClient: Sendable {
  func discover() async throws(SetupFailure) -> ControllerSummary
  func pair() async throws(SetupFailure)
  func hello() async throws(SetupFailure)
  func readNetwork() async throws(SetupFailure) -> NetworkSettings
  func writeNetwork(_ change: NetworkChange, expectedVersion: UInt32) async throws(SetupFailure)
    -> UInt32
  func setTime(_ date: Date) async throws(SetupFailure)
  func close() async
}
public protocol ControllerClientFactory: Sendable {
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
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
