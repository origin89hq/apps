import Origin89UI
import SetupKit
import SwiftUI

/// Choose the network the controller joins, then enter its password. On a
/// controller that reports Wi-Fi (P-216) the list is what its radio hears;
/// otherwise it holds the networks the controller and this phone already
/// know. Any other network is typed. The passphrase is never shown: the
/// controller only says whether one is held (P-106).
struct NetworkView: View {
  let settings: NetworkSettings
  let flow: SetupFlow
  /// The page opened from the list. The caller keeps it, so a reconnect
  /// after the app left the screen reopens it.
  @Binding var step: NetworkStep?

  @State private var phoneSSID: String?

  var body: some View {
    List {
      Section {
        Header(
          title: "Choose the Wi-Fi network your controller should use.",
          detail: flow.reportsWiFi
            ? "These are the networks the controller can hear."
            : "Networks this phone or the controller already know are listed here.")
      }
      if flow.reportsWiFi, let heard = flow.scan?.networks {
        Section {
          ForEach(heard) { network in
            Button {
              step = .join(network.ssid)
            } label: {
              HeardRow(
                network: network, saved: same(network.ssid, settings.ssid),
                onPhone: same(network.ssid, phoneSSID))
            }
            .disabled(!network.security.isJoinable)
          }
          Button("Other network…") { step = .other }
        } header: {
          scanHeader
        } footer: {
          if let scanNote { Text(scanNote) }
        }
      } else {
        Section {
          ForEach(NetworkSuggestion.list(controller: settings.ssid, phone: phoneSSID)) {
            suggestion in
            Button {
              step = .join(suggestion.ssid)
            } label: {
              SuggestionRow(suggestion: suggestion, passphraseSet: settings.passphraseSet)
            }
          }
          if flow.isScanning {
            HStack {
              ProgressView()
              Text("Looking for networks…").foregroundStyle(Color.origin89.muted)
            }
          }
          Button("Other network…") { step = .other }
        } header: {
          if flow.reportsWiFi { scanHeader }
        } footer: {
          if let scanNote { Text(scanNote) }
        }
      }
      LinkSection(flow: flow)
      if let held = settings.ssid {
        Section {
          Button("Forget this network", role: .destructive) { step = .forget }
        } footer: {
          Text("The controller stops joining \(held) and deletes its password.")
        }
      }
    }
    .navigationDestination(item: $step) { step in
      NetworkDetailsView(mode: mode(for: step), settings: settings) { change in
        self.step = nil
        Task { await flow.writeNetwork(change) }
      }
    }
    .task { flow.scanNetworks() }
    .task { phoneSSID = await PhoneWiFi().currentSSID() }
  }

  private var scanHeader: some View {
    HStack {
      Text("Networks the controller hears")
      Spacer()
      if flow.isScanning {
        ProgressView()
      } else {
        Button("Scan again") { flow.scanNetworks() }
          .font(.footnote)
          .textCase(nil)
      }
    }
  }

  /// What the last scan answer says beyond its list (P-217, P-218).
  private var scanNote: String? {
    guard flow.reportsWiFi, let scan = flow.scan else { return nil }
    switch scan.refused {
    case .tooSoon: return "The controller scanned moments ago. Try again in a few seconds."
    case .radioOff:
      return
        "The controller's radio stays off until it has a network. Choose one above or enter its name."
    case .linkDown: return "The controller cannot reach its Wi-Fi radio right now."
    case .unauthorised: return "This phone may not start a scan."
    case nil: break
    }
    switch scan.progress {
    case .failed: return "The last scan failed. Scan again, or enter the network by name."
    case .running: return "The scan is taking longer than expected. Scan again in a moment."
    case .none, .complete: break
    }
    guard let networks = scan.networks else { return nil }
    if networks.isEmpty { return "The controller heard no networks." }
    if scan.unlisted > 0 {
      return
        "\(scan.unlisted) more networks were heard. Choose Other network for one not listed."
    }
    return nil
  }

  private func mode(for step: NetworkStep) -> NetworkDetailsView.Mode {
    switch step {
    case .join(let ssid): .join(ssid)
    case .other: .other
    case .forget: .forget
    }
  }
}

/// A page opened from the network list: the password for a chosen network,
/// a network typed by name, or forgetting the held one.
enum NetworkStep: Hashable {
  case join(String)
  case other, forget
}

/// SSIDs compare byte for byte, as the controller compares them (P-107).
private func same(_ ssid: String, _ other: String?) -> Bool {
  other.map { ssid.utf8.elementsEqual($0.utf8) } ?? false
}

private struct Header: View {
  let title: String
  let detail: String
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.origin89Value)
      Text(detail).foregroundStyle(Color.origin89.muted)
    }
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
  }
}

/// A network the controller heard. The list is the radio's account (P-221):
/// it is shown, and a pick still goes through the password step.
private struct HeardRow: View {
  let network: HeardNetwork
  let saved: Bool
  let onPhone: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(network.ssid)
          .foregroundStyle(network.security.isJoinable ? Color.origin89.fg : Color.origin89.muted)
        if let detail {
          Text(detail).font(.origin89Label).foregroundStyle(Color.origin89.muted)
        }
      }
      Spacer()
      if network.security != .open {
        Image(systemName: "lock.fill")
          .foregroundStyle(Color.origin89.muted)
          .accessibilityLabel("Secured")
      }
      Image(systemName: "wifi", variableValue: Double(network.bars) / 3)
        .foregroundStyle(Color.origin89.muted)
        .accessibilityLabel("Signal \(network.bars) of 3")
      if network.security.isJoinable {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.origin89.faint)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }

  private var detail: String? {
    switch network.security {
    case .open: return "Open network. The controller needs a password-protected network."
    case .other: return "Enterprise or other security. Not supported."
    case .wpa2Personal, .wpa3Personal: break
    }
    switch (saved, onPhone) {
    case (true, true): return "Saved on the controller · this phone's network"
    case (true, false): return "Saved on the controller"
    case (false, true): return "This phone's network"
    case (false, false): return nil
    }
  }
}

