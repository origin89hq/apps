import SetupCore
import SetupKit
import SwiftUI
import os

@main
struct Origin89App: App {
  @State private var flow = Self.makeFlow()

  @MainActor private static func makeFlow() -> SetupFlow {
    let store = KeychainEnrolmentStore()
    // Keychain items outlive an app delete; user defaults do not. A launch
    // with no label suffix yet is a new install: drop what an old one kept.
    // A failed removal is tried again on each launch until it succeeds, which
    // then also drops any enrolment made in between.
    let defaults = UserDefaults.standard
    let pendingKey = "setup.clearPreviousInstall"
    if DeviceLabel.isNewInstall { defaults.set(true, forKey: pendingKey) }
    if defaults.bool(forKey: pendingKey) {
      do {
        try store.removeAll()
        defaults.removeObject(forKey: pendingKey)
      } catch {
        Logger(subsystem: SetupLog.subsystem, category: "flow").error(
          "could not remove enrolments left from a previous install: \(String(describing: error), privacy: .public)"
        )
      }
    }
    return SetupFlow(
      factory: RustControllerClientFactory(label: DeviceLabel.current),
      store: store,
      transportFactory: { BluetoothTransport(identifiers: .km43, codec: RustFragmentCodec()) },
      lastController: DefaultsLastController(),
      webSocketFactory: { WebSocketTransport.km43(address: $0) },
      addresses: DefaultsControllerAddresses(),
      browser: NetworkControllerBrowser.km43())
  }

  var body: some Scene {
    WindowGroup {
      SetupView(flow: flow)
    }
  }
}

/// The label this phone enrols under (see `EnrolmentLabel`). It is stable
/// per install: the random suffix is kept in user defaults. A suffix stored by
/// an earlier build (up to 4 hex digits) keeps working; new installs get 8.
/// `UIDevice.name` is not used; it is generic without an entitlement.
enum DeviceLabel {
  private static let suffixKey = "setup.labelSuffix"

  /// True until `current` stores this install's suffix.
  static var isNewInstall: Bool { UserDefaults.standard.string(forKey: suffixKey) == nil }

  @MainActor static var current: String {
    let defaults = UserDefaults.standard
    let suffix: String
    if let stored = defaults.string(forKey: suffixKey) {
      suffix = stored
    } else {
      suffix = EnrolmentLabel.suffix(UInt32.random(in: .min ... .max))
      defaults.set(suffix, forKey: suffixKey)
    }
    return EnrolmentLabel.label(model: UIDevice.current.model, suffix: suffix)
  }
}
