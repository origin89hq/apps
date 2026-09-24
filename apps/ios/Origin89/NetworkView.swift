import Origin89UI
import SetupKit
import SwiftUI

/// The network section as read, and the form that writes it. The passphrase
/// is never shown: the controller only says whether one is held (P-106).
struct NetworkView: View {
  let settings: NetworkSettings
  let save: (NetworkChange) -> Void

  @State private var ssid: String
  @State private var passphrase = ""
  @State private var country: String
  @State private var hostname: String

  init(settings: NetworkSettings, save: @escaping (NetworkChange) -> Void) {
    self.settings = settings
    self.save = save
    _ssid = State(initialValue: settings.ssid ?? "")
    _country = State(initialValue: settings.country ?? "")
    _hostname = State(initialValue: settings.hostname ?? "")
  }

  var body: some View {
    Form {
      Section("On the controller") {
        Row(label: "Network", value: settings.ssid ?? "Not set")
        Row(label: "Passphrase", value: settings.passphraseSet ? "Set" : "Not set")
        Row(label: "Country", value: settings.country ?? "Not set")
        Row(label: "Hostname", value: settings.hostname ?? "Not set")
        Row(
          label: "Version",
          value: settings.version == 0 ? "Never written" : String(settings.version))
      }
      Section {
        TextField("Network name (SSID)", text: $ssid)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField(passphrasePrompt, text: $passphrase)
        TextField("Country (two capital letters)", text: $country)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
        TextField("Hostname", text: $hostname)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } header: {
        Text("Change")
      } footer: {
        if let problem {
          Text(problem).foregroundStyle(Color.origin89.warning)
        } else {
          Text("Written against version \(settings.version); the controller checks it again.")
        }
      }
      Section {
        Button("Save to the controller") {
          save(
            NetworkChange(
              ssid: ssid.isEmpty ? nil : ssid,
              passphrase: passphrase.isEmpty ? nil : passphrase,
              country: country, hostname: hostname))
          passphrase = ""
        }
        .disabled(problem != nil)
      }
    }
  }

  /// The passphrase held on the controller is kept only for the network it
  /// was given for (P-107).
  private var canKeepPassphrase: Bool {
    settings.passphraseSet && !ssid.isEmpty && ssid == settings.ssid
  }

  private var passphrasePrompt: String {
    canKeepPassphrase ? "Passphrase (leave empty to keep)" : "Passphrase"
  }

  /// The first reason the form cannot be saved, checked against the section's
  /// bounds (P-101) and P-107. The controller still validates everything.
  private var problem: String? {
    if ssid.isEmpty {
      if !passphrase.isEmpty { return "A passphrase needs a network name." }
    } else {
      if ssid.utf8.count > 32 { return "The network name is longer than 32 bytes." }
      if passphrase.isEmpty, !canKeepPassphrase {
        return
          "Enter the passphrase for \(ssid). A passphrase is kept only for the network it was given for."
      }
      if !passphrase.isEmpty, !(8...63).contains(passphrase.utf8.count) {
        return "The passphrase must be 8 to 63 bytes long."
      }
    }
    if country.utf8.count != 2 || !country.utf8.allSatisfy({ (65...90).contains($0) }) {
      return "The country is two capital letters, such as CA."
    }
    let host = Array(hostname.utf8)
    let allowed = host.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45
    }
    if host.isEmpty || host.count > 32 || !allowed || host.first == 45 || host.last == 45 {
      return
        "The hostname is 1 to 32 letters, digits and hyphens, not starting or ending with a hyphen."
    }
    return nil
  }
}

private struct Row: View {
  let label: String
  let value: String
  var body: some View {
    LabeledContent(label) {
      Text(value).foregroundStyle(Color.origin89.fg)
    }
  }
}