private struct SuggestionRow: View {
  let suggestion: NetworkSuggestion
  let passphraseSet: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(suggestion.ssid).foregroundStyle(Color.origin89.fg)
        Text(source).font(.origin89Label).foregroundStyle(Color.origin89.muted)
      }
      Spacer()
      if suggestion.onController, passphraseSet {
        Image(systemName: "lock.fill")
          .foregroundStyle(Color.origin89.muted)
          .accessibilityLabel("Password saved")
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.origin89.faint)
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
  }

  private var source: String {
    switch (suggestion.onController, suggestion.onPhone) {
    case (true, true): "Saved on the controller · this phone's network"
    case (true, false): "Saved on the controller"
    case (false, _): "This phone's network"
    }
  }
}

/// The password step, with country and hostname folded under advanced
/// options. Problems show once the person tries to continue.
private struct NetworkDetailsView: View {
  enum Mode: Equatable {
    case join(String)
    case other, forget
  }

  let mode: Mode
  let settings: NetworkSettings
  let save: (NetworkChange) -> Void

  @State private var draft: NetworkDraft
  @State private var passwordShown = false
  @State private var advancedOpen: Bool
  @State private var attempted = false
  @FocusState private var focus: Field?

  private enum Field { case name, password }

  init(mode: Mode, settings: NetworkSettings, save: @escaping (NetworkChange) -> Void) {
    self.mode = mode
    self.settings = settings
    self.save = save
    let ssid: String? =
      switch mode {
      case .join(let ssid): ssid
      case .other: ""
      case .forget: nil
      }
    let draft = NetworkDraft(
      ssid: ssid, settings: settings, region: Locale.current.region?.identifier)
    _draft = State(initialValue: draft)
    _advancedOpen = State(initialValue: draft.advancedProblem != nil)
  }

  var body: some View {
    Form {
      Section { Header(title: title, detail: detail) }
      if mode != .forget {
        Section {
          if mode == .other {
            TextField("Network name", text: typedName)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .focused($focus, equals: .name)
              .submitLabel(.next)
              .onSubmit { focus = .password }
          }
          passwordField
        }
      }
      Section {
        DisclosureGroup("Advanced options", isExpanded: $advancedOpen) {
          LabeledContent("Country") {
            TextField("CA", text: $draft.country)
              .textInputAutocapitalization(.characters)
              .autocorrectionDisabled()
              .multilineTextAlignment(.trailing)
          }
          LabeledContent("Hostname") {
            TextField("Required", text: $draft.hostname)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .multilineTextAlignment(.trailing)
          }
        }
      } footer: {
        if attempted, let problem {
          Origin89Notice(problem.message, tone: .alarm)
        }
      }
    }
    .navigationTitle(mode == .forget ? "Forget network" : "Wi-Fi password")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      Button(role: mode == .forget ? .destructive : nil, action: submit) {
        Text(mode == .forget ? "Forget network" : "Continue").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .padding()
      .background(.bar)
    }
    .onAppear {
      switch mode {
      case .join: focus = .password
      case .other: focus = .name
      case .forget: break
      }
    }
  }

  private var passwordField: some View {
    HStack {
      Group {
        if passwordShown {
          TextField(passwordPrompt, text: $draft.passphrase)
        } else {
          SecureField(passwordPrompt, text: $draft.passphrase)
        }
      }
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($focus, equals: .password)
      .submitLabel(.continue)
      .onSubmit(submit)
      Button {
        passwordShown.toggle()
      } label: {
        Image(systemName: passwordShown ? "eye.slash" : "eye")
          .foregroundStyle(Color.origin89.muted)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(passwordShown ? "Hide password" : "Show password")
    }
  }

  private var typedName: Binding<String> {
    Binding(get: { draft.ssid ?? "" }, set: { draft.ssid = $0 })
  }

  private var problem: NetworkDraftProblem? { draft.problem(against: settings) }

  private var title: String {
    switch mode {
    case .join(let ssid): "Enter the password for \(ssid)."
    case .other: "Enter the network's name and password."
    case .forget: "Forget \(settings.ssid ?? "this network")?"
    }
  }

  private var detail: String {
    switch mode {
    case .join, .other:
      draft.canKeepPassphrase(settings)
        ? "The controller has a password for this network. Leave the field empty to keep it, or enter a new one. Wi-Fi passwords are case sensitive."
        : "Wi-Fi passwords are case sensitive."
    case .forget:
      "The controller stops joining this network and deletes the password it holds."
    }
  }

  private var passwordPrompt: String {
    draft.canKeepPassphrase(settings) ? "Password (leave empty to keep)" : "Password"
  }

  private func submit() {
    attempted = true
    if let problem {
      if problem.isAdvanced { advancedOpen = true }
      return
    }
    save(draft.change)
    draft.passphrase = ""
  }
}
