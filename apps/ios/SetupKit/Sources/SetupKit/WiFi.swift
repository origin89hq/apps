import Foundation

/// What `Hello` said that the flow can use.
public struct SessionReport: Sendable, Equatable {
  /// The controller answers Wi-Fi scan and status reads (capability bit 8,
  /// P-216). Without it the person types the network name.
  public var reportsWiFi: Bool
  public init(reportsWiFi: Bool) { self.reportsWiFi = reportsWiFi }
}

public enum NetworkSecurity: Sendable, Equatable {
  case open, wpa2Personal, wpa3Personal, other

  /// The network section always carries a WPA passphrase (L-131), so only
  /// WPA Personal networks can be joined.
  public var isJoinable: Bool {
    switch self {
    case .wpa2Personal, .wpa3Personal: true
    case .open, .other: false
    }
  }
}

public enum NetworkBand: Sendable, Equatable { case ghz24, ghz5, ghz6 }

/// One network the controller's radio heard: the strongest access point for
/// its SSID. The comms processor's account, shown and never acted on (P-221).
public struct HeardNetwork: Sendable, Equatable, Identifiable {
  public var ssid: String
  /// dBm.
  public var rssi: Int8
  public var security: NetworkSecurity
  public var band: NetworkBand
  public var channel: UInt8
  /// The SSID's bytes, as the controller compares SSIDs.
  public var id: [UInt8] { Array(ssid.utf8) }

  public init(
    ssid: String, rssi: Int8, security: NetworkSecurity, band: NetworkBand, channel: UInt8
  ) {
    self.ssid = ssid
    self.rssi = rssi
    self.security = security
    self.band = band
    self.channel = channel
  }

  /// Signal as 1 to 3 bars: -60 dBm or better is strong, below -75 weak.
  public var bars: Int {
    if rssi >= -60 { return 3 }
    return rssi >= -75 ? 2 : 1
  }
}

public enum ScanProgress: Sendable, Equatable { case none, running, complete, failed }

/// Why a refresh started no scan (P-218).
public enum ScanRefusal: Sendable, Equatable { case tooSoon, radioOff, linkDown, unauthorised }

/// `WifiScan 0x91`. No list and an empty list are different answers.
public struct NetworkScan: Sendable, Equatable {
  public var progress: ScanProgress
  public var refused: ScanRefusal?
  /// Strongest first, one per SSID; nil when no scan has completed.
  public var networks: [HeardNetwork]?
  /// Networks heard and left out of `networks`.
  public var unlisted: Int

  public init(
    progress: ScanProgress, refused: ScanRefusal? = nil, networks: [HeardNetwork]?,
    unlisted: Int = 0
  ) {
    self.progress = progress
    self.refused = refused
    self.networks = networks
    self.unlisted = unlisted
  }
}

public enum JoinFailure: Sendable, Equatable {
  case authFailed, notFound, noIP, lost, other

  public var message: String {
    switch self {
    case .authFailed: "The network refused the password."
    case .notFound: "The controller cannot hear this network. It may be too far away or 5 GHz only."
    case .noIP: "The controller joined but the network gave it no address."
    case .lost: "The controller joined, then lost the network."
    case .other: "The controller could not join the network."
    }
  }
}

/// What the radio is doing with the network it holds.
public enum RadioState: Sendable, Equatable {
  case off, joining
  case joined(address: String)
  case failed(JoinFailure)
}

/// `WifiStatus 0x92`: the section version the controller holds, and the
/// version the radio is acting on with what it is doing (P-219).
public struct WiFiStatus: Sendable, Equatable {
  public var section: UInt32
  public var radio: (version: UInt32, state: RadioState)?

  public init(section: UInt32, radio: (version: UInt32, state: RadioState)?) {
    self.section = section
    self.radio = radio
  }

  /// The radio's state for `version`, the section version a write produced;
  /// nil while it reports on another version or not at all.
  public func state(for version: UInt32) -> RadioState? {
    guard let radio, radio.version == version else { return nil }
    return radio.state
  }

  public static func == (lhs: WiFiStatus, rhs: WiFiStatus) -> Bool {
    lhs.section == rhs.section && lhs.radio?.version == rhs.radio?.version
      && lhs.radio?.state == rhs.radio?.state
  }
}
