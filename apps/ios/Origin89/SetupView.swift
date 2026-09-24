import Origin89UI
import SetupKit
import SwiftUI

/// The setup flow: scan or paste the code, connect over Bluetooth, pair inside the
/// panel's window, then read and write the network section.
struct SetupView: View {
  let flow: SetupFlow

  @State private var windowOpenedAt: Date?
  @State private var failedDuring: SetupFlow.State?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Set up a controller")
        .toolbar {
          if flow.state != .enterCode {
            Button("Start over") { Task { await startOver() } }
          }
        }
    }
    .tint(Palette.color(\.action))
    .onChange(of: flow.state) { old, new in
      if case .failed = new { failedDuring = old }
      switch new {
      case .discovering, .pairing: break
      default: windowOpenedAt = nil
      }
    }
    // A controller allows two connections: never hold one in the background.
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { Task { await flow.suspend() } }
    }
    .onDisappear { Task { await flow.suspend() } }
  }

  @ViewBuilder private var content: some View {
    switch flow.state {
    case .enterCode:
      CodeEntryView { code throws(SetupCodeError) in
        try flow.submitCode(code)
        Task { await flow.connect() }
      }
    case .connecting:
      Progress(title: "Connecting over Bluetooth", detail: "Keep the phone near the controller.")
    case .openWindow:
      OpenWindowView {
        windowOpenedAt = Date()
        Task { await flow.confirmWindowOpened() }
      }
    case .discovering, .pairing, .greeting:
      PairingView(state: flow.state, windowOpenedAt: windowOpenedAt)
    case .readingNetwork:
      Progress(title: "Reading network settings", detail: nil)
    case .editingNetwork(let settings):
      NetworkView(settings: settings) { change in Task { await flow.writeNetwork(change) } }
    case .writingNetwork:
      Progress(title: "Saving network settings", detail: nil)
    case .written(let version):
      WrittenView(version: version) {
        Task { await flow.setTime() }
      } done: {
        Task { await flow.finish() }
      }
    case .finished(let version, let timeSet):
      FinishedView(version: version, timeSet: timeSet) { Task { await startOver() } }
    case .settingTime:
      Progress(title: "Setting the controller's clock", detail: nil)
    case .failed(let failure, _):
      FailureView(message: message(for: failure)) {
        Task { await flow.retry() }
      } startOver: {
        Task { await startOver() }
      }
    }
  }

  /// A wrong setup code cannot be told apart from a forged reply: the
  /// controller's refusal is signed with the real code, so this phone cannot
  /// verify it and reports a protocol error. During pairing, say so.
  private func message(for failure: SetupFailure) -> String {
    if failure == .protocolError, failedDuring == .pairing {
      return
        "The controller's answer could not be verified with this setup code. Check that the code belongs to this controller and was entered exactly, then start over."
    }
    return failure.message
  }

  private func startOver() async {
    failedDuring = nil
    windowOpenedAt = nil
    await flow.reset()
  }
}

/// Origin89 palette colors that follow the current appearance.
enum Palette {
  static func color(_ token: any KeyPath<Origin89Palette, Color> & Sendable) -> Color {
    Color(
      UIColor { traits in
        let palette =
          traits.userInterfaceStyle == .dark ? Origin89Tokens.dark : Origin89Tokens.light
        return UIColor(palette[keyPath: token])
      })
  }
}

private struct Heading: View {
  let text: String
  var body: some View {
    Text(text).font(.custom("InterTight-SemiBold", size: 22, relativeTo: .title2))
  }
}

private struct Progress: View {
  let title: String
  let detail: String?
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
      Heading(text: title)
      if let detail { Text(detail).foregroundStyle(.secondary) }
    }
    .multilineTextAlignment(.center)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

enum CodeEntryMessage {
  static let refused =
    "That is not a setup code. Scan the code on the controller's label, or paste it exactly as printed."
}

