import Origin89UI
import SetupKit
import SwiftUI

/// Choose the network the controller joins, then enter its password. The
/// controller cannot scan yet (origin89hq/km43#110), so the list holds only
/// the networks the controller and this phone already know, and any other
/// is typed. The passphrase is never shown: the controller only says whether
/// one is held (P-106).
struct NetworkView: View {
  let settings: NetworkSettings
  let save: (NetworkChange) -> Void

  @State private var phoneSSID: String?
  @State private var destination: Destination?

  private enum Destination: Hashable {
    case join(String)
    case other, forget
  }

  var body: some View {
    List {
      Section {
        Header(
          title: "Choose the Wi-Fi network your controller should use.",
          detail: "Networks this phone or the controller already know are listed here.")
      }
      Section {
        ForEach(NetworkSuggestion.list(controller: settings.ssid, phone: phoneSSID)) {
          suggestion in
          Button {
            destination = .join(suggestion.ssid)
          } label: {
            SuggestionRow(suggestion: suggestion, passphraseSet: settings.passphraseSet)
          }
        }
        Button("Other network…") { destination = .other }
      }
      if let held = settings.ssid {
        Section {
          Button("Forget this network", role: .destructive) { destination = .forget }
        } footer: {
          Text("The controller stops joining \(held) and deletes its password.")
        }
      }
    }
    .navigationDestination(item: $destination) { destination in
      NetworkDetailsView(mode: mode(for: destination), settings: settings) { change in
        self.destination = nil
        save(change)
      }
    }
    .task { phoneSSID = await PhoneWiFi().currentSSID() }
  }

  private func mode(for destination: Destination) -> NetworkDetailsView.Mode {
    switch destination {
    case .join(let ssid): .join(ssid)
    case .other: .other
    case .forget: .forget
    }
  }
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
