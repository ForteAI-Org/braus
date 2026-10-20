//
//  FakeChromeServer.swift
//  Braus
//

import Foundation
import Network
import Synchronization
@testable import WebDriver

/// FakeChromeServer is a DevTools WebSocket on 127.0.0.1 that stands in for the person's Chrome: it records every
/// command it receives and answers as `behavior` says. No Chrome runs, and nothing leaves the loopback.
///
/// Its listener and connections run on its own queue; what it records is read under a lock.
final class FakeChromeServer: @unchecked Sendable {

    enum Behavior {
        /// Answers the commands a browser and a tab need, a 3 MiB `blob` for `Fake.big`, and an error otherwise.
        case answers
        /// Accepts the connection and answers nothing, as Chrome does while it waits for the person to allow it.
        case silent
        /// Closes the connection on the first command, as Chrome does when the person did not allow it.
        case closesOnFirstCommand
    }

    /// The tab `Target.createTarget` opens.
    static let openedTarget = "braus-tab"

    /// The size of `Fake.big`'s `blob`, beyond `URLSessionWebSocketTask`'s 1 MiB default.
    static let bigByteCount = 3 << 20

    let port: UInt16

    private let listener   : NWListener
    private let queue      : DispatchQueue
    private let behavior   : Behavior
    private let commands   = Mutex<[JSONValue]>([])
    private let connections = Mutex<[NWConnection]>([])

    /// Starts listening on a free loopback port and returns once it is ready.
    init(_ behavior: Behavior) async throws {
        self.behavior = behavior
        let parameters = NWParameters.tcp
        let websocket  = NWProtocolWebSocket.Options()
        websocket.autoReplyPing      = true
        websocket.maximumMessageSize = 64 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue    = DispatchQueue(label: "FakeChromeServer")
        self.listener = listener
        self.queue    = queue
        port = try await Self.ready(listener, on: queue)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    deinit {
        stop()
    }

    /// The DevTools endpoint as Chrome's `DevToolsActivePort` would name it.
    var activePort: String { "\(port)\n/devtools/browser/fake-chrome\n" }

    /// The methods received, in order.
    var methods: [String] { commands.withLock { $0.compactMap { $0["method"]?.stringValue } } }

    /// The commands received, in order.
    var received: [JSONValue] { commands.withLock { $0 } }

    /// Stops listening and closes every connection. Idempotent.
    func stop() {
        listener.cancel()
        for connection in connections.withLock({ $0 }) { connection.cancel() }
    }

    /// A port nothing listens on: one a listener had, released before it returns.
    static func closedPort() async throws -> UInt16 {
        let server = try await FakeChromeServer(.silent)
        let port = server.port
        server.stop()
        return port
    }

    /// Claims a one-time event: true for the first caller only.
    private final class Once: Sendable {
        private let isClaimed = Mutex(false)
        func claim() -> Bool { isClaimed.withLock { claimed in defer { claimed = true }; return !claimed } }
    }

    private static func ready(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
        let resumed = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let answer: Result<UInt16, any Error>?
                switch state {
                    case .ready:
                        answer = listener.port.map { .success($0.rawValue) } ?? .failure(URLError(.cannotFindHost))
                    case .failed(let error): answer = .failure(error)
                    case .cancelled        : answer = .failure(CancellationError())
                    default                : answer = nil
                }
                guard let answer, resumed.claim() else { return }
                continuation.resume(with: answer)
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else { return }
            if let content, let command = try? JSONDecoder().decode(JSONValue.self, from: content) {
                commands.withLock { $0.append(command) }
                switch behavior {
                    case .silent              : break
                    case .closesOnFirstCommand: return connection.cancel()
                    case .answers             : send(Self.answer(to: command), on: connection)
                }
            }
            receive(on: connection)
        }
    }

    private func send(_ answer: JSONValue, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(answer) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context  = NWConnection.ContentContext(identifier: "answer", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func answer(to command: JSONValue) -> JSONValue {
        let id = command["id"] ?? .null
        let result: JSONValue
        switch command["method"]?.stringValue {
            case "Browser.getVersion"   : result = ["product": "FakeChrome/1"]
            case "Target.createTarget"  : result = ["targetId": .string(openedTarget)]
            case "Target.attachToTarget": result = ["sessionId": "braus-session"]
            case "Target.closeTarget"   : result = ["success": true]
            case "Fake.big"             : result = ["blob": .string(String(repeating: "x", count: bigByteCount))]
            default:
                return ["id": id, "error": ["code": -32601, "message": "not handled by the fake"]]
        }
        return ["id": id, "result": result]
    }
}
