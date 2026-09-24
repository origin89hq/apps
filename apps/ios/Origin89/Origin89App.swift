import SetupCore
import SetupKit
import SwiftUI

@main
struct Origin89App: App {
  @State private var flow = SetupFlow(
    factory: RustControllerClientFactory(label: DeviceLabel.current),
    store: KeychainEnrolmentStore(),
    transportFactory: { BluetoothTransport(identifiers: .km43, codec: RustFragmentCodec()) })

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
