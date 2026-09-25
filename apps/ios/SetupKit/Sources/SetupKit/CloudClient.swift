import Foundation

/// Where the Origin89 cloud API runs. Each cloud accepts tokens only from its
/// own WorkOS environment, so a build pairs it with that environment's client.
public struct CloudConfiguration: Sendable {
  public let baseURL: URL

  /// Nil for an empty or non-HTTPS URL, as a build without a cloud has.
  public init?(baseURL: String) {
    guard let url = URL(string: baseURL), url.scheme == "https", url.host() != nil else {
      return nil
    }
    self.baseURL = url
  }
}

/// What a cloud request can fail with. Server errors map from the contract's
/// `{"error": {"code", "message"}}` (`@origin89/cloud`).
public enum CloudError: Error, Sendable, Equatable {
  /// No access token: signed out, or the refresh failed.
  case account(AccountError)
  /// The cloud could not be reached.
  case unreachable
  /// `unauthenticated`: the cloud refused the token.
  case unauthenticated
  /// `reauthentication_required`: the action needs a sign-in within the last
  /// five minutes. `Account.reauthenticate` and a retry clear it.
  case reauthenticationRequired
  /// `not_found`: the site does not exist or the caller is not its owner.
  case notFound
  /// `generation_linked`: this device and epoch are linked to another site.
  case generationLinked
  /// `stale_epoch`: a newer epoch of this device is already linked.
  case staleEpoch
  /// `provider_unavailable`: WorkOS failed. The message says what changed.
  case providerUnavailable(String)
  /// Any other error answer: `invalid_request`, `internal`, or a code this
  /// build does not know. The cloud's message is kept.
  case rejected(status: Int, message: String)
  /// An answer that is not the contract's.
  case invalidResponse

  public var message: String {
    switch self {
    case .account(let error): error.message
    case .unreachable:
      "The Origin89 cloud could not be reached. Check the connection and try again."
    case .unauthenticated: "The cloud did not accept this sign-in. Sign out and sign in again."
    case .reauthenticationRequired: "Sign in again to continue."
    case .notFound: "That site was not found."
    case .generationLinked: "This controller is already linked to another site."
    case .staleEpoch:
      "This controller was reset since this phone paired. Reconnect to it, then try again."
    case .providerUnavailable(let message), .rejected(_, let message): message
    case .invalidResponse: "The cloud sent an unexpected answer. Try again."
    }
  }
}

/// Requests to the v1 cloud API with the signed-in account's access token.
@MainActor public struct CloudClient {
  public enum Method: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
  }

  public let account: Account
  private let configuration: CloudConfiguration
  private let http: any HTTPSender

  public init(
    configuration: CloudConfiguration, account: Account, http: any HTTPSender = URLSessionSender()
  ) {
    self.configuration = configuration
    self.account = account
    self.http = http
  }

  /// Send `body` as JSON to `path` (such as `/v1/sites`) and decode the
  /// answer, which the contract writes in camelCase.
  public func send<Response: Decodable>(
    _ method: Method, _ path: String, body: (any Encodable)? = nil, as type: Response.Type
  ) async throws(CloudError) -> Response {
    let data = try await send(method, path, body: body)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      SetupLog.account.error("the cloud answered \(path, privacy: .public) with an unreadable body")
      throw .invalidResponse
    }
  }

  /// Send a request whose answer carries no body the caller needs.
  @discardableResult
  public func send(_ method: Method, _ path: String, body: (any Encodable)? = nil)
    async throws(CloudError) -> Data
  {
    let token: String
    do {
      token = try await account.accessToken()
    } catch {
      throw .account(error)
    }
    var request = URLRequest(url: configuration.baseURL.appending(path: path))
    request.httpMethod = method.rawValue
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      do {
        request.httpBody = try JSONEncoder().encode(body)
      } catch {
        throw .invalidResponse
      }
    }
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await http.send(request)
    } catch {
      SetupLog.account.error(
        "the cloud could not be reached: \(String(describing: error), privacy: .public)")
      throw .unreachable
    }
    if (200..<300).contains(response.statusCode) { return data }
    let failure = Self.failure(status: response.statusCode, data)
    SetupLog.account.notice(
      "the cloud refused \(method.rawValue, privacy: .public) \(path, privacy: .public): status \(response.statusCode, privacy: .public)"
    )
    throw failure
  }

  private static func failure(status: Int, _ data: Data) -> CloudError {
    struct Body: Decodable {
      struct Detail: Decodable {
        let code: String
        let message: String
      }
      let error: Detail
    }
    guard let detail = try? JSONDecoder().decode(Body.self, from: data).error else {
      return status >= 500 ? .unreachable : .invalidResponse
    }
    return switch detail.code {
    case "unauthenticated": .unauthenticated
    case "reauthentication_required": .reauthenticationRequired
    case "not_found": .notFound
    case "generation_linked": .generationLinked
    case "stale_epoch": .staleEpoch
    case "provider_unavailable": .providerUnavailable(detail.message)
    default: .rejected(status: status, message: detail.message)
    }
  }
}
