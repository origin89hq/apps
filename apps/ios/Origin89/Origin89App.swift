import SetupCore
import SetupKit
import SwiftUI
import os

@main
struct Origin89App: App {
  @State private var account: Account
  @State private var flow: SetupFlow
  private let cloud: CloudClient?

  @MainActor init() {
    Self.clearPreviousInstall()
    let account = Account(
      client: Self.authKit.map { AuthKitClient(configuration: $0) },
      store: KeychainAccountSessionStore())
    _account = State(initialValue: account)
    cloud = Self.cloudConfiguration.map { CloudClient(configuration: $0, account: account) }
    _flow = State(initialValue: Self.makeFlow(owner: account.owner))
  }

  /// Keychain items outlive an app delete; user defaults do not. A launch
  /// with no label suffix yet is a new install: drop the enrolments and the
  /// session an old one kept. A failed removal is tried again on each launch
  /// until it succeeds, which then also drops any enrolment made in between.
  @MainActor private static func clearPreviousInstall() {
    let defaults = UserDefaults.standard
    let pendingKey = "setup.clearPreviousInstall"
    if DeviceLabel.isNewInstall { defaults.set(true, forKey: pendingKey) }
    guard defaults.bool(forKey: pendingKey) else { return }
    do {
      try KeychainEnrolmentStore.removeEveryAccount()
      try KeychainAccountSessionStore().remove()
      defaults.removeObject(forKey: pendingKey)
    } catch {
      Logger(subsystem: SetupLog.subsystem, category: "flow").error(
        "could not remove what a previous install kept: \(String(describing: error), privacy: .public)"
      )
    }
  }

  private static var authKit: AuthKitConfiguration? {
    let clientID = Bundle.main.object(forInfoDictionaryKey: "WorkOSClientID") as? String
    return clientID.flatMap { AuthKitConfiguration(clientID: $0) }
  }

  private static var cloudConfiguration: CloudConfiguration? {
    let baseURL = Bundle.main.object(forInfoDictionaryKey: "CloudBaseURL") as? String
    return baseURL.flatMap { CloudConfiguration(baseURL: $0) }
  }

  nonisolated private static func lastController(owner: AccountID?) -> DefaultsLastController {
    DefaultsLastController(
      key: owner.map { "setup.lastController.\($0.rawValue)" } ?? "setup.lastController")
  }

  private static let pairings = KeychainAccountPairings(
    signedOutLast: lastController(owner: nil), accountLast: { lastController(owner: $0) })

  /// The flow for `owner`'s enrolments: signed out, those made signed out;
  /// signed in, the account's own too. Each keeps its own last controller.
  @MainActor private static func makeFlow(owner: AccountID?) -> SetupFlow {
    let signedOut = KeychainEnrolmentStore()
    let store: any EnrolmentStore =
      owner.map {
        AccountEnrolmentStore(own: KeychainEnrolmentStore(owner: $0), signedOut: signedOut)
      } ?? signedOut
    let lastController = lastController(owner: owner)
    return SetupFlow(
      factory: RustControllerClientFactory(label: DeviceLabel.current),
      store: store,
      transportFactory: { BluetoothTransport(identifiers: .km43, codec: RustFragmentCodec()) },
      lastController: lastController,
      webSocketFactory: { WebSocketTransport.km43(address: $0) },
      addresses: DefaultsControllerAddresses(),
      browser: NetworkControllerBrowser.km43())
  }

  var body: some Scene {
    WindowGroup {
      SetupView(flow: flow, account: account, cloud: cloud, pairings: Self.pairings)
        .id(ObjectIdentifier(flow))
        .task { await account.refreshIfExpired() }
        // Another account sees other enrolments: close this flow's connection
        // first, then start the account's own flow.
        .onChange(of: account.owner) { _, owner in
          let previous = flow
          Task {
            await previous.suspend()
            flow = Self.makeFlow(owner: owner)
          }
        }
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
