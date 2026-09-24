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
    let deleted = SecItemDelete(item(deviceID) as CFDictionary)
    guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
      throw Failure(status: deleted)
    }
    var attributes = item(deviceID)
    attributes[kSecValueData as String] = enrolment
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  private func item(_ deviceID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deviceID,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}
