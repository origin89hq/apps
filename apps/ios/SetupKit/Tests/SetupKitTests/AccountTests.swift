import CryptoKit
import Foundation
import Testing

@testable import SetupKit

/// Answers WorkOS requests in order and records them.
final class StubHTTP: HTTPSender, @unchecked Sendable {
  enum Answer {
    case status(Int, String)
    case offline
  }
  private let lock = NSLock()
  private var answers: [Answer]
  private var sent: [URLRequest] = []
  init(_ answers: [Answer]) { self.answers = answers }
  var requests: [URLRequest] { lock.withLock { sent } }
  /// The JSON body of each request.
  var bodies: [[String: String]] {
    requests.map { request in
      request.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
  }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let answer: Answer? = lock.withLock {
      sent.append(request)
      return answers.isEmpty ? nil : answers.removeFirst()
    }
    // Let a concurrent caller reach the account while this one waits.
    await Task.yield()
    guard case .status(let code, let body) = answer, let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: code, httpVersion: nil, headerFields: nil)
    else { throw URLError(.notConnectedToInternet) }
    return (Data(body.utf8), response)
  }
}

/// Keeps the session in memory, or refuses every save or removal.
final class MemorySessionStore: AccountSessionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var kept: AccountSession?
  private let refusesSaves: Bool
  private let refusesRemovals: Bool
  init(_ kept: AccountSession? = nil, refusesSaves: Bool = false, refusesRemovals: Bool = false) {
    self.kept = kept
    self.refusesSaves = refusesSaves
    self.refusesRemovals = refusesRemovals
  }
  var session: AccountSession? { lock.withLock { kept } }
  func load() -> AccountSession? { session }
  func save(_ session: AccountSession) throws(AccountError) {
    if refusesSaves { throw .keychain(errSecInteractionNotAllowed) }
    lock.withLock { kept = session }
  }
  func remove() throws(AccountError) {
    if refusesRemovals { throw .keychain(errSecInteractionNotAllowed) }
    lock.withLock { kept = nil }
  }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let user = AccountUser(id: AccountID("user_01A"), email: "a@example.com", firstName: "Ada")

/// An unsigned JWT with `exp` set `seconds` from `now`.
private func token(expiresIn seconds: TimeInterval, _ tag: String = "") -> String {
  let payload = #"{"exp":\#(Int(now.timeIntervalSince1970 + seconds)),"t":"\#(tag)"}"#
  return "e30.\(Base64URL.encode(Data(payload.utf8))).sig"
}

