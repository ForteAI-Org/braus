//
//  FixtureHTTPServer.swift
//  Braus
//

import Foundation
import Network

/// FixtureHTTPServer serves the request tests' local fixture on 127.0.0.1, on a port the system picks, so only this
/// machine reaches it: no TLS, no account, no other address. Its routes are fixed:
/// - `/`: the page it was started with;
/// - `/slow`: "ok" after 600 ms;
/// - `/fail`: the connection closed with no answer, a network error on the page;
/// - `/hang`: no answer, until the client closes;
/// - anything else: 404.
///
/// It keeps how many requests each path received, nothing of their headers or bodies. `stop` cancels the listener
/// and every connection still open; afterwards the port refuses connections.
actor FixtureHTTPServer {

    nonisolated let port: UInt16
    nonisolated var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private let listener: NWListener
    private let queue   : DispatchQueue
    private let page    : String
    private var open    : [ObjectIdentifier: NWConnection] = [:]
    private var isStopped = false
    private(set) var counts: [String: Int] = [:]

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue, page: String) {
        self.listener = listener
        self.port     = port
        self.queue    = queue
        self.page     = page
    }

    static func start(page: String) async throws -> FixtureHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.forte.braus.webdriving.tests.http")
        let (connections, continuation) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { continuation.yield($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        ready.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        ready.resume(throwing: error)
                    default:
                        break
                }
            }
            listener.start(queue: queue)
        }
        let server = FixtureHTTPServer(listener: listener, port: port, queue: queue, page: page)
        Task {
            for await connection in connections {
                Task { await server.serve(connection) }
            }
        }
        return server
    }

    /// Cancels the listener and every connection still open. Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        listener.cancel()
        for connection in open.values { connection.cancel() }
        open.removeAll()
    }

    private func serve(_ connection: NWConnection) async {
        guard !isStopped else { return connection.cancel() }
        let key = ObjectIdentifier(connection)
        open[key] = connection
        defer {
            connection.cancel()
            open.removeValue(forKey: key)
        }
        connection.start(queue: queue)
        guard let path = await Self.path(of: connection) else { return }
        counts[path, default: 0] += 1
        switch path {
            case "/":
                await Self.write(connection, Self.answer(200, "text/html; charset=utf-8", page))
            case "/slow":
                try? await Task.sleep(for: .milliseconds(600))
                await Self.write(connection, Self.answer(200, "text/plain", "ok"))
            case "/fail":
                return
            case "/hang":
                while await Self.receive(connection) != nil {}
            default:
                await Self.write(connection, Self.answer(404, "text/plain", "not found"))
        }
    }

    private static func answer(_ status: Int, _ type: String, _ body: String) -> String {
        "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nConnection: close\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\n\r\n\(body)"
    }

    /// The path of the request line, once the head arrived; nil when the client closed first.
    private static func path(of connection: NWConnection) async -> String? {
        var head = Data()
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = await receive(connection) else { return nil }
            head.append(chunk)
        }
        let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1].split(separator: "?").first ?? "")
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete || error != nil { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    private static func write(_ connection: NWConnection, _ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// Whether 127.0.0.1:`port` refuses a connection now.
    nonisolated static func refuses(port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port   = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected != 0 && errno == ECONNREFUSED
    }
}
