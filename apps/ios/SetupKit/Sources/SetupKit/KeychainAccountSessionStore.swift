import Foundation
import Security

/// The WorkOS session in the Keychain: this device only, readable only while
/// it is unlocked, never synced or restored to another phone.
public struct KeychainAccountSessionStore: AccountSessionStore {
  private let service: String

  public init(service: String = "com.origin89.account.session") { self.service = service }

  public func load() -> AccountSession? {
    var query = item()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(AccountSession.self, from: data)
  }

  public func save(_ session: AccountSession) throws(AccountError) {
    let data: Data
    do {
      data = try JSONEncoder().encode(session)
    } catch {
      throw .invalidResponse
    }
    try remove()
    var attributes = item()
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw .keychain(added) }
  }

  public func remove() throws(AccountError) {
    let status = SecItemDelete(item() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw .keychain(status)
    }
  }

  private func item() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "workos",
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}
