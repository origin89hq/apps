@preconcurrency import AVFoundation
import Origin89UI
import SetupKit
import SwiftUI
import UIKit

/// Camera access for scanning, as the enter-code screen needs it.
enum CameraAccess {
  case unavailable, notDetermined, allowed, denied, restricted

  /// A phone without a camera, and the simulator, cannot scan.
  static var current: CameraAccess {
    guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined: return .notDetermined
    case .authorized: return .allowed
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .denied
    }
  }

  static func request() async -> CameraAccess {
    _ = await AVCaptureDevice.requestAccess(for: .video)
    return current
  }
}

/// What the running camera can do; the card shows only the controls it supports.
struct CameraCapabilities: Sendable, Equatable {
  var hasTorch: Bool
  /// The zoom the zoom button switches to: about 2x, never past the device maximum.
  var zoomedFactor: CGFloat

  var canZoom: Bool { zoomedFactor > 1 }
}

/// The square the corner brackets mark and the only area scanned for codes.
enum Viewfinder {
  static func rect(in bounds: CGRect) -> CGRect {
    let side = min(bounds.width, bounds.height) * 0.68
    return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
  }
}

/// The live camera in a rounded card: corner brackets, torch and zoom buttons,
/// and a banner when a scanned code is refused. `scanned` returns whether the
/// code was accepted; after a refusal the scanner rearms itself.
struct ScannerCard: View {
  let torchOn: Bool
  let zoomed: Bool
  let capabilities: CameraCapabilities?
  let refused: Bool
  let failed: Bool
  let toggleTorch: () -> Void
  let toggleZoom: () -> Void
  let ready: (CameraCapabilities?) -> Void
  let scanned: (String) -> Bool

  var body: some View {
    CameraCard {
      if failed {
        CardMessage(text: "The camera could not start. Enter the code manually instead.")
      } else {
        ZStack {
          QRCameraView(
            torchOn: torchOn,
            zoomFactor: zoomed ? (capabilities?.zoomedFactor ?? 1) : 1,
            ready: ready, scanned: scanned
          )
          .accessibilityLabel("Camera viewfinder")
          CornerBrackets()
            .stroke(
              Color.origin89.onFill, style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .accessibilityHidden(true)
          overlays
        }
      }
    }
  }

  private var overlays: some View {
    VStack {
      if refused {
        Text(CodeEntryMessage.refused)
          .font(.origin89Label)
          .foregroundStyle(Color.origin89.onFill)
          .padding(12)
          .background(Color.origin89.alarmDeep, in: RoundedRectangle(cornerRadius: 12))
          .padding(12)
          .transition(.opacity)
      }
      Spacer()
      HStack {
        if capabilities?.hasTorch == true {
          RoundButton(
            systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill", lit: torchOn,
            action: toggleTorch
          )
          .accessibilityLabel("Flashlight")
          .accessibilityValue(torchOn ? "On" : "Off")
        }
        Spacer()
        if let capabilities, capabilities.canZoom {
          RoundButton(
            systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", lit: zoomed,
            action: toggleZoom
          )
          .accessibilityLabel("Zoom")
          .accessibilityValue(zoomed ? Self.zoomText(capabilities.zoomedFactor) : "1x")
        }
      }
      .padding(12)
    }
    .animation(.default, value: refused)
  }

  private static func zoomText(_ factor: CGFloat) -> String {
    "\(Double(factor).formatted(.number.precision(.fractionLength(0...1))))x"
  }
}

/// The rounded frame the camera, or a message in its place, sits in.
struct CameraCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .frame(maxWidth: 360)
      .aspectRatio(3 / 4, contentMode: .fit)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .frame(maxWidth: .infinity)
  }
}

/// Text shown in the card in place of the camera.
struct CardMessage<Actions: View>: View {
  let text: String
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "camera.fill")
        .font(.largeTitle)
        .foregroundStyle(Color.origin89.muted)
        .accessibilityHidden(true)
      Text(text)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.origin89.onFill)
      actions()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension CardMessage where Actions == EmptyView {
  init(text: String) { self.init(text: text) { EmptyView() } }
}

