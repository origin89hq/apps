import Foundation

/// The enrolments one signed-in account uses: its own, then those made while
/// signed out. Another account's enrolments are neither read nor changed, so
/// signing out or switching accounts leaves every enrolment in place.
///
/// New enrolments are kept for the account. Forgetting removes what the
/// account can see: its own and the signed-out one for the same controller.
public struct AccountEnrolmentStore: EnrolmentStore {
  private let own: any EnrolmentStore
  private let signedOut: any EnrolmentStore

  public init(own: any EnrolmentStore, signedOut: any EnrolmentStore) {
    self.own = own
    self.signedOut = signedOut
  }

  public func load(deviceID: String) -> Data? {
    own.load(deviceID: deviceID) ?? signedOut.load(deviceID: deviceID)
  }

  public func save(_ enrolment: Data, deviceID: String) throws {
    try own.save(enrolment, deviceID: deviceID)
  }

  /// Both removals are tried; the first error is thrown.
  public func remove(deviceID: String) throws {
    try Self.both(
      { try own.remove(deviceID: deviceID) }, { try signedOut.remove(deviceID: deviceID) })
  }

  public func removeAll() throws {
    try Self.both({ try own.removeAll() }, { try signedOut.removeAll() })
  }

  private static func both(_ first: () throws -> Void, _ second: () throws -> Void) throws {
    var failure: (any Error)?
    do { try first() } catch { failure = error }
    do { try second() } catch { failure = failure ?? error }
    if let failure { throw failure }
  }
}
