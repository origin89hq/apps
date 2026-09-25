import CryptoKit
import Foundation

/// Where the app signs in: a WorkOS AuthKit application used as a public
/// client with PKCE. No secret ships in the app; the client ID is public.
public struct AuthKitConfiguration: Sendable {
  /// The scheme of the redirect registered in WorkOS. It is fixed here, not
  /// derived from the bundle identifier, which a local signing setup changes.
  public static let callbackScheme = "com.origin89.apps.ios"

  public let clientID: String
  public let redirectURI: URL
  public let apiBase: URL

  /// Nil for an empty client ID, as a build without one configured has.
  public init?(clientID: String, apiBase: URL? = nil) {
    var redirect = URLComponents()
    redirect.scheme = Self.callbackScheme
    redirect.host = "auth"
    redirect.path = "/callback"
    guard !clientID.isEmpty, let redirectURI = redirect.url,
      let apiBase = apiBase ?? URL(string: "https://api.workos.com")
    else { return nil }
    self.clientID = clientID
    self.redirectURI = redirectURI
    self.apiBase = apiBase
  }
}

/// Sends one HTTP request. Tests replace URLSession with canned answers.
public protocol HTTPSender: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionSender: HTTPSender {
  private let session: URLSession
  public init(session: URLSession = .shared) { self.session = session }
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
  }
}

/// A PKCE verifier and its S256 challenge (RFC 7636).
struct PKCE: Sendable, Equatable {
  let verifier: String
  let challenge: String

  init(verifier: String) {
    self.verifier = verifier
    challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  /// A verifier from 32 random bytes, 43 characters once encoded.
  static func random() -> PKCE { PKCE(verifier: Base64URL.random(bytes: 32)) }
}

enum Base64URL {
  static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ text: some StringProtocol) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
  }

  static func random(bytes count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return encode(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }
}

/// The WorkOS User Management calls the app makes as a public client.
public struct AuthKitClient: Sendable {
  public let configuration: AuthKitConfiguration
  private let http: any HTTPSender

  public init(configuration: AuthKitConfiguration, http: any HTTPSender = URLSessionSender()) {
    self.configuration = configuration
    self.http = http
  }

  /// The hosted AuthKit page, which offers every sign-in method enabled in
  /// WorkOS. Its redirect carries `code` and `state`. With `reauthenticating`,
  /// AuthKit asks that person to sign in again even with a live session
  /// (`max_age=0`), which starts a new one.
  func authorizationURL(challenge: String, state: String, reauthenticating email: String? = nil)
    -> URL?
  {
    var components = URLComponents(
      url: configuration.apiBase.appending(path: "user_management/authorize"),
      resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
      URLQueryItem(name: "provider", value: "authkit"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    if let email {
      components?.queryItems? += [
        URLQueryItem(name: "max_age", value: "0"), URLQueryItem(name: "login_hint", value: email),
      ]
    }
    return components?.url
  }

  /// Exchange the redirect's code with the verifier that produced its challenge.
  func authenticate(code: String, verifier: String) async throws(AccountError) -> AccountSession {
    try await authenticate([
      "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
    ])
  }

  /// A new access token for `refreshToken`. WorkOS rotates the refresh token:
  /// only the returned one works afterwards.
  func refresh(_ refreshToken: String) async throws(AccountError) -> AccountSession {
    try await authenticate(["grant_type": "refresh_token", "refresh_token": refreshToken])
  }

  private func authenticate(_ grant: [String: String]) async throws(AccountError) -> AccountSession
  {
    var request = URLRequest(
      url: configuration.apiBase.appending(path: "user_management/authenticate"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var body = grant
    body["client_id"] = configuration.clientID
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw .invalidResponse
    }
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await http.send(request)
    } catch {
      SetupLog.account.error(
        "WorkOS could not be reached: \(String(describing: error), privacy: .public)")
      throw .unavailable
    }
    switch response.statusCode {
    case 200..<300:
      do {
        return try Self.decoder.decode(AccountSession.self, from: data)
      } catch {
        SetupLog.account.error("WorkOS answered with an unreadable session")
        throw .invalidResponse
      }
    case 400..<500 where Self.oauthError(in: data) == "invalid_grant":
      // The code or refresh token is spent, expired or revoked (RFC 6749 5.2).
      SetupLog.account.notice("WorkOS refused the grant")
      throw .refused
    case 400..<500 where response.statusCode != 408 && response.statusCode != 429:
      // Not a verdict on the grant: the session is kept.
      SetupLog.account.error(
        "WorkOS rejected the request: status \(response.statusCode, privacy: .public)")
      throw .invalidResponse
    default:
      SetupLog.account.error(
        "WorkOS is unavailable: status \(response.statusCode, privacy: .public)")
      throw .unavailable
    }
  }

  private static func oauthError(in data: Data) -> String? {
    struct Body: Decodable { let error: String }
    return try? JSONDecoder().decode(Body.self, from: data).error
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()
}
