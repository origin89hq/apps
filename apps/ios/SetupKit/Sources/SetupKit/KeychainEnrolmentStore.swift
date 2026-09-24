import Foundation
import Security

/// Enrolments in the Keychain: this device only, readable only while it is
/// unlocked, never synced or restored to another phone. One generic-password
/// item per controller, its account the `device_id`.
public struct KeychainEnrolmentStore: EnrolmentStore {
  public struct Failure: Error, Sendable, Equatable {
    public let status: OSStatus
  }

  private let service: String

  public init(service: String = "com.origin89.setup.enrolment") { self.service = service }

  public func load(deviceID: String) -> Data? {
    var query = item(deviceID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  public func save(_ enrolment: Data, deviceID: String) throws {
    try remove(deviceID: deviceID)
    var attributes = item(deviceID)
    attributes[kSecValueData as String] = enrolment
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  public func remove(deviceID: String) throws { try delete(item(deviceID)) }

  /// Every item under this service, including ones a previous install of
  /// the app left: Keychain items outlive an app delete.
  public func removeAll() throws { try delete(items()) }

  private func delete(_ query: [String: Any]) throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }

  private func item(_ deviceID: String) -> [String: Any] {
    var query = items()
    query[kSecAttrAccount as String] = deviceID
    return query
  }

  private func items() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}
