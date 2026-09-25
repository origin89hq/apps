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

  /// Replaces an existing entry in place, so a failed save leaves the older
  /// one as it was.
  public func save(_ enrolment: Data, deviceID: String) throws {
    let changes: [String: Any] = [
      kSecValueData as String: enrolment,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updated = SecItemUpdate(item(deviceID) as CFDictionary, changes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure(status: updated) }
    let added = SecItemAdd(item(deviceID).merging(changes) { $1 } as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  public func remove(deviceID: String) throws { try delete(item(deviceID)) }

  /// The `device_id` of every enrolment under this service, sorted; none
  /// when the Keychain cannot be read.
  public func deviceIDs() -> [String] { (try? storedDeviceIDs()) ?? [] }

  /// The `device_id` of every enrolment under this service, sorted. Throws
  /// when the Keychain cannot be read, as while the phone is locked, rather
  /// than answering none.
  public func storedDeviceIDs() throws -> [String] {
    var query = items()
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw Failure(status: status) }
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
