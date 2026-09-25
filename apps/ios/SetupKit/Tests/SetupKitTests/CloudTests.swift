import Foundation
import Testing

@testable import SetupKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let user = AccountUser(id: AccountID("user_01A"), email: "a@example.com")

private func token(_ tag: String) -> String {
  let payload = #"{"exp":\#(Int(now.timeIntervalSince1970 + 300)),"t":"\#(tag)"}"#
  return "e30.\(Base64URL.encode(Data(payload.utf8))).sig"
}

private func sessionJSON(id: String, access: String) -> String {
  #"""
  {"user":{"id":"\#(id)","email":"a@example.com","first_name":null,"last_name":null},
   "access_token":"\#(access)","refresh_token":"r2"}
  """#
}

private func failure(_ code: String, _ message: String = "From the cloud.") -> String {
  #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
}

/// Records what deletion hands over, or refuses it.
private final class Pairings: AccountPairingStore, @unchecked Sendable {
  struct Refused: Error {}
  private let lock = NSLock()
  private var handed: [String] = []
  private let refuses: Bool
  init(refuses: Bool = false) { self.refuses = refuses }
  var calls: [String] { lock.withLock { handed } }
  func keep(_ owner: AccountID) throws {
    if refuses { throw Refused() }
    lock.withLock { handed.append("keep \(owner.rawValue)") }
  }
  func forget(_ owner: AccountID) throws {
    if refuses { throw Refused() }
    lock.withLock { handed.append("forget \(owner.rawValue)") }
  }
}

private struct Setup {
  let account: Account
  let cloud: CloudClient
  let cloudHTTP: StubHTTP
  let authHTTP: StubHTTP
  let session: MemorySessionStore
}

@MainActor private func setup(
  cloud answers: [StubHTTP.Answer], auth: [StubHTTP.Answer] = [], signedIn: Bool = true
) throws -> Setup {
  let authHTTP = StubHTTP(auth)
  let cloudHTTP = StubHTTP(answers)
  let session = MemorySessionStore(
    signedIn ? AccountSession(user: user, accessToken: token("old"), refreshToken: "r1") : nil)
  let configuration = try #require(AuthKitConfiguration(clientID: "client_01TEST"))
  let account = Account(
    client: AuthKitClient(configuration: configuration, http: authHTTP), store: session,
    now: { now })
  let cloud = CloudClient(
    configuration: try #require(CloudConfiguration(baseURL: "https://cloud.example.com")),
    account: account, http: cloudHTTP)
  return Setup(
    account: account, cloud: cloud, cloudHTTP: cloudHTTP, authHTTP: authHTTP, session: session)
}

/// Answers like AuthKit, echoing the request's `state`, and records the URL.
private final class Sheet: @unchecked Sendable {
  private(set) var opened: [URL] = []
  var cancels = false
  func authenticate(_ url: URL, _ scheme: String) throws(AccountError) -> URL {
    opened.append(url)
    if cancels { throw .cancelled }
    let state =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "state" }?.value ?? ""
    guard let callback = URL(string: "\(scheme)://auth/callback?code=c&state=\(state)") else {
      throw .invalidResponse
    }
    return callback
  }
}

// MARK: Configuration and requests

@Test func onlyAnHTTPSCloudIsConfigured() {
  #expect(
    CloudConfiguration(baseURL: "https://cloud.origin89.com")?.baseURL.host()
      == "cloud.origin89.com")
  #expect(CloudConfiguration(baseURL: "http://cloud.origin89.com") == nil)
  #expect(CloudConfiguration(baseURL: "") == nil)
  #expect(CloudConfiguration(baseURL: "https://") == nil)
}

@Test @MainActor func aRequestCarriesTheAccessTokenAndBody() async throws {
  struct Site: Decodable, Equatable { let id: String }
  let setup = try setup(cloud: [.status(201, #"{"id":"s1"}"#)])
  let site = try await setup.cloud.send(
    .post, "/v1/sites", body: ["name": "Home"], as: Site.self)
  #expect(site == Site(id: "s1"))
  let request = try #require(setup.cloudHTTP.requests.first)
  #expect(request.url?.absoluteString == "https://cloud.example.com/v1/sites")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token("old"))")
  #expect(setup.cloudHTTP.bodies == [["name": "Home"]])
}

@Test(arguments: [
  (401, failure("unauthenticated"), CloudError.unauthenticated),
  (401, failure("reauthentication_required"), .reauthenticationRequired),
  (404, failure("not_found"), .notFound),
  (409, failure("generation_linked"), .generationLinked),
  (409, failure("stale_epoch"), .staleEpoch),
  (
    502, failure("provider_unavailable", "Retry to finish."),
    .providerUnavailable("Retry to finish.")
  ),
  (
    400, failure("invalid_request", "name: Required"),
    .rejected(status: 400, message: "name: Required")
  ),
  (418, failure("a_new_code", "Newer cloud."), .rejected(status: 418, message: "Newer cloud.")),
  (500, "<html>", .unreachable),
  (400, "", .invalidResponse),
])
@MainActor func cloudErrorsMapFromTheContract(status: Int, body: String, expected: CloudError)
  async throws
{
  let setup = try setup(cloud: [.status(status, body)])
  await #expect(throws: expected) { try await setup.cloud.send(.get, "/v1/sites") }
}

@Test @MainActor func anUnreachableCloudIsTold() async throws {
  let setup = try setup(cloud: [.offline])
  await #expect(throws: CloudError.unreachable) { try await setup.cloud.send(.get, "/v1/sites") }
}

@Test @MainActor func signedOutSendsNothing() async throws {
  let setup = try setup(cloud: [], signedIn: false)
  await #expect(throws: CloudError.account(.signedOut)) {
    try await setup.cloud.send(.get, "/v1/sites")
  }
  #expect(setup.cloudHTTP.requests.isEmpty)
}

@Test @MainActor func aBodyOutsideTheContractIsInvalid() async throws {
  struct Site: Decodable { let id: String }
  let setup = try setup(cloud: [.status(200, #"{"sites":[]}"#)])
  await #expect(throws: CloudError.invalidResponse) {
    try await setup.cloud.send(.get, "/v1/sites", as: Site.self)
  }
}

// MARK: Deletion

@Test(arguments: [DeletedPairings.keep, .forget])
@MainActor func deletingHandsThePairingsOverAndSignsOut(pairings: DeletedPairings) async throws {
  let setup = try setup(cloud: [.status(204, "")])
  let store = Pairings()
  let sheet = Sheet()
  let outcome = try await setup.cloud.deleteAccount(
    pairings: pairings, store: store, authenticate: sheet.authenticate)
  #expect(outcome == .deleted)
  #expect(store.calls == [pairings == .keep ? "keep user_01A" : "forget user_01A"])
  #expect(setup.cloudHTTP.requests.map(\.httpMethod) == ["DELETE"])
  #expect(setup.cloudHTTP.requests.first?.url?.path == "/v1/account")
  #expect(setup.account.status == .signedOut)
  #expect(!setup.account.sessionEnded)
  #expect(setup.session.session == nil)
  #expect(sheet.opened.isEmpty)
}

/// The cloud needs a sign-in within five minutes: sign in again, then retry.
@Test @MainActor func aStaleSignInSignsInAgainThenDeletes() async throws {
  let fresh = token("fresh")
  let setup = try setup(
    cloud: [.status(401, failure("reauthentication_required")), .status(204, "")],
    auth: [.status(200, sessionJSON(id: "user_01A", access: fresh))])
  let store = Pairings()
  let sheet = Sheet()
  let outcome = try await setup.cloud.deleteAccount(
    pairings: .keep, store: store, authenticate: sheet.authenticate)
  #expect(outcome == .deleted)
  let opened = try #require(sheet.opened.first)
  let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
  #expect(items.first { $0.name == "max_age" }?.value == "0")
  #expect(items.first { $0.name == "login_hint" }?.value == "a@example.com")
  #expect(
    setup.cloudHTTP.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
      == ["Bearer \(token("old"))", "Bearer \(fresh)"])
  #expect(store.calls == ["keep user_01A"])
}

/// Signing in again as someone else must not delete that other account.
@Test @MainActor func anotherAccountSigningInAgainDeletesNothing() async throws {
  let setup = try setup(
    cloud: [.status(401, failure("reauthentication_required"))],
    auth: [.status(200, sessionJSON(id: "user_01B", access: token("b")))])
  let store = Pairings()
  await #expect(throws: CloudError.account(.differentAccount)) {
    try await setup.cloud.deleteAccount(
      pairings: .forget, store: store, authenticate: Sheet().authenticate)
  }
  #expect(setup.cloudHTTP.requests.count == 1)
  #expect(setup.account.status == .signedIn(user))
  #expect(setup.session.session?.accessToken == token("old"))
  #expect(store.calls.isEmpty)
}

@Test @MainActor func cancellingTheNewSignInDeletesNothing() async throws {
  let setup = try setup(cloud: [.status(401, failure("reauthentication_required"))])
  let store = Pairings()
  let sheet = Sheet()
  sheet.cancels = true
  await #expect(throws: CloudError.account(.cancelled)) {
    try await setup.cloud.deleteAccount(
      pairings: .forget, store: store, authenticate: sheet.authenticate)
  }
  #expect(setup.account.status == .signedIn(user))
  #expect(store.calls.isEmpty)
}

/// WorkOS failed after the cloud removed its records: nothing changes here,
/// and a retry finishes.
@Test @MainActor func aWorkOSFailureKeepsEverythingForARetry() async throws {
  let setup = try setup(cloud: [
    .status(502, failure("provider_unavailable", "Retry to finish.")), .status(204, ""),
  ])
  let store = Pairings()
  let sheet = Sheet()
  await #expect(throws: CloudError.providerUnavailable("Retry to finish.")) {
    try await setup.cloud.deleteAccount(
      pairings: .forget, store: store, authenticate: sheet.authenticate)
  }
  #expect(setup.account.status == .signedIn(user))
  #expect(store.calls.isEmpty)
  let outcome = try await setup.cloud.deleteAccount(
    pairings: .forget, store: store, authenticate: sheet.authenticate)
  #expect(outcome == .deleted)
  #expect(store.calls == ["forget user_01A"])
}

@Test @MainActor func pairingsThatCannotBeHandedOverAreReported() async throws {
  let setup = try setup(cloud: [.status(204, "")])
  let outcome = try await setup.cloud.deleteAccount(
    pairings: .keep, store: Pairings(refuses: true), authenticate: Sheet().authenticate)
  #expect(outcome == .pairingsLeft)
  #expect(setup.account.status == .signedOut)
}

/// The Keychain keeping a deleted account's tokens does not keep it signed in.
@Test @MainActor func aDeletedAccountSignsOutEvenIfTheKeychainKeepsItsSession() async throws {
  let authHTTP = StubHTTP([])
  let session = MemorySessionStore(
    AccountSession(user: user, accessToken: token("old"), refreshToken: "r1"),
    refusesRemovals: true)
  let configuration = try #require(AuthKitConfiguration(clientID: "client_01TEST"))
  let account = Account(
    client: AuthKitClient(configuration: configuration, http: authHTTP), store: session,
    now: { now })
  let cloud = CloudClient(
    configuration: try #require(CloudConfiguration(baseURL: "https://cloud.example.com")),
    account: account, http: StubHTTP([.status(204, "")]))
  _ = try await cloud.deleteAccount(
    pairings: .keep, store: Pairings(), authenticate: Sheet().authenticate)
  #expect(account.status == .signedOut)
}

@Test @MainActor func signedOutCannotDelete() async throws {
  let setup = try setup(cloud: [], signedIn: false)
  await #expect(throws: CloudError.account(.signedOut)) {
    try await setup.cloud.deleteAccount(
      pairings: .keep, store: Pairings(), authenticate: Sheet().authenticate)
  }
  #expect(setup.cloudHTTP.requests.isEmpty)
}
