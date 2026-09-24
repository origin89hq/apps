@preconcurrency import AVFoundation
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

/// Scans the setup code and hands it to `submit`, the same path paste uses.
/// A refused code keeps the sheet open so the person can scan again.
struct CodeScannerSheet: View {
  let submit: (String) throws(SetupCodeError) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var refused = false
  @State private var attempt = 0
  @State private var cameraFailed = false

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottom) {
        QRCameraView(attempt: attempt) { code in
          do {
            try submit(code)
            dismiss()
          } catch {
            refused = true
          }
        } failed: {
          cameraFailed = true
        }
        .ignoresSafeArea(edges: .bottom)
        status
          .padding()
          .frame(maxWidth: .infinity)
          .background(.regularMaterial)
      }
      .navigationTitle("Scan setup code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
  }

  @ViewBuilder private var status: some View {
    if cameraFailed {
      Text("The camera could not start. Paste the code instead.")
    } else if refused {
      VStack(spacing: 12) {
        Text(CodeEntryMessage.refused).foregroundStyle(Palette.color(\.alarm))
        Button("Scan again") {
          refused = false
          attempt += 1
        }
        .buttonStyle(.borderedProminent)
      }
    } else {
      Text("Point the camera at the QR code on the controller's label.")
    }
  }
}

/// The camera preview. Each new `attempt` rearms the scanner after a refusal.
private struct QRCameraView: UIViewControllerRepresentable {
  let attempt: Int
  let scanned: (String) -> Void
  let failed: () -> Void

  func makeUIViewController(context: Context) -> QRScannerController {
    QRScannerController(scanned: scanned, failed: failed)
  }

  func updateUIViewController(_ controller: QRScannerController, context: Context) {
    controller.scanned = scanned
    controller.failed = failed
    controller.rescan(attempt: attempt)
  }

  static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) {
    controller.stop()
  }
}

private final class QRScannerController: UIViewController {
  var scanned: (String) -> Void
  var failed: () -> Void
  private var gate = ScanGate()
  private var attempt = 0
  private let capture = CaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?

  init(scanned: @escaping (String) -> Void, failed: @escaping () -> Void) {
    self.scanned = scanned
    self.failed = failed
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
    capture.start(delegate: delegate) { [weak self] configured in
      if !configured { self?.failed() }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  func rescan(attempt: Int) {
    guard attempt != self.attempt else { return }
    self.attempt = attempt
    gate.rearm()
    capture.resume()
  }

  func stop() { capture.stop() }

  private func receive(_ string: String) {
    guard let code = gate.pass(string) else { return }
    capture.stop()
    scanned(code)
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

  /// Configure the camera for QR codes only and start it. `configured` runs
  /// on the main actor.
  func start(
    delegate: MetadataDelegate, configured: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    queue.async { [self] in
      let ok = configure(delegate: delegate)
      if ok { session.startRunning() }
      Task { @MainActor in configured(ok) }
    }
  }

  func resume() {
    queue.async { [self] in
      if delegate != nil, !session.isRunning { session.startRunning() }
    }
  }

  func stop() {
    queue.async { [self] in
      if session.isRunning { session.stopRunning() }
    }
  }

  private func configure(delegate: MetadataDelegate) -> Bool {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera)
    else { return false }
    let output = AVCaptureMetadataOutput()
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input), session.canAddOutput(output) else { return false }
    session.addInput(input)
    session.addOutput(output)
    guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
    output.setMetadataObjectsDelegate(delegate, queue: queue)
    output.metadataObjectTypes = [.qr]
    self.delegate = delegate
    return true
  }
}
