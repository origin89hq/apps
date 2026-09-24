import CoreLocation
import NetworkExtension

/// The Wi-Fi network this phone is on, offered as a suggestion. iOS gives an
/// app nothing else: no list of nearby networks, and the current one only
/// with the Access Wi-Fi Information entitlement and location permission.
/// Without either, the answer is nil and the person picks another way.
@MainActor final class PhoneWiFi: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var authorized: CheckedContinuation<Void, Never>?

  func currentSSID() async -> String? {
    if manager.authorizationStatus == .notDetermined {
      manager.delegate = self
      await withCheckedContinuation { continuation in
        authorized = continuation
        manager.requestWhenInUseAuthorization()
      }
    }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: return await Self.fetch()
    case .notDetermined, .denied, .restricted: return nil
    @unknown default: return nil
    }
  }

  private nonisolated static func fetch() async -> String? {
    await NEHotspotNetwork.fetchCurrent()?.ssid
  }

  /// Also called when the delegate is set, still undetermined; only an
  /// answer ends the wait.
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    MainActor.assumeIsolated {
      guard self.manager.authorizationStatus != .notDetermined else { return }
      authorized?.resume()
      authorized = nil
    }
  }
}
