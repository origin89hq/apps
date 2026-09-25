import Foundation
import Testing

@testable import SetupKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let user = AccountUser(id: AccountID("user_01A"), email: "a@example.com")
private let siteID = "7c0e6f3a-1b2d-4c5e-8f90-a1b2c3d4e5f6"
private let deviceID = "343199df00112233445566778899aabb"
private let generation = ControllerGeneration(deviceID: deviceID, epoch: 5)

private func token(_ tag: String) -> String {
  let payload = #"{"exp":\#(Int(now.timeIntervalSince1970 + 300)),"t":"\#(tag)"}"#
  return "e30.\(Base64URL.encode(Data(payload.utf8))).sig"
}

private func failure(_ code: String) -> String {
  #"{"error":{"code":"\#(code)","message":"From the cloud."}}"#
}

private let linked = #"""
  {"deviceId":"\#(deviceID)","epoch":5,"name":"Barn","linkedAt":"2026-09-25T15:00:00.000Z"}
  """#

private let fresh = #"""
  {"user":{"id":"user_01A","email":"a@example.com"},"access_token":"\#(token("new"))",
   "refresh_token":"r2"}
  """#

@MainActor private func cloud(
  _ answers: [StubHTTP.Answer], auth: [StubHTTP.Answer] = []
) throws -> (CloudClient, StubHTTP) {
  let http = StubHTTP(answers)
  let configuration = try #require(AuthKitConfiguration(clientID: "client_01TEST"))
  let account = Account(
    client: AuthKitClient(configuration: configuration, http: StubHTTP(auth)),
    store: MemorySessionStore(
      AccountSession(user: user, accessToken: token("old"), refreshToken: "r1")),
    now: { now })
  let client = CloudClient(
    configuration: try #require(CloudConfiguration(baseURL: "https://cloud.example.com")),
    account: account, http: http)
  return (client, http)
}

/// Answers like AuthKit, echoing the request's `state`, and counts the sheets.
private final class Sheet: @unchecked Sendable {
  private(set) var opened = 0
  var cancels = false
  func authenticate(_ url: URL, _ scheme: String) throws(AccountError) -> URL {
    opened += 1
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

private func json(_ request: URLRequest?) -> NSDictionary? {
  request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
}

private let name = DisplayName("Barn")!

// MARK: Sites

@Test @MainActor func sitesDecodeWithTheirLinkedGenerations() async throws {
  let (cloud, http) = try cloud([
    .status(
      200,
      #"""
      {"sites":[{"id":"\#(siteID)","name":"Farm","role":"owner",
        "createdAt":"2026-09-25T14:00:00.000Z","controllers":[\#(linked)]}]}
      """#)
  ])
  let sites = try await cloud.sites()
  #expect(
    sites == [
      Site(
        id: siteID, name: "Farm", role: .owner,
        controllers: [LinkedController(generation: generation, name: "Barn")])
    ])
  #expect(sites.first?.links(generation) == true)
  #expect(sites.first?.links(ControllerGeneration(deviceID: deviceID, epoch: 6)) == false)
  #expect(http.requests.first?.httpMethod == "GET")
  #expect(http.requests.first?.url?.path() == "/v1/sites")
}

@Test @MainActor func aSiteWithoutAUUIDOrAKnownRoleIsNotTheContract() async throws {
  for site in [
    #"{"id":"../account","name":"F","role":"owner","createdAt":"x","controllers":[]}"#,
    #"{"id":"\#(siteID)","name":"F","role":"viewer","createdAt":"x","controllers":[]}"#,
  ] {
    let (cloud, _) = try cloud([.status(200, #"{"sites":[\#(site)]}"#)])
    await #expect(throws: CloudError.invalidResponse) { try await cloud.sites() }
  }
}

@Test @MainActor func creatingASiteSendsItsTrimmedName() async throws {
  let (cloud, http) = try cloud([
    .status(
      201,
      #"{"id":"\#(siteID)","name":"Farm","role":"owner","createdAt":"x","controllers":[]}"#)
  ])
  let site = try await cloud.createSite(named: try #require(DisplayName("  Farm \n")))
  #expect(site.id == siteID)
  #expect(json(http.requests.first) == ["name": "Farm"])
}

@Test func aDisplayNameIsOneToEightyCharactersOnceTrimmed() {
  #expect(DisplayName("  ")?.rawValue == nil)
  #expect(DisplayName("")?.rawValue == nil)
  #expect(DisplayName(String(repeating: "a", count: 80))?.rawValue.count == 80)
  #expect(DisplayName(String(repeating: "a", count: 81)) == nil)
  #expect(DisplayName(" é ")?.rawValue == "é")
}

// MARK: Linking

@Test(arguments: [201, 200])
@MainActor func aLinkSendsOnlyTheGenerationAndName(status: Int) async throws {
  // 201 links; 200 is the same site linking the same generation again.
  let (cloud, http) = try cloud([.status(status, linked)])
  let sheet = Sheet()
  let link = try await cloud.link(
    generation, named: name, to: siteID, authenticate: sheet.authenticate)
  #expect(link == LinkedController(generation: generation, name: "Barn"))
  let request = try #require(http.requests.first)
  #expect(request.httpMethod == "POST")
  #expect(request.url?.path() == "/v1/sites/\(siteID)/controllers")
  #expect(json(request) == ["deviceId": deviceID, "epoch": 5, "name": "Barn"])
  #expect(sheet.opened == 0)
}

@Test(arguments: [
  (409, "generation_linked", CloudError.generationLinked),
  (409, "stale_epoch", .staleEpoch),
  (404, "not_found", .notFound),
])
@MainActor func aRefusedLinkIsTold(status: Int, code: String, expected: CloudError) async throws {
  let (cloud, http) = try cloud([.status(status, failure(code))])
  let sheet = Sheet()
  await #expect(throws: expected) {
    try await cloud.link(generation, named: name, to: siteID, authenticate: sheet.authenticate)
  }
  #expect(http.requests.count == 1)
  #expect(sheet.opened == 0)
}

@Test @MainActor func aStaleSignInSignsInAgainAndRetriesOnce() async throws {
  let (cloud, http) = try cloud(
    [.status(401, failure("reauthentication_required")), .status(201, linked)],
    auth: [.status(200, fresh)])
  let sheet = Sheet()
  _ = try await cloud.link(generation, named: name, to: siteID, authenticate: sheet.authenticate)
  #expect(sheet.opened == 1)
  #expect(http.requests.count == 2)
  #expect(
    http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token("new"))")
}

@Test @MainActor func aCancelledSignInDoesNotRetry() async throws {
  let (cloud, http) = try cloud([.status(401, failure("reauthentication_required"))])
  let sheet = Sheet()
  sheet.cancels = true
  await #expect(throws: CloudError.account(.cancelled)) {
    try await cloud.link(generation, named: name, to: siteID, authenticate: sheet.authenticate)
  }
  #expect(http.requests.count == 1)
}

@Test @MainActor func aSecondStaleAnswerIsNotRetriedAgain() async throws {
  let (cloud, http) = try cloud(
    [
      .status(401, failure("reauthentication_required")),
      .status(401, failure("reauthentication_required")),
    ],
    auth: [.status(200, fresh)])
  let sheet = Sheet()
  await #expect(throws: CloudError.reauthenticationRequired) {
    try await cloud.link(generation, named: name, to: siteID, authenticate: sheet.authenticate)
  }
  #expect(sheet.opened == 1)
  #expect(http.requests.count == 2)
}
