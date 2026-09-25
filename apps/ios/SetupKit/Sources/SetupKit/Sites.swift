import Foundation

/// A site's role for the signed-in user. Only an owner can link controllers.
public enum SiteRole: String, Sendable, Decodable {
  case owner, admin
}

/// One ownership generation linked to a site, as the cloud lists it.
public struct LinkedController: Sendable, Equatable, Decodable {
  public let generation: ControllerGeneration
  public let name: String

  public init(generation: ControllerGeneration, name: String) {
    self.generation = generation
    self.name = name
  }

  private enum CodingKeys: String, CodingKey { case deviceId, epoch, name }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    generation = ControllerGeneration(
      deviceID: try container.decode(String.self, forKey: .deviceId),
      epoch: try container.decode(UInt32.self, forKey: .epoch))
    name = try container.decode(String.self, forKey: .name)
  }
}

public struct Site: Sendable, Equatable, Identifiable, Decodable {
  /// A UUID, kept as the cloud wrote it because it goes back in request paths.
  public let id: String
  public let name: String
  public let role: SiteRole
  public let controllers: [LinkedController]

  public init(id: String, name: String, role: SiteRole, controllers: [LinkedController]) {
    self.id = id
    self.name = name
    self.role = role
    self.controllers = controllers
  }

  private enum CodingKeys: String, CodingKey { case id, name, role, controllers }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    guard UUID(uuidString: id) != nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .id, in: container, debugDescription: "a site ID is a UUID")
    }
    self.id = id
    name = try container.decode(String.self, forKey: .name)
    role = try container.decode(SiteRole.self, forKey: .role)
    controllers = try container.decode([LinkedController].self, forKey: .controllers)
  }

  /// Whether `generation` is linked here.
  public func links(_ generation: ControllerGeneration) -> Bool {
    controllers.contains { $0.generation == generation }
  }
}

/// A name for a site or a controller: 1 to 80 characters once trimmed, as the
/// cloud accepts.
public struct DisplayName: Sendable, Equatable {
  public let rawValue: String

  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(trimmed.count) else { return nil }
    rawValue = trimmed
  }
}

extension CloudClient {
  /// The signed-in user's sites, each with its linked controllers.
  public func sites() async throws(CloudError) -> [Site] {
    struct Sites: Decodable { let sites: [Site] }
    return try await send(.get, "/v1/sites", as: Sites.self).sites
  }

  /// A new site owned by the signed-in user.
  public func createSite(named name: DisplayName) async throws(CloudError) -> Site {
    struct Request: Encodable { let name: String }
    return try await send(.post, "/v1/sites", body: Request(name: name.rawValue), as: Site.self)
  }

  /// Link `generation` to `site`. Only its `device_id`, `epoch` and a display
  /// name are sent: never the setup code or the enrolment key, and the link
  /// grants no access to the controller. Linking the same generation to the
  /// same site again answers the stored link.
  ///
  /// The cloud wants a sign-in from the last five minutes for this. A stale
  /// one asks the person to sign in again through `authenticate`, then
  /// retries once.
  public func link(
    _ generation: ControllerGeneration, named name: DisplayName, to site: Site.ID,
    authenticate: (URL, String) async throws(AccountError) -> URL
  ) async throws(CloudError) -> LinkedController {
    struct Request: Encodable {
      let deviceId: String
      let epoch: UInt32
      let name: String
    }
    let path = "/v1/sites/\(site)/controllers"
    let body = Request(deviceId: generation.deviceID, epoch: generation.epoch, name: name.rawValue)
    // The generation comes from this account's pairings: never link it for
    // another account that signed in meanwhile.
    guard let owner = account.owner else { throw .account(.signedOut) }
    do {
      return try await send(.post, path, body: body, as: LinkedController.self)
    } catch .reauthenticationRequired {
      guard account.owner == owner else { throw .account(.differentAccount) }
      do {
        try await account.reauthenticate(using: authenticate)
      } catch {
        throw .account(error)
      }
      guard account.owner == owner else { throw .account(.differentAccount) }
      return try await send(.post, path, body: body, as: LinkedController.self)
    }
  }
}