private struct CornerBrackets: Shape {
  func path(in rect: CGRect) -> Path {
    let frame = Viewfinder.rect(in: rect)
    let arm = frame.width * 0.18
    var path = Path()
    for (corner, dx, dy) in [
      (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
      (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
      (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
      (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
    ] {
      path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
      path.addLine(to: corner)
      path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    return path
  }
}

private struct RoundButton: View {
  let systemImage: String
  let lit: Bool
  let action: () -> Void

  @ScaledMetric(relativeTo: .body) private var size = 48

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(lit ? Color.origin89.action : Color.origin89.onFill)
        .frame(width: size, height: size)
        .background(
          lit ? AnyShapeStyle(Color.origin89.onFill) : AnyShapeStyle(.black.opacity(0.5)),
          in: Circle())
    }
    .buttonStyle(.plain)
  }
}

/// The camera preview. It pushes torch and zoom changes to the capture session.
private struct QRCameraView: UIViewControllerRepresentable {
  let torchOn: Bool
  let zoomFactor: CGFloat
  let ready: (CameraCapabilities?) -> Void
  let scanned: (String) -> Bool

  func makeUIViewController(context: Context) -> QRScannerController {
    QRScannerController(ready: ready, scanned: scanned)
  }

  func updateUIViewController(_ controller: QRScannerController, context: Context) {
    controller.ready = ready
    controller.scanned = scanned
    controller.apply(torchOn: torchOn, zoomFactor: zoomFactor)
  }

  static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) {
    controller.stop()
  }
}

private final class QRScannerController: UIViewController {
  /// How long a refused code keeps the scanner paused before it rearms.
  private static let rearmDelay = Duration.seconds(1.5)

  var ready: (CameraCapabilities?) -> Void
  var scanned: (String) -> Bool
  private var gate = ScanGate()
  private var running = false
  private var stopped = false
  private let capture = CaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?
  private var torchOn = false
  private var zoomFactor: CGFloat = 1

  init(ready: @escaping (CameraCapabilities?) -> Void, scanned: @escaping (String) -> Bool) {
    self.ready = ready
    self.scanned = scanned
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let preview = AVCaptureVideoPreviewLayer(session: capture.session)
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    self.preview = preview
    let delegate = MetadataDelegate { [weak self] string in self?.receive(string) }
    capture.start(delegate: delegate) { [weak self] capabilities in
      guard let self, !stopped else { return }
      running = capabilities != nil
      if running {
        updateRectOfInterest()
        capture.set(torchOn: torchOn, zoomFactor: zoomFactor)
      }
      ready(capabilities)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
    updateRectOfInterest()
  }

  func apply(torchOn: Bool, zoomFactor: CGFloat) {
    guard torchOn != self.torchOn || zoomFactor != self.zoomFactor else { return }
    self.torchOn = torchOn
    self.zoomFactor = zoomFactor
    if running { capture.set(torchOn: torchOn, zoomFactor: zoomFactor) }
  }

  func stop() {
    stopped = true
    running = false
    capture.stop()
  }

  /// Limit detection to the bracketed square. The conversion needs a running
  /// session and a laid-out preview.
  private func updateRectOfInterest() {
    guard running, let preview, !view.bounds.isEmpty else { return }
    let area = preview.metadataOutputRectConverted(fromLayerRect: Viewfinder.rect(in: view.bounds))
    capture.setRectOfInterest(area)
  }

  private func receive(_ string: String) {
    guard running, let code = gate.pass(string) else { return }
    if scanned(code) {
      stop()
    } else {
      Task { [weak self] in
        try? await Task.sleep(for: Self.rearmDelay)
        self?.gate.rearm()
      }
    }
  }
}

/// Reads QR codes on the capture queue and hands their strings to the main actor.
private final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate, Sendable {
  private let deliver: @MainActor @Sendable (String) -> Void

  init(deliver: @escaping @MainActor @Sendable (String) -> Void) {
    self.deliver = deliver
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let strings = metadataObjects.compactMap { object in
      (object as? AVMetadataMachineReadableCodeObject).flatMap {
        $0.type == .qr ? $0.stringValue : nil
      }
    }
    guard let string = strings.first else { return }
    let deliver = deliver
    Task { @MainActor in deliver(string) }
  }
}

/// Owns the capture session and runs every call on one serial queue:
/// `startRunning` blocks, and the session is not safe to use from several
/// threads at once.
private final class CaptureSession: @unchecked Sendable {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "com.origin89.apps.ios.qr-capture")
  private var delegate: MetadataDelegate?
  private var camera: AVCaptureDevice?
  private let output = AVCaptureMetadataOutput()

  /// Configure the camera for QR codes only and start it. `configured` runs
  /// on the main actor with what the camera supports, or nil when it failed.
  func start(
    delegate: MetadataDelegate,
    configured: @escaping @MainActor @Sendable (CameraCapabilities?) -> Void
  ) {
    queue.async { [self] in
      let capabilities = configure(delegate: delegate)
      if capabilities != nil { session.startRunning() }
      Task { @MainActor in configured(capabilities) }
    }
  }

  /// Set the torch and zoom, clamped to what the camera supports.
  func set(torchOn: Bool, zoomFactor: CGFloat) {
    queue.async { [self] in
      guard let camera, session.isRunning, (try? camera.lockForConfiguration()) != nil else {
        return
      }
      defer { camera.unlockForConfiguration() }
      if camera.hasTorch, camera.isTorchAvailable {
        camera.torchMode = torchOn ? .on : .off
      }
      camera.videoZoomFactor = min(
        max(zoomFactor, camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
    }
  }

  func setRectOfInterest(_ area: CGRect) {
    queue.async { [self] in output.rectOfInterest = area }
  }

  /// Turn the torch off and stop the camera.
  func stop() {
    queue.async { [self] in
      if let camera, camera.hasTorch, camera.torchMode != .off,
        (try? camera.lockForConfiguration()) != nil
      {
        camera.torchMode = .off
        camera.unlockForConfiguration()
      }
      if session.isRunning { session.stopRunning() }
    }
  }

  private func configure(delegate: MetadataDelegate) -> CameraCapabilities? {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera)
    else { return nil }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
    session.addInput(input)
    session.addOutput(output)
    guard output.availableMetadataObjectTypes.contains(.qr) else { return nil }
    output.setMetadataObjectsDelegate(delegate, queue: queue)
    output.metadataObjectTypes = [.qr]
    self.delegate = delegate
    self.camera = camera
    return CameraCapabilities(
      hasTorch: camera.hasTorch, zoomedFactor: min(2, camera.maxAvailableVideoZoomFactor))
  }
}
