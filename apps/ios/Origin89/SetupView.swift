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
    .tint(Color.origin89.action)
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
    // A setup an earlier launch left unfinished starts here, in `connecting`.
    .task { await flow.connect() }
  }

  @ViewBuilder private var content: some View {
    switch flow.state {
    case .enterCode:
      CodeEntryView { code throws(SetupCodeError) in
        try flow.submitCode(code)
        Task { await flow.connect() }
      }
    case .connecting:
      Progress(
        title: "Connecting over Bluetooth",
        detail: flow.resumed
          ? "Continuing setup with the controller this phone paired with. Keep the phone near it."
          : "Keep the phone near the controller.")
    case .openWindow:
      OpenWindowView(keptEnrolmentLost: flow.keptEnrolmentLost) {
        windowOpenedAt = Date()
        Task { await flow.confirmWindowOpened() }
      }
    case .discovering, .pairing, .greeting:
      PairingView(state: flow.state, windowOpenedAt: windowOpenedAt)
    case .readingNetwork:
      Progress(title: "Reading network settings", detail: nil)
    case .editingNetwork(let settings):
      NetworkView(settings: settings, flow: flow)
    case .writingNetwork:
      Progress(title: "Saving network settings", detail: nil)
    case .written(let version):
      WrittenView(version: version, flow: flow)
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
    // Continued without the setup code, a refused pairing needs the code again.
    if failure == .enrolmentRefused, flow.resumed {
      return
        "The controller no longer accepts this phone's pairing. Scan its setup code to pair again."
    }
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

private struct Heading: View {
  let text: String
  var body: some View {
    Text(text).font(.origin89Value)
  }
}

private struct Progress: View {
  let title: String
  let detail: String?
  var body: some View {
    SetupPage {
      VStack(spacing: 16) {
        Heading(text: title)
        Origin89Status("In progress", tone: .info)
        Origin89Loading(title)
        if let detail { Origin89Notice(detail) }
      }
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

enum CodeEntryMessage {
  static let refused =
    "That is not a setup code. Scan the code on the controller's label, or paste it exactly as printed."
}

/// The enter-code step. With a camera, the scanner comes first and the paste
/// field is one tap away; without one, only the paste field shows.
private struct CodeEntryView: View {
  let submit: (String) throws(SetupCodeError) -> Void
  @State private var code = ""
  @State private var refused = false
  @State private var camera = CameraAccess.current
  @State private var scannerOpen = true
  @State private var manualShown = false
  @State private var capabilities: CameraCapabilities?
  @State private var cameraFailed = false
  @State private var scanRefused = false
  @State private var torchOn = false
  @State private var zoomed = false
  @State private var hint = ScanHint<ContinuousClock.Instant>()
  @State private var hintVisible = false
  @FocusState private var codeFocused: Bool
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let manualID = "manual"

  private var scanning: Bool { camera != .unavailable && scannerOpen }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        if scanning { scannerSection }
        if !scanning || manualShown { manualSections }
      }
      .onChange(of: manualShown) { _, shown in
        guard shown else { return }
        withAnimation { proxy.scrollTo(Self.manualID, anchor: .top) }
        codeFocused = true
      }
    }
    .safeAreaInset(edge: .bottom) {
      if hintVisible {
        hintCard.transition(
          reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(
      reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4), value: hintVisible
    )
    .toolbar {
      if scanning {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: closeScanner) { Image(systemName: "xmark") }
            .accessibilityLabel("Close scanner")
        }
      }
    }
    .task { await askForCamera() }
    .task(id: hint.deadline) { await showHintWhenDue() }
    .onChange(of: scenePhase) { _, phase in
      // The torch never stays on behind the app.
      if phase != .active { torchOn = false }
      if phase == .active, camera != .unavailable { camera = CameraAccess.current }
    }
  }

  // MARK: Scanner

  @ViewBuilder private var scannerSection: some View {
    Section {
      Text("Scan the QR code on your controller")
        .font(.origin89Value)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
      scannerCard
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
      if !manualShown {
        Button("Enter code manually", action: revealManual)
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder private var scannerCard: some View {
    switch camera {
    case .allowed:
      ScannerCard(
        torchOn: torchOn, zoomed: zoomed, capabilities: capabilities, refused: scanRefused,
        failed: cameraFailed,
        toggleTorch: { torchOn.toggle() },
        toggleZoom: { zoomed.toggle() },
        ready: cameraReady,
        scanned: scanned)
    case .denied, .restricted:
      CameraCard {
        CardMessage(
          text: camera == .denied
            ? "Camera access is off for Origin89. Turn it on in Settings to scan, or enter the code manually."
            : "Camera access is restricted on this phone. Enter the code manually instead."
        ) {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
          }
          .buttonStyle(.borderedProminent)
        }
      }
    case .notDetermined, .unavailable:
      CameraCard { CardMessage(text: "Waiting for camera access.") }
    }
  }

  private func cameraReady(_ capabilities: CameraCapabilities?) {
    self.capabilities = capabilities
    if capabilities == nil {
      cameraFailed = true
      hint.scanStopped()
    } else {
      hint.scanStarted(at: .now)
    }
  }

  /// Submit a scanned code through the same path as paste. A refusal shows
  /// over the preview, and the scanner rearms and restarts the hint's wait.
  private func scanned(_ code: String) -> Bool {
    do {
      try submit(code)
    } catch {
      scanRefused = true
      hint.scanStarted(at: .now)
      return false
    }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    torchOn = false
    hint.scanStopped()
    return true
  }

  private func askForCamera() async {
    guard scanning, camera == .notDetermined else { return }
    camera = await CameraAccess.request()
  }

  private func closeScanner() {
    scannerOpen = false
    torchOn = false
    zoomed = false
    capabilities = nil
    cameraFailed = false
    scanRefused = false
    hint.scanStopped()
  }

  private func openScanner() {
    hint = ScanHint()
    scannerOpen = true
    Task { await askForCamera() }
  }

  // MARK: Hint

  private func showHintWhenDue() async {
    guard let deadline = hint.deadline else {
      hintVisible = false
      return
    }
    hintVisible = hint.isVisible(at: .now)
    guard !hintVisible else { return }
    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
    hintVisible = hint.isVisible(at: .now)
  }

  private var hintCard: some View {
    let hasTorch = capabilities?.hasTorch == true
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Image(systemName: "flashlight.on.fill")
          .font(.title2)
          .foregroundStyle(Color.origin89.action)
          .accessibilityHidden(true)
        Spacer()
        Button {
          hint.dismiss()
        } label: {
          Image(systemName: "xmark").foregroundStyle(Color.origin89.muted)
        }
        .accessibilityLabel("Dismiss")
      }
      Text("Can't scan the code?").font(.headline)
      Origin89Notice(
        hasTorch
          ? "Try turning on the flashlight for a better scan, or hold the phone a little farther from the label."
          : "Make sure the label is well lit, and hold the phone a little farther from it."
      )
      ViewThatFits(in: .horizontal) {
        HStack {
          Spacer()
          hintActions(hasTorch: hasTorch)
        }
        VStack(alignment: .trailing) { hintActions(hasTorch: hasTorch) }
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding()
    .background(
      Color.origin89.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    .padding(.horizontal)
    .padding(.bottom, 8)
  }

  @ViewBuilder private func hintActions(hasTorch: Bool) -> some View {
    Button("Enter the code instead", action: revealManual)
      .buttonStyle(.bordered)
    if hasTorch, !torchOn {
      Button("Turn on flashlight") {
        torchOn = true
        hint.dismiss()
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private func revealManual() {
    hint.dismiss()
    manualShown = true
  }

  // MARK: Manual entry

  @ViewBuilder private var manualSections: some View {
    Section {
      TextField("km43:1:…", text: $code, axis: .vertical)
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($codeFocused)
        .onChange(of: code) { refused = false }
        .id(Self.manualID)
      HStack {
        Button("Paste") { code = UIPasteboard.general.string ?? "" }
        if camera != .unavailable, !scannerOpen {
          Spacer()
          Button("Scan QR code", action: openScanner)
        }
      }
      .buttonStyle(.borderless)
    } header: {
      Text("Setup code")
    } footer: {
      if refused {
        Origin89Notice(CodeEntryMessage.refused, tone: .alarm)
      } else {
        Origin89Notice(
          "Paste the code printed on the controller's label. It is used once to pair and is not kept."
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
}

private struct OpenWindowView: View {
  let keptEnrolmentLost: Bool
  let opened: () -> Void
  var body: some View {
    SetupPage {
      VStack(alignment: .leading, spacing: 16) {
        Heading(text: "Open the pairing window")
        if keptEnrolmentLost {
          Origin89Notice(
            "This phone's earlier pairing no longer works with this controller, so it pairs again."
          )
        }
        Origin89Notice(
          "Press the pairing button on the controller's panel. The window stays open for 120 seconds, and pairing must finish inside it."
        )
        Button("The window is open, pair now", action: opened)
          .buttonStyle(.borderedProminent)
        Spacer()
      }
      .padding()
    }
  }
}

private struct PairingView: View {
  let state: SetupFlow.State
  let windowOpenedAt: Date?

  var body: some View {
    SetupPage {
      VStack(alignment: .leading, spacing: 20) {
        Heading(text: "Pairing")
        if let windowOpenedAt, state != .greeting {
          TimelineView(.periodic(from: windowOpenedAt, by: 1)) { context in
            let left = max(0, 120 - Int(context.date.timeIntervalSince(windowOpenedAt)))
            Text("Window closes in \(left / 60):\(String(format: "%02d", left % 60))")
              .font(.origin89Data)
              .monospacedDigit()
              .foregroundStyle(left > 20 ? Color.origin89.fg : Color.origin89.warning)
          }
        }
        Step(
          title: "Finding the controller", done: state != .discovering,
          active: state == .discovering)
        Step(title: "Proving the setup code", done: state == .greeting, active: state == .pairing)
        Step(title: "Opening a session", done: false, active: state == .greeting)
        Spacer()
      }
      .padding()
    }
  }
}

private struct Step: View {
  let title: String
  let done: Bool
  let active: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).foregroundStyle(done || active ? Color.origin89.fg : Color.origin89.muted)
      Origin89Status(
        done ? "Done" : active ? "In progress" : "Waiting",
        tone: done ? .nominal : active ? .info : .faint)
      if active { Origin89Loading(title) }
    }
  }
}

private struct WrittenView: View {
  let version: UInt32
  let flow: SetupFlow

  var body: some View {
    Form {
      Section {
        Text("Network settings saved")
        Origin89Status("Saved", tone: .nominal)
        Text(
          flow.reportsWiFi
            ? "The controller accepted version \(version) and passes it to its radio."
            : "The controller accepted version \(version) and passes it to its radio. Watch the module join the network."
        )
      }
      if flow.reportsWiFi { JoinSection(join: flow.join, flow: flow) }
      Section {
        Button("Set the controller's clock from this phone") { Task { await flow.setTime() } }
      } footer: {
        Text("Optional. The time is sent as a signed write, then setup finishes.")
      }
      Section {
        Button("Done") { Task { await flow.finish() } }
      } footer: {
        Text("Ends setup and disconnects. A controller accepts only two connections at once.")
      }
    }
  }
}

/// What the radio did with the written network, as the controller reports
/// it (P-219). The report is shown, never acted on (P-221).
private struct JoinSection: View {
  let join: SetupFlow.JoinWatch
  let flow: SetupFlow

  var body: some View {
    Section {
      switch join {
      case .idle:
        Button("Check whether the controller joined") { Task { await flow.watchJoinAgain() } }
      case .waiting:
        HStack(spacing: 12) {
          ProgressView()
          Text("Waiting for the controller to join the network…")
        }
      case .joined(let address):
        Origin89Status("Joined", tone: .nominal)
        Text("The controller is on the network at \(address).")
      case .failed(let reason):
        Origin89Status("Not joined", tone: .alarm)
        Origin89Notice(reason.message, tone: .alarm)
        Button("Choose another network or password") { Task { await flow.changeNetwork() } }
      case .noAnswer:
        Origin89Status("No answer", tone: .warning)
        Text("The controller has not said whether it joined the network.")
        Button("Check again") { Task { await flow.watchJoinAgain() } }
      }
    } header: {
      Text("Wi-Fi")
    }
  }
}

private struct FinishedView: View {
  let version: UInt32
  let timeSet: Bool
  let startOver: () -> Void
  var body: some View {
    SetupPage {
      VStack(alignment: .leading, spacing: 16) {
        Heading(text: "Setup finished")
        Origin89Status("Finished", tone: .nominal)
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
}

private struct FailureView: View {
  let message: String
  let retry: () -> Void
  let startOver: () -> Void
  var body: some View {
    SetupPage {
      VStack(alignment: .leading, spacing: 16) {
        Heading(text: "Setup stopped")
        Origin89Notice(message, tone: .alarm)
        HStack {
          Button("Try again", action: retry).buttonStyle(.borderedProminent)
          Button("Start over", action: startOver).buttonStyle(.bordered)
        }
        Spacer()
      }
      .padding()
    }
  }
}

/// Keeps short pages full-height and lets longer content scroll in compact layouts.
private struct SetupPage<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        content()
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
    }
  }
}
