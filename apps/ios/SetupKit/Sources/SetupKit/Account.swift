import Foundation
import Observation

/// A WorkOS user ID. It scopes the enrolments made while that user is signed in.
public struct AccountID: Hashable, Sendable, Codable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct AccountUser: Sendable, Equatable, Codable {
  public let id: AccountID
  public let email: String
  public let firstName: String?
  public let lastName: String?
  public init(id: AccountID, email: String, firstName: String? = nil, lastName: String? = nil) {
    self.id = id
    self.email = email
    self.firstName = firstName
    self.lastName = lastName
  }
}

/// What WorkOS returns on sign-in and refresh, and what the Keychain keeps.
public struct AccountSession: Sendable, Equatable, Codable {
  public let user: AccountUser
  public let accessToken: String
  public let refreshToken: String
  public init(user: AccountUser, accessToken: String, refreshToken: String) {
    self.user = user
    self.accessToken = accessToken
    self.refreshToken = refreshToken
  }

  /// When the access token expires, from its `exp` claim. Nil when the token
  /// cannot be read, which the account treats as expired. The signature is
  /// the cloud's to check; the app only decides when to refresh.
  var accessTokenExpiry: Date? {
    let parts = accessToken.split(separator: ".")
    guard parts.count == 3, let payload = Base64URL.decode(parts[1]),
      let claims = try? JSONDecoder().decode(Claims.self, from: payload)
    else { return nil }
    return Date(timeIntervalSince1970: claims.exp)
  }

  private struct Claims: Decodable { let exp: TimeInterval }
}

public enum AccountError: Error, Sendable, Equatable {
  /// This build has no WorkOS client ID.
  case notConfigured
  /// The person closed the sign-in sheet.
  case cancelled
  /// No session is signed in.
  case signedOut
  /// WorkOS could not be reached, or answered with a server error.
  case unavailable
  /// WorkOS refused the sign-in or the refresh token.
  case refused
  /// The redirect or WorkOS's answer was not what AuthKit sends.
  case invalidResponse
  case keychain(OSStatus)

  public var message: String {
    switch self {
    case .notConfigured: "This build of the app has no sign-in configured."
    case .cancelled: "Sign-in was cancelled."
    case .signedOut: "Sign in to continue."
    case .unavailable:
      "The sign-in service could not be reached. Check the connection and try again."
    case .refused: "Sign-in was refused. Try again."
    case .invalidResponse: "The sign-in service sent an unexpected answer. Try again."
    case .keychain: "This phone could not store or remove the sign-in in its Keychain."
    }
  }
}

/// Where the session is kept between launches.
public protocol AccountSessionStore: Sendable {
  func load() -> AccountSession?
  func save(_ session: AccountSession) throws(AccountError)
  func remove() throws(AccountError)
}

/// Optional sign-in. Nothing in setup waits for it: enrolments, pairing and
/// the controller's network work the same signed in or out. Signing in or out
/// changes which account's enrolments the app shows, never the enrolments.
@Observable @MainActor public final class Account {
  public enum Status: Sendable, Equatable {
    case signedOut, signingIn
    case signedIn(AccountUser)
  }

  public private(set) var status: Status
  /// WorkOS refused the refresh token, so the session ended here. Cleared by
  /// the next sign-in.
  public private(set) var sessionEnded = false
  /// The signed-in user, whose enrolments the app shows.
  public var owner: AccountID? {
    if case .signedIn(let user) = status { user.id } else { nil }
  }
  public var isAvailable: Bool { client != nil }

  private let client: AuthKitClient?
  private let store: any AccountSessionStore
  private let now: @Sendable () -> Date
  private var session: AccountSession?
  private var refreshing: Task<AccountSession, any Error>?
  /// Bumped by sign-out, so a refresh in flight cannot bring the session back.
  private var generation = 0

  /// A session is refreshed this long before its access token expires.
  private static let refreshMargin: TimeInterval = 60