private struct CodeEntryView: View {
  let submit: (String) throws(SetupCodeError) -> Void
  @State private var code = ""
  @State private var refused = false
  @State private var camera = CameraAccess.current
  @State private var scanning = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    Form {
      Section {
        TextField("km43:1:…", text: $code, axis: .vertical)
          .font(.system(.body, design: .monospaced))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: code) { refused = false }
        HStack {
          Button("Paste") { code = UIPasteboard.general.string ?? "" }
          if camera != .unavailable {
            Spacer()
            Button("Scan QR code") { Task { await scan() } }
          }
        }
        .buttonStyle(.borderless)
      } header: {
        Text("Setup code")
      } footer: {
        Text(
          refused
            ? CodeEntryMessage.refused
            : "Scan or paste the code printed on the controller's label. It is used once to pair and is not kept."
        )
        .foregroundStyle(refused ? Palette.color(\.alarm) : .secondary)
      }
      if camera == .denied || camera == .restricted {
        Section {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
          }
        } footer: {
          Text(
            camera == .denied
              ? "Camera access is off for Origin89. Turn it on in Settings to scan, or paste the code."
              : "Camera access is restricted on this phone. Paste the code instead."
          )
        }
      }
      Section {
        Button("Connect") {
          do { try submit(code) } catch { refused = true }
        }
        .disabled(code.isEmpty)
      }
    }
    .sheet(isPresented: $scanning) {
      CodeScannerSheet(submit: submit)
    }
  }

  private func scan() async {
    camera = CameraAccess.current
    if camera == .notDetermined { camera = await CameraAccess.request() }
    if camera == .allowed {
      refused = false
      scanning = true
    }
  }
}

private struct OpenWindowView: View {
  let opened: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Heading(text: "Open the pairing window")
      Text(
        "Press the pairing button on the controller's panel. The window stays open for 120 seconds, and pairing must finish inside it."
      )
      Button("The window is open, pair now", action: opened)
        .buttonStyle(.borderedProminent)
      Spacer()
    }
    .padding()
  }
}

private struct PairingView: View {
  let state: SetupFlow.State
  let windowOpenedAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Heading(text: "Pairing")
      if let windowOpenedAt, state != .greeting {
        TimelineView(.periodic(from: windowOpenedAt, by: 1)) { context in
          let left = max(0, 120 - Int(context.date.timeIntervalSince(windowOpenedAt)))
          Text("Window closes in \(left / 60):\(String(format: "%02d", left % 60))")
            .font(.custom("IBMPlexMono-Regular", size: 17, relativeTo: .body))
            .monospacedDigit()
            .foregroundStyle(left > 20 ? Palette.color(\.fg) : Palette.color(\.warning))
        }
      }
      Step(
        title: "Finding the controller", done: state != .discovering, active: state == .discovering)
      Step(title: "Proving the setup code", done: state == .greeting, active: state == .pairing)
      Step(title: "Opening a session", done: false, active: state == .greeting)
      Spacer()
    }
    .padding()
  }
}

private struct Step: View {
  let title: String
  let done: Bool
  let active: Bool
  var body: some View {
    HStack(spacing: 12) {
      if active {
        ProgressView()
      } else {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(done ? Palette.color(\.nominal) : Palette.color(\.faint))
      }
      Text(title).foregroundStyle(done || active ? Palette.color(\.fg) : Palette.color(\.muted))
    }
  }
}

private struct WrittenView: View {
  let version: UInt32
  let setTime: () -> Void
  let done: () -> Void
  var body: some View {
    Form {
      Section {
        Label("Network settings saved", systemImage: "checkmark.circle.fill")
          .foregroundStyle(Palette.color(\.nominal))
        Text(
          "The controller accepted version \(version) and passes it to its radio. Watch the module join the network."
        )
      }
      Section {
        Button("Set the controller's clock from this phone", action: setTime)
      } footer: {
        Text("Optional. The time is sent as a signed write, then setup finishes.")
      }
      Section {
        Button("Done", action: done)
      } footer: {
        Text("Ends setup and disconnects. A controller accepts only two connections at once.")
      }
    }
  }
}

private struct FinishedView: View {
  let version: UInt32
  let timeSet: Bool
  let startOver: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Setup finished", systemImage: "checkmark.circle.fill")
        .font(.custom("InterTight-SemiBold", size: 22, relativeTo: .title2))
        .foregroundStyle(Palette.color(\.nominal))
      Text("Network settings version \(version) are on the controller.")
      if timeSet { Text("The controller's clock was set from this phone.") }
      Text("This phone has disconnected from the controller.")
        .foregroundStyle(.secondary)
      Button("Set up another controller", action: startOver)
        .buttonStyle(.borderedProminent)
      Spacer()
    }
    .padding()
  }
}

private struct FailureView: View {
  let message: String
  let retry: () -> Void
  let startOver: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Setup stopped", systemImage: "exclamationmark.triangle.fill")
        .font(.custom("InterTight-SemiBold", size: 22, relativeTo: .title2))
        .foregroundStyle(Palette.color(\.alarm))
      Text(message)
      HStack {
        Button("Try again", action: retry).buttonStyle(.borderedProminent)
        Button("Start over", action: startOver).buttonStyle(.bordered)
      }
      Spacer()
    }
    .padding()
  }
}
