import SetupCore
import SetupKit
import SwiftUI

@main
struct Origin89App: App {
  @State private var flow = SetupFlow(
    factory: RustControllerClientFactory(label: DeviceLabel.current),
    transportFactory: { BluetoothTransport(identifiers: .km43, codec: RustFragmentCodec()) })

  var body: some Scene {
    WindowGroup {
      SetupView(flow: flow)
    }
  }
}

/// The label this phone enrols under. The controller lists it, and a re-pair
/// with the same label reclaims the same row (P-078), so it is stable per
/// install and distinct between phones: the model plus a random suffix kept
/// in user defaults. `UIDevice.name` is not used; it is generic without an
/// entitlement.
enum DeviceLabel {
  private static let suffixKey = "setup.labelSuffix"

  @MainActor static var current: String {
    let defaults = UserDefaults.standard
    let suffix: String
    if let stored = defaults.string(forKey: suffixKey) {
      suffix = stored
    } else {
      suffix = String(UInt16.random(in: .min ... .max), radix: 16, uppercase: true)
      defaults.set(suffix, forKey: suffixKey)
    }
    return "\(UIDevice.current.model) \(suffix)"
  }
}
