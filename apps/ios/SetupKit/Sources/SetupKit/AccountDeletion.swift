import Foundation

/// What a deleted account's pairings become on this phone.
public enum DeletedPairings: Sendable, Equatable {
  /// They become signed-out pairings, which every account on this phone uses.
  case keep
  /// They are removed, and each controller needs its setup code again.
  case forget
}

/// The pairings kept for one account, handed over when it is deleted.
public protocol AccountPairingStore: Sendable {
  /// Make `owner`'s pairings signed-out ones. One replaces a signed-out
  /// pairing for the same controller, since it is the newer.
  func keep(_ owner: AccountID) throws
  /// Remove `owner`'s pairings.
  func forget(_ owner: AccountID) throws
}

public enum AccountDeletion: Sendable, Equatable {
  case deleted
  /// The account was deleted and signed out, but its pairings could not be
  /// kept or removed. They stay hidden under the deleted account.
  case pairingsLeft
}

extension CloudClient {
  /// Delete the signed-in account in the cloud (`DELETE /v1/account`), then
  /// hand its pairings over as the person chose and sign out. A stale sign-in
  /// asks the person to sign in again through `authenticate`, then retries
  /// once. Nothing on this phone changes until the cloud confirms.
  public func deleteAccount(
    pairings: DeletedPairings, store: any AccountPairingStore,
    authenticate: (URL, String) async throws(AccountError) -> URL
  ) async throws(CloudError) -> AccountDeletion {
    guard let owner = account.owner else { throw .account(.signedOut) }
    do {
      try await send(.delete, "/v1/account")
    } catch .reauthenticationRequired {
      // Another account signed in meanwhile: never delete it instead.
      guard account.owner == owner else { throw .account(.differentAccount) }
      do {
        try await account.reauthenticate(using: authenticate)
      } catch {
        throw .account(error)
      }
      guard account.owner == owner else { throw .account(.differentAccount) }
      try await send(.delete, "/v1/account")
    }
    // Deleted in the cloud: the person may have signed out meanwhile.
    var outcome = AccountDeletion.deleted
    do {
      switch pairings {
      case .keep: try store.keep(owner)
      case .forget: try store.forget(owner)
      }
    } catch {
      SetupLog.account.error(
        "the deleted account's pairings could not be handed over: \(String(describing: error), privacy: .public)"
      )
      outcome = .pairingsLeft
    }
    if account.owner == owner { account.endDeletedSession() }
    return outcome
  }
}

/// Pairings in the Keychain, with each scope's last controller.
public struct KeychainAccountPairings: AccountPairingStore {
  private let signedOutLast: any LastControllerStore
  private let accountLast: @Sendable (AccountID) -> any LastControllerStore

  public init(
    signedOutLast: any LastControllerStore,
    accountLast: @escaping @Sendable (AccountID) -> any LastControllerStore
  ) {
    self.signedOutLast = signedOutLast
    self.accountLast = accountLast
  }

  public func keep(_ owner: AccountID) throws {
    let own = KeychainEnrolmentStore(owner: owner)
    let signedOut = KeychainEnrolmentStore()
    for deviceID in try own.storedDeviceIDs() {
      // Unreadable, as while the phone is locked: keep it rather than lose it.
      guard let enrolment = own.load(deviceID: deviceID) else {
        throw KeychainEnrolmentStore.Failure(status: errSecInteractionNotAllowed)
      }
      try signedOut.save(enrolment, deviceID: deviceID)
    }
    try own.removeAll()
    // Relaunching signed out reconnects to the account's last controller
    // when no signed-out one is remembered.
    let last = accountLast(owner)
    if signedOutLast.load() == nil, let deviceID = last.load() { signedOutLast.save(deviceID) }
    last.save(nil)
  }

  public func forget(_ owner: AccountID) throws {
    try KeychainEnrolmentStore(owner: owner).removeAll()
    accountLast(owner).save(nil)
  }
}
