import Foundation
import Network

/// A WebSocket client over Network.framework. Every handler runs on the main
/// queue; one from a cancelled connection is ignored.
@MainActor final class NetworkWebSocketDriver: WebSocketDriver {
  var event: ((WebSocketEvent) -> Void)?
  private var connection: NWConnection?

  func start(url: URL, maximumMessage: Int) {
    cancel()
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    options.maximumMessageSize = maximumMessage
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    let connection = NWConnection(to: .url(url), using: parameters)
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated { self?.update(state, of: connection) }
    }
    connection.start(queue: .main)
  }
  func send(_ message: Data) {
    guard let connection else {
      event?(.closed)
      return
    }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
    let context = NWConnection.ContentContext(identifier: "km43", metadata: [metadata])
    connection.send(
      content: message, contentContext: context, isComplete: true,
      completion: .contentProcessed { [weak self] error in
        MainActor.assumeIsolated {
          guard let self, self.connection === connection else { return }
          self.event?(error == nil ? .sent : .closed)
        }
      })
  }
  func cancel() {
    guard let connection else { return }
    self.connection = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  private func update(_ state: NWConnection.State, of connection: NWConnection) {
    guard self.connection === connection else { return }
    switch state {
    case .ready:
      event?(.ready)
      receive(on: connection)
    case .waiting(let error):
      let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
      SetupLog.webSocket.notice(
        "waiting: \(error.localizedDescription, privacy: .public), local network denied \(denied, privacy: .public)"
      )
      event?(.waiting(localNetworkDenied: denied))
    case .failed(let error):
      SetupLog.webSocket.error("failed: \(error.localizedDescription, privacy: .public)")
      event?(.closed)
    case .cancelled: event?(.closed)
    case .setup, .preparing: break
    @unknown default: break
    }
  }
  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] content, context, _, error in
      MainActor.assumeIsolated {
        guard let self, self.connection === connection else { return }
        let metadata =
          context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
          as? NWProtocolWebSocket.Metadata
        guard error == nil, let metadata else {
          self.event?(.closed)
          return
        }
        switch metadata.opcode {
        case .binary: self.event?(.message(content ?? Data()))
        case .text: self.event?(.textMessage)
        case .close:
          self.event?(.closed)
          return
        case .cont, .ping, .pong: break
        @unknown default: break
        }
        self.receive(on: connection)
      }
    }
  }
}
