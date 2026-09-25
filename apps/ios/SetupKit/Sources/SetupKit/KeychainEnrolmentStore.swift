import Foundation
import Security

/// Enrolments in the Keychain: this device only, readable only while it is
/// unlocked, never synced or restored to another phone. One generic-password
/// item per controller, its account the `device_id`. Enrolments made while
/// signed out share one service; each WorkOS account has its own below it.
public struct KeychainEnrolmentStore: EnrolmentStore {
  public struct Failure: Error, Sendable, Equatable {
    public let status: OSStatus
  }

  public static let signedOutService = "com.origin89.setup.enrolment"

  private let service: String

  public init(service: String = Self.signedOutService) { self.service = service }

  /// The enrolments made while `owner` was signed in.
  public init(owner: AccountID) { self.init(service: Self.signedOutService + "/" + owner.rawValue) }

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

  /// The `device_id` of every enrolment under this service, sorted.
  public func deviceIDs() -> [String] {
    var query = items()
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
    return (result as? [[String: Any]] ?? []).compactMap {
      $0[kSecAttrAccount as String] as? String
    }
    .sorted()
  }

  /// Every item under this service, including ones a previous install of
  /// the app left: Keychain items outlive an app delete.
  public func removeAll() throws { try delete(items()) }

  /// Every enrolment this app kept, signed out and under every account,
  /// including ones a previous install left.
  public static func removeEveryAccount() throws {
    try KeychainEnrolmentStore().removeAll()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecUseDataProtectionKeychain as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
    let services = Set(
      (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrService as String] as? String }
    )
    for service in services where service.hasPrefix(signedOutService + "/") {
      try KeychainEnrolmentStore(service: service).removeAll()
    }
  }

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
