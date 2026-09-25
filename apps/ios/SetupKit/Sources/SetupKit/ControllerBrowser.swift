import Foundation
import Network

/// Finds a controller on the site network by DNS-SD (P-224). An instance
/// names its controller in an unauthenticated TXT record, so every address
/// found is only a candidate: Discover and Hello decide (P-225).
@MainActor public protocol ControllerBrowser: AnyObject {
  /// The IPv4 addresses of the instances whose TXT names `deviceID`, from one
  /// bounded browse; empty when none answer in time.
  func addresses(advertising deviceID: String) async -> [String]
}

/// A `ControllerBrowser` over `NWBrowser`. It browses `local.` until `settle`
/// after the first instance naming the controller, or `limit` with none, so
/// a later match is not lost to an earlier one. It then resolves each such
/// instance to IPv4 with a UDP path that sends nothing to the controller, so
/// no connection slot is used before the WebSocket opens. The app must declare
/// the service type in `NSBonjourServices`; iOS refuses to browse others.
@MainActor public final class NetworkControllerBrowser: ControllerBrowser {
  private let serviceType: String
  private let deviceIDKey: String
  private let limit: Duration
  private let settle: Duration

  /// Browse `serviceType`, reading the `device_id` from TXT key `deviceIDKey`.
  public init(
    serviceType: String, deviceIDKey: String, limit: Duration = .seconds(3),
    settle: Duration = .milliseconds(500)
  ) {
    self.serviceType = serviceType
    self.deviceIDKey = deviceIDKey
    self.limit = limit
    self.settle = settle
  }

  public func addresses(advertising deviceID: String) async -> [String] {
    let endpoints = await browse(for: deviceID)
    SetupLog.webSocket.info(
      "DNS-SD found \(endpoints.count, privacy: .public) instances for the controller")
    var addresses: [String] = []
    for endpoint in endpoints {
      guard !Task.isCancelled else { break }
      if let address = await resolve(endpoint), !addresses.contains(address) {
        addresses.append(address)
      }
    }
    return addresses
  }

  /// Whether a TXT record names `deviceID` under `key`. Other keys are ignored,
  /// and a record without the key names no controller.
  nonisolated static func advertises(
    _ txt: [String: String], deviceID: String, key: String
  ) -> Bool {
    txt[key] == deviceID
  }

  /// The endpoints of the instances naming `deviceID`: those seen by `settle`
  /// after the first, or none once `limit` passes.
  private func browse(for deviceID: String) async -> [NWEndpoint] {
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: serviceType, domain: "local."), using: NWParameters())
    let key = deviceIDKey
    let settle = settle
    let search = Search(browser)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        search.continuation = continuation
        search.timer = Task { [limit] in
          do { try await Task.sleep(for: limit) } catch { return }
          search.finish()
        }
        browser.browseResultsChangedHandler = { results, _ in
          MainActor.assumeIsolated {
            search.found = results.compactMap { result in
              guard case .bonjour(let txt) = result.metadata,
                Self.advertises(txt.dictionary, deviceID: deviceID, key: key)
              else { return nil }
              return result.endpoint
            }
            // More matches may follow the first; wait `settle` for them.
            if !search.found.isEmpty, !search.settling {
              search.settling = true
              search.timer?.cancel()
              search.timer = Task {
                do { try await Task.sleep(for: settle) } catch { return }
                search.finish()
              }
            }
          }
        }
        browser.stateUpdateHandler = { state in
          MainActor.assumeIsolated {
            switch state {
            case .failed(let error):
              SetupLog.webSocket.error(
                "DNS-SD browse failed: \(error.localizedDescription, privacy: .public)")
              search.finish()
            case .waiting(let error):
              // Denied local network access among others; the limit ends it.
              SetupLog.webSocket.notice(
                "DNS-SD browse waiting: \(error.localizedDescription, privacy: .public)")
            case .setup, .ready, .cancelled: break
            @unknown default: break
            }
          }
        }
        browser.start(queue: .main)
      }
    } onCancel: {
      Task { @MainActor in search.finish() }
    }
  }

  /// The IPv4 address `endpoint` resolves to, nil when it does not in `limit`.
  private func resolve(_ endpoint: NWEndpoint) async -> String? {
    let parameters = NWParameters.udp
    // The controller has no IPv6 (P-224 names the WifiStatus IPv4 address).
    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ip.version = .v4
    }
    let connection = NWConnection(to: endpoint, using: parameters)
    let lookup = Lookup(connection)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lookup.continuation = continuation
        lookup.timer = Task { [limit] in
          do { try await Task.sleep(for: limit) } catch { return }
          lookup.finish(nil)
        }
        connection.stateUpdateHandler = { [weak connection] state in
          MainActor.assumeIsolated {
            switch state {
            case .ready:
              lookup.finish(connection?.currentPath?.remoteEndpoint.flatMap(Self.ipv4))
            case .failed(let error):
              SetupLog.webSocket.error(
                "DNS-SD resolve failed: \(error.localizedDescription, privacy: .public)")
              lookup.finish(nil)
            case .setup, .preparing, .waiting, .cancelled: break
            @unknown default: break
            }
          }
        }
        connection.start(queue: .main)
      }
    } onCancel: {
      Task { @MainActor in lookup.finish(nil) }
    }
  }

  /// Dotted-decimal IPv4 of a resolved endpoint, without an interface scope.
  private nonisolated static func ipv4(_ endpoint: NWEndpoint) -> String? {
    guard case .hostPort(host: .ipv4(let address), port: _) = endpoint else { return nil }
    return address.rawValue.map(String.init).joined(separator: ".")
  }
}

/// One browse in flight. It holds the browser until the first of a match, a
/// failure, the limit or cancellation, then stops it and resumes once.
@MainActor private final class Search {
  private var browser: NWBrowser?
  var continuation: CheckedContinuation<[NWEndpoint], Never>?
  var found: [NWEndpoint] = []
  /// A match was seen; `timer` now ends the search after the settle time.
  var settling = false
  var timer: Task<Void, Never>?

  init(_ browser: NWBrowser) { self.browser = browser }

  func finish() {
    // Clearing the handlers breaks their cycle through this search.
    browser?.browseResultsChangedHandler = nil
    browser?.stateUpdateHandler = nil
    browser?.cancel()
    browser = nil
    timer?.cancel()
    timer = nil
    continuation?.resume(returning: found)
    continuation = nil
  }
}

/// One resolve in flight, ended the same way.
@MainActor private final class Lookup {
  private var connection: NWConnection?
  var continuation: CheckedContinuation<String?, Never>?
  var timer: Task<Void, Never>?

  init(_ connection: NWConnection) { self.connection = connection }

  func finish(_ address: String?) {
    connection?.stateUpdateHandler = nil
    connection?.cancel()
    connection = nil
    timer?.cancel()
    timer = nil
    continuation?.resume(returning: address)
    continuation = nil
  }
}
