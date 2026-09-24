import Foundation

/// A network a person can pick without typing it: the one the controller
/// holds, the one this phone is on, or both when they are the same.
public struct NetworkSuggestion: Sendable, Equatable, Identifiable {
  public var ssid: String
  public var onController: Bool
  public var onPhone: Bool
  public var id: String { ssid }

  public init(ssid: String, onController: Bool, onPhone: Bool) {
    self.ssid = ssid
    self.onController = onController
    self.onPhone = onPhone
  }

  /// The controller's network first, then the phone's, one row per SSID.
  /// SSIDs compare byte for byte, as the controller compares them (P-107).
  public static func list(controller: String?, phone: String?) -> [NetworkSuggestion] {
    let controller = controller.flatMap { $0.isEmpty ? nil : $0 }
    let phone = phone.flatMap { $0.isEmpty ? nil : $0 }
    var list: [NetworkSuggestion] = []
    if let controller {
      list.append(
        NetworkSuggestion(
          ssid: controller, onController: true,
          onPhone: phone.map { sameBytes($0, controller) } ?? false))
    }
    if let phone, !list.contains(where: { sameBytes($0.ssid, phone) }) {
      list.append(NetworkSuggestion(ssid: phone, onController: false, onPhone: true))
    }
    return list
  }
}

/// Why a network draft cannot be saved yet, checked against the section's
/// bounds (P-101) and P-107. The controller still validates everything.
public enum NetworkDraftProblem: Sendable, Equatable {
  case passphraseWithoutNetwork
  case networkNameTooLong
  case passphraseRequired(ssid: String)
  case passphraseLength
  case country
  case hostname

  /// Country and hostname sit under the advanced options, so a problem with
  /// either has to open them.
  public var isAdvanced: Bool {
    switch self {
    case .country, .hostname: true
    case .passphraseWithoutNetwork, .networkNameTooLong, .passphraseRequired, .passphraseLength:
      false
    }
  }

  public var message: String {
    switch self {
    case .passphraseWithoutNetwork: "A password needs a network name."
    case .networkNameTooLong: "The network name is longer than 32 bytes."
    case .passphraseRequired(let ssid):
      "Enter the password for \(ssid). The controller keeps a password only for the network it was given for."
    case .passphraseLength: "Wi-Fi passwords are 8 to 63 characters long."
    case .country: "The country is two capital letters, such as CA."
    case .hostname:
      "The hostname is 1 to 32 letters, digits and hyphens, not starting or ending with a hyphen."
    }
  }
}

/// What the person has entered for the network section. An empty SSID asks
/// the controller to forget its network.
public struct NetworkDraft: Sendable, Equatable {
  public var ssid: String
  public var passphrase: String
  public var country: String
  public var hostname: String

  public init(ssid: String, passphrase: String = "", country: String, hostname: String) {
    self.ssid = ssid
    self.passphrase = passphrase
    self.country = country
    self.hostname = hostname
  }

  /// A draft for `ssid` that keeps the controller's country and hostname.
  /// A controller with no country takes this phone's region when it is a
  /// valid code; nothing is invented for the hostname.
  public init(ssid: String, settings: NetworkSettings, region: String?) {
    let country = settings.country ?? region.flatMap { Self.isCountry($0) ? $0 : nil }
    self.init(ssid: ssid, country: country ?? "", hostname: settings.hostname ?? "")
  }

  /// The controller keeps its passphrase only for the network it was given
  /// for (P-107), so an empty field keeps it only when the SSID is unchanged.
  public func canKeepPassphrase(_ settings: NetworkSettings) -> Bool {
    guard settings.passphraseSet, !ssid.isEmpty, let held = settings.ssid else { return false }
    return sameBytes(ssid, held)
  }

  /// The first reason this draft cannot be saved, or nil.
  public func problem(against settings: NetworkSettings) -> NetworkDraftProblem? {
    if ssid.isEmpty {
      if !passphrase.isEmpty { return .passphraseWithoutNetwork }
    } else {
      if ssid.utf8.count > 32 { return .networkNameTooLong }
      if passphrase.isEmpty, !canKeepPassphrase(settings) { return .passphraseRequired(ssid: ssid) }
      if !passphrase.isEmpty, !(8...63).contains(passphrase.utf8.count) { return .passphraseLength }
    }
    return advancedProblem
  }

  /// A problem with the country or hostname, which sit under the advanced
  /// options. A controller that was never written has neither.
  public var advancedProblem: NetworkDraftProblem? {
    if !Self.isCountry(country) { return .country }
    if !Self.isHostname(hostname) { return .hostname }
    return nil
  }

  public var change: NetworkChange {
    NetworkChange(
      ssid: ssid.isEmpty ? nil : ssid, passphrase: passphrase.isEmpty ? nil : passphrase,
      country: country, hostname: hostname)
  }

  static func isCountry(_ text: String) -> Bool {
    text.utf8.count == 2 && text.utf8.allSatisfy { (65...90).contains($0) }
  }

  static func isHostname(_ text: String) -> Bool {
    let host = Array(text.utf8)
    let allowed = host.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45
    }
    return !host.isEmpty && host.count <= 32 && allowed && host.first != 45 && host.last != 45
  }
}

private func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
