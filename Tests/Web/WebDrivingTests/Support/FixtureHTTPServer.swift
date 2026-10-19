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
/// It keeps how many requests each path received, nothing of their headers or bodies. `stop` cancels the listener,
/// ends the stream of new connections, cancels every connection still open, and returns once the task that took
/// connections and every task serving one have ended; afterwards the port refuses connections. A start that fails
/// leaves no listener, stream or task.
actor FixtureHTTPServer {

    nonisolated let port: UInt16
    nonisolated var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private let listener: NWListener
    private let queue   : DispatchQueue
    private let page    : String
    private let incoming: AsyncStream<NWConnection>.Continuation
    private var taking  : Task<Void, Never>?
    private var open    : [ObjectIdentifier: NWConnection] = [:]
    private var serving : [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isStopped = false
    private(set) var counts: [String: Int] = [:]

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue, page: String,
                 incoming: AsyncStream<NWConnection>.Continuation) {
        self.listener = listener
        self.port     = port
        self.queue    = queue
        self.page     = page
        self.incoming = incoming
    }

    /// Starts serving `page` on 127.0.0.1, on `port`, by default one the system picks.
    static func start(page: String, port: NWEndpoint.Port = .any) async throws -> FixtureHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.forte.braus.webdriving.tests.http")
        let (connections, continuation) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { continuation.yield($0) }
        let port: UInt16
        do {
            port = try await withCheckedThrowingContinuation { ready in
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
        } catch {
            listener.newConnectionHandler = nil
            listener.cancel()
            continuation.finish()
            throw error
        }
        let server = FixtureHTTPServer(listener: listener, port: port, queue: queue, page: page, incoming: continuation)
        await server.take(connections)
        return server
    }

    /// Starts the task that takes each new connection and serves it in a task of its own, kept until it ends.
    private func take(_ connections: AsyncStream<NWConnection>) {
        taking = Task { [weak self] in
            for await connection in connections {
                await self?.accept(connection)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped else { return connection.cancel() }
        let key = ObjectIdentifier(connection)
        open[key] = connection
        serving[key] = Task { [weak self] in await self?.serve(connection, key: key) }
    }

    /// Cancels the listener, ends the stream of new connections, cancels every connection still open, and returns
    /// once the listener is cancelled and the taking task and every serving task have ended. Idempotent.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        listener.newConnectionHandler = nil
        // A cancel closes the port only once the listener reports it cancelled, on its queue.
        await withCheckedContinuation { (cancelled: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                guard case .cancelled = state else { return }
                cancelled.resume()
            }
            listener.cancel()
        }
        listener.stateUpdateHandler = nil
        incoming.finish()
        for connection in open.values { connection.cancel() }
        let tasks = Array(serving.values)
        for task in tasks { task.cancel() }
        await taking?.value
        for task in tasks { await task.value }
        taking = nil
        serving.removeAll()
        open.removeAll()
    }

    /// How many connection tasks are still running: none once `stop` returned.
    var runningTasks: Int { serving.count + (taking == nil ? 0 : 1) }

    private func serve(_ connection: NWConnection, key: ObjectIdentifier) async {
        defer {
            connection.cancel()
            open.removeValue(forKey: key)
            serving.removeValue(forKey: key)
        }
        connection.start(queue: queue)
        guard let path = await Self.path(of: connection) else { return }
        counts[path, default: 0] += 1
        guard !isStopped else { return }
        switch path {
            case "/":
                await Self.write(connection, Self.answer(200, "text/html; charset=utf-8", page))
            case "/slow":
                try? await Task.sleep(for: .milliseconds(600))
                guard !isStopped else { return }
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