private func sessionJSON(access: String, refresh: String) -> String {
  #"""
  {"user":{"object":"user","id":"user_01A","email":"a@example.com","first_name":"Ada","last_name":null,"email_verified":true},
   "organization_id":null,"access_token":"\#(access)","refresh_token":"\#(refresh)","authentication_method":"GoogleOAuth"}
  """#
}

@MainActor private func account(
  _ http: StubHTTP, _ store: MemorySessionStore, configured: Bool = true
) -> Account {
  let client = AuthKitConfiguration(clientID: configured ? "client_01TEST" : "").map {
    AuthKitClient(configuration: $0, http: http)
  }
  return Account(client: client, store: store, now: { now })
}

/// Answers like AuthKit: redirects with a code and the request's `state`.
private func redirect(code: String = "code_01", state override: String? = nil, error: String? = nil)
  -> (URL, String) async throws(AccountError) -> URL
{
  { url, scheme throws(AccountError) in
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let state = override ?? items.first { $0.name == "state" }?.value ?? ""
    var components = URLComponents(string: "\(scheme)://auth/callback")
    components?.queryItems =
      (error.map { [URLQueryItem(name: "error", value: $0)] }
        ?? [URLQueryItem(name: "code", value: code)]) + [URLQueryItem(name: "state", value: state)]
    guard let callback = components?.url else { throw .invalidResponse }
    return callback
  }
}

private func query(_ url: URL?, _ name: String) -> String? {
  url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
    .first { $0.name == name }?.value
}

// MARK: Sign-in

@Test @MainActor func signingInExchangesTheCodeWithItsVerifier() async throws {
  let http = StubHTTP([.status(200, sessionJSON(access: token(expiresIn: 300), refresh: "r1"))])
  let store = MemorySessionStore()
  let account = account(http, store)
  var opened: URL?
  try await account.signIn { url, scheme throws(AccountError) in
    opened = url
    #expect(scheme == "com.origin89.apps.ios")
    return try await redirect()(url, scheme)
  }
  #expect(account.status == .signedIn(user))
  #expect(account.owner == AccountID("user_01A"))
  #expect(store.session?.refreshToken == "r1")

  #expect(opened?.host == "api.workos.com")
  #expect(opened?.path == "/user_management/authorize")
  #expect(query(opened, "client_id") == "client_01TEST")
  #expect(query(opened, "provider") == "authkit")
  #expect(query(opened, "redirect_uri") == "com.origin89.apps.ios://auth/callback")
  #expect(query(opened, "code_challenge_method") == "S256")
  let body = try #require(http.bodies.first)
  #expect(http.requests.first?.url?.path == "/user_management/authenticate")
  #expect(body["grant_type"] == "authorization_code")
  #expect(body["code"] == "code_01")
  #expect(body["client_id"] == "client_01TEST")
  #expect(body["client_secret"] == nil)
  // The verifier sent is the one whose S256 hash the sheet was given.
  let verifier = try #require(body["code_verifier"])
  #expect(verifier.count == 43)
  #expect(query(opened, "code_challenge") == PKCE(verifier: verifier).challenge)
}

/// RFC 7636 appendix B.
@Test func theChallengeIsTheVerifiersS256() {
  let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  #expect(PKCE.random() != PKCE.random())
}

@Test @MainActor func cancellingTheSheetLeavesTheAccountSignedOut() async {
  let http = StubHTTP([])
  let store = MemorySessionStore()
  let account = account(http, store)
  await #expect(throws: AccountError.cancelled) {
    try await account.signIn { _, _ throws(AccountError) in throw .cancelled }
  }
  #expect(account.status == .signedOut)
  #expect(store.session == nil)
  #expect(http.requests.isEmpty)
}

@Test @MainActor func aRedirectWithAnotherStateIsNotExchanged() async {
  let http = StubHTTP([])
  let account = account(http, MemorySessionStore())
  await #expect(throws: AccountError.invalidResponse) {
    try await account.signIn(using: redirect(state: "forged"))
  }
  #expect(account.status == .signedOut)
  #expect(http.requests.isEmpty)
}

@Test @MainActor func aRedirectCarryingAnErrorIsRefused() async {
  let http = StubHTTP([])
  let account = account(http, MemorySessionStore())
  await #expect(throws: AccountError.refused) {
    try await account.signIn(using: redirect(error: "access_denied"))
  }
  #expect(http.requests.isEmpty)
}

@Test @MainActor func aCodeWorkOSRefusesSignsNothingIn() async {
  let http = StubHTTP([.status(400, #"{"error":"invalid_grant"}"#)])
  let store = MemorySessionStore()
  let account = account(http, store)
  await #expect(throws: AccountError.refused) { try await account.signIn(using: redirect()) }
  #expect(account.status == .signedOut)
  #expect(store.session == nil)
}

@Test @MainActor func unreadableSessionsAndServerErrorsAreTold() async {
  let garbled = account(StubHTTP([.status(200, "{}")]), MemorySessionStore())
  await #expect(throws: AccountError.invalidResponse) {
    try await garbled.signIn(using: redirect())
  }
  let down = account(StubHTTP([.status(503, "")]), MemorySessionStore())
  await #expect(throws: AccountError.unavailable) { try await down.signIn(using: redirect()) }
  let limited = account(StubHTTP([.status(429, "")]), MemorySessionStore())
  await #expect(throws: AccountError.unavailable) { try await limited.signIn(using: redirect()) }
}

/// A session the Keychain did not keep would vanish on the next launch.
@Test @MainActor func aSessionTheKeychainRefusesIsNotSignedIn() async {
  let http = StubHTTP([.status(200, sessionJSON(access: token(expiresIn: 300), refresh: "r1"))])
  let account = account(http, MemorySessionStore(refusesSaves: true))
  await #expect(throws: AccountError.keychain(errSecInteractionNotAllowed)) {
    try await account.signIn(using: redirect())
  }
  #expect(account.status == .signedOut)
}

@Test @MainActor func aBuildWithoutAClientIDCannotSignIn() async {
  let account = account(StubHTTP([]), MemorySessionStore(), configured: false)
  #expect(!account.isAvailable)
  await #expect(throws: AccountError.notConfigured) { try await account.signIn(using: redirect()) }
}

// MARK: Tokens and refresh

private func signedIn(access: String, refresh: String = "r1") -> AccountSession {
  AccountSession(user: user, accessToken: access, refreshToken: refresh)
}

@Test @MainActor func aLaunchWithAKeptSessionIsSignedIn() async throws {
  let access = token(expiresIn: 300)
  let http = StubHTTP([])
  let account = account(http, MemorySessionStore(signedIn(access: access)))
  #expect(account.status == .signedIn(user))
  #expect(try await account.accessToken() == access)
  #expect(http.requests.isEmpty)
}

@Test @MainActor func anExpiringTokenIsRefreshedAndTheRotatedTokenKept() async throws {
  let fresh = token(expiresIn: 300, "fresh")
  let http = StubHTTP([.status(200, sessionJSON(access: fresh, refresh: "r2"))])
  // 30 seconds left is inside the refresh margin.
  let store = MemorySessionStore(signedIn(access: token(expiresIn: 30)))
  let account = account(http, store)
  #expect(try await account.accessToken() == fresh)
  #expect(
    http.bodies == [
      ["grant_type": "refresh_token", "refresh_token": "r1", "client_id": "client_01TEST"]
    ])
  #expect(store.session?.refreshToken == "r2")
  #expect(try await account.accessToken() == fresh)
  #expect(http.requests.count == 1)
}

@Test @MainActor func anUnreadableTokenCountsAsExpired() async throws {
  let fresh = token(expiresIn: 300)
  let http = StubHTTP([.status(200, sessionJSON(access: fresh, refresh: "r2"))])
  let account = account(http, MemorySessionStore(signedIn(access: "not-a-jwt")))
  #expect(try await account.accessToken() == fresh)
}

/// The acceptance's refresh failure: WorkOS refuses the refresh token, so the
/// session ends here and the person is told.
@Test @MainActor func aRefusedRefreshEndsTheSession() async {
  let http = StubHTTP([.status(400, #"{"error":"invalid_grant"}"#)])
  let store = MemorySessionStore(signedIn(access: token(expiresIn: -10)))
  let account = account(http, store)
  await account.refreshIfExpired()
  #expect(account.status == .signedOut)
  #expect(account.sessionEnded)
  #expect(store.session == nil)
  await #expect(throws: AccountError.signedOut) { try await account.accessToken() }
}

/// Only `invalid_grant` says the refresh token is dead; a timeout, a rate
/// limit or another client error keeps the session.
@Test(arguments: [
  (408, ""), (429, ""), (400, #"{"error":"invalid_request"}"#),
  (401, #"{"error":"invalid_client"}"#), (403, ""),
])
@MainActor func anErrorOtherThanInvalidGrantKeepsTheSession(status: Int, body: String) async {
  let kept = signedIn(access: token(expiresIn: -10))
  let store = MemorySessionStore(kept)
  let account = account(StubHTTP([.status(status, body)]), store)
  await #expect(throws: (any Error).self) { try await account.accessToken() }
  #expect(account.status == .signedIn(user))
  #expect(!account.sessionEnded)
  #expect(store.session == kept)
}

/// A refused refresh whose session the Keychain keeps is not reported as
/// signed out: a relaunch would load it as signed in.
@Test @MainActor func anEndedSessionTheKeychainKeepsIsReported() async {
  let kept = signedIn(access: token(expiresIn: -10))
  let http = StubHTTP([.status(400, #"{"error":"invalid_grant"}"#)])
  let account = account(http, MemorySessionStore(kept, refusesRemovals: true))
  await #expect(throws: AccountError.keychain(errSecInteractionNotAllowed)) {
    try await account.accessToken()
  }
  #expect(account.status == .signedIn(user))
  #expect(!account.sessionEnded)
}

/// Offline is not a sign-out: the session stays for the next attempt.
@Test @MainActor func anUnreachableRefreshKeepsTheSession() async throws {
  let kept = signedIn(access: token(expiresIn: -10))
  let http = StubHTTP([.offline, .status(502, "")])
  let store = MemorySessionStore(kept)
  let account = account(http, store)
  await #expect(throws: AccountError.unavailable) { try await account.accessToken() }
  await #expect(throws: AccountError.unavailable) { try await account.accessToken() }
  #expect(account.status == .signedIn(user))
  #expect(!account.sessionEnded)
  #expect(store.session == kept)
}

/// WorkOS rotates the refresh token, so two refreshes at once would spend it
/// twice and the second would be refused.
@Test @MainActor func concurrentCallersShareOneRefresh() async throws {
  let fresh = token(expiresIn: 300)
  let http = StubHTTP([
    .status(200, sessionJSON(access: fresh, refresh: "r2")),
    .status(400, #"{"error":"invalid_grant"}"#),
  ])
  let account = account(http, MemorySessionStore(signedIn(access: token(expiresIn: -10))))
  async let first = account.accessToken()
  async let second = account.accessToken()
  #expect(try await [first, second] == [fresh, fresh])
  #expect(http.requests.count == 1)
  #expect(account.status == .signedIn(user))
}

@Test @MainActor func aRefreshFinishingAfterSignOutIsDropped() async throws {
  let http = StubHTTP([.status(200, sessionJSON(access: token(expiresIn: 300), refresh: "r2"))])
  let store = MemorySessionStore(signedIn(access: token(expiresIn: -10)))
  let account = account(http, store)
  let refreshed = Task { try await account.accessToken() }
  while http.requests.isEmpty { await Task.yield() }
  try account.signOut()
  await #expect(throws: AccountError.signedOut) { try await refreshed.value }
  #expect(account.status == .signedOut)
  #expect(!account.sessionEnded)
  #expect(store.session == nil)
}

// MARK: Sign-out

@Test @MainActor func signingOutRemovesTheSession() throws {
  let store = MemorySessionStore(signedIn(access: token(expiresIn: 300)))
  let account = account(StubHTTP([]), store)
  try account.signOut()
  #expect(account.status == .signedOut)
  #expect(account.owner == nil)
  #expect(store.session == nil)
  // Signed out already: nothing to do.
  try account.signOut()
}

@Test @MainActor func aSessionTheKeychainKeepsStaysSignedIn() {
  let store = MemorySessionStore(signedIn(access: token(expiresIn: 300)), refusesRemovals: true)
  let account = account(StubHTTP([]), store)
  #expect(throws: AccountError.keychain(errSecInteractionNotAllowed)) { try account.signOut() }
  #expect(account.status == .signedIn(user))
}