  public init(
    client: AuthKitClient?, store: any AccountSessionStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.store = store
    self.now = now
    let session = store.load()
    self.session = session
    status = session.map { .signedIn($0.user) } ?? .signedOut
  }

  /// Sign in through the AuthKit page. `authenticate` presents it and returns
  /// the redirect to `AuthKitConfiguration.callbackScheme`.
  public func signIn(
    using authenticate: (URL, String) async throws(AccountError) -> URL
  ) async throws(AccountError) {
    guard let client else { throw .notConfigured }
    guard status == .signedOut else { return }
    status = .signingIn
    defer { if status == .signingIn { status = .signedOut } }
    let pkce = PKCE.random()
    let state = Base64URL.random(bytes: 16)
    guard let url = client.authorizationURL(challenge: pkce.challenge, state: state) else {
      throw .invalidResponse
    }
    let callback = try await authenticate(url, AuthKitConfiguration.callbackScheme)
    let code = try Self.code(from: callback, state: state)
    let session = try await client.authenticate(code: code, verifier: pkce.verifier)
    try store.save(session)
    self.session = session
    sessionEnded = false
    status = .signedIn(session.user)
    SetupLog.account.info("signed in")
  }

  /// Remove the session from this phone. Enrolments are not touched. When the
  /// Keychain keeps the session, the error is thrown and the account stays
  /// signed in.
  public func signOut() throws(AccountError) {
    guard session != nil else { return }
    try store.remove()
    generation += 1
    refreshing?.cancel()
    refreshing = nil
    session = nil
    status = .signedOut
    SetupLog.account.info("signed out")
  }

  /// An access token valid for at least a minute, refreshed when needed.
  /// A refused refresh ends the session; an unreachable WorkOS keeps it.
  public func accessToken() async throws(AccountError) -> String {
    guard let session else { throw .signedOut }
    if let expiry = session.accessTokenExpiry,
      expiry.timeIntervalSince(now()) > Self.refreshMargin
    {
      return session.accessToken
    }
    return try await refresh().accessToken
  }

  /// At launch: refresh an expired session, ending it if WorkOS refuses.
  /// Offline, the session stays until a refresh can reach WorkOS.
  public func refreshIfExpired() async {
    _ = try? await accessToken()
  }

  /// One refresh at a time: WorkOS rotates the refresh token, so a second
  /// concurrent refresh with the old token would be refused.
  private func refresh() async throws(AccountError) -> AccountSession {
    guard let client, let session else { throw .signedOut }
    let operation = generation
    let task: Task<AccountSession, any Error>
    if let refreshing {
      task = refreshing
    } else {
      let refreshToken = session.refreshToken
      task = Task { try await client.refresh(refreshToken) }
      refreshing = task
    }
    let result = await task.result
    if refreshing == task { refreshing = nil }
    guard generation == operation else { throw .signedOut }
    switch result {
    case .success(let refreshed):
      guard self.session != refreshed else { return refreshed }
      self.session = refreshed
      status = .signedIn(refreshed.user)
      do {
        try store.save(refreshed)
      } catch {
        // The kept refresh token is spent: the next launch signs in again.
        SetupLog.account.error("the refreshed session could not be kept")
      }
      return refreshed
    case .failure(let error):
      let error = error as? AccountError ?? .unavailable
      if error == .refused { endSession() }
      throw error
    }
  }

  private func endSession() {
    SetupLog.account.notice("WorkOS refused the refresh token: the session ended")
    do {
      try store.remove()
    } catch {
      SetupLog.account.error("the ended session could not be removed from the Keychain")
    }
    generation += 1
    session = nil
    sessionEnded = true
    status = .signedOut
  }

  /// The code from AuthKit's redirect, once its `state` matches.
  static func code(from callback: URL, state: String) throws(AccountError) -> String {
    guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
    else { throw .invalidResponse }
    let value = { (name: String) in items.first { $0.name == name }?.value }
    guard value("state") == state else { throw .invalidResponse }
    if value("error") != nil { throw .refused }
    guard let code = value("code"), !code.isEmpty else { throw .invalidResponse }
    return code
  }
}
