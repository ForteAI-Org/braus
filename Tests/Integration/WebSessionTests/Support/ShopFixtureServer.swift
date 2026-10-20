//
//  ShopFixtureServer.swift
//  Braus
//

import Foundation
import Network

/// ShopFixtureServer serves a shop's search page on 127.0.0.1, on a port the system picks, so only this machine
/// reaches it: no TLS, no account, no other address. It keeps every request target it received, path and query, in
/// order, and the `Cookie` header each carried: what a page did, read without the browser or Braus. Its routes are
/// fixed:
/// - `/`: the shop, a Search field and a Go button submitting `GET /search?q=…`;
/// - `/search`: a results page;
/// - `/remember`: sets a persistent cookie (`braus_fixture=kept`, a day) and a `localStorage` value of the page;
/// - `/check`: sends what `localStorage` holds to `/report?local=…`;
/// - `/report`: a plain page;
/// - `/refused`: 403 with an empty body;
/// - anything else: 404.
///
/// The structure is `WebDrivingTests`' `FixtureHTTPServer`'s (test targets share no sources). `stop` cancels the
/// listener, ends the stream of new connections, cancels every connection still open, and returns once every task
/// has ended. A start that fails leaves no listener, stream or task.
actor ShopFixtureServer {

    nonisolated let port: UInt16
    nonisolated var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    static let shop = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Shop</title></head>
        <body>
          <form action="/search" method="get">
            <label for="query">Search</label>
            <input id="query" name="q" type="text">
            <button type="submit">Go</button>
          </form>
        </body></html>
        """

    static let results = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Results</title></head>
        <body><p>Results</p><a href="/">Back to the shop</a></body></html>
        """

    private let listener: NWListener
    private let queue   : DispatchQueue
    private let incoming: AsyncStream<NWConnection>.Continuation
    private var taking  : Task<Void, Never>?
    private var open    : [ObjectIdentifier: NWConnection] = [:]
    private var serving : [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isStopped = false

    /// Every request target received, in order.
    private(set) var targets: [String] = []

    /// The `Cookie` header of each request, by its target; empty when it carried none.
    private(set) var cookies: [String: String] = [:]

    static let remember = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Remembered</title></head>
        <body><p>Remembered</p><script>localStorage.setItem('braus_fixture', 'kept')</script></body></html>
        """

    static let check = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Check</title></head>
        <body><p>Checking</p><script>
          location.replace('/report?local=' + encodeURIComponent(localStorage.getItem('braus_fixture') || 'none'))
        </script></body></html>
        """

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue,
                 incoming: AsyncStream<NWConnection>.Continuation) {
        self.listener = listener
        self.port     = port
        self.queue    = queue
        self.incoming = incoming
    }

    /// Starts serving on 127.0.0.1, on a port the system picks.
    static func start() async throws -> ShopFixtureServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.forte.braus.websession.tests.shop")
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
        let server = ShopFixtureServer(listener: listener, port: port, queue: queue, incoming: continuation)
        await server.take(connections)
        return server
    }

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

    /// Cancels the listener and every connection, and returns once every task has ended. Idempotent.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        listener.newConnectionHandler = nil
        listener.cancel()
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

    private func serve(_ connection: NWConnection, key: ObjectIdentifier) async {
        defer {
            connection.cancel()
            open.removeValue(forKey: key)
            serving.removeValue(forKey: key)
        }
        connection.start(queue: queue)
        guard let (target, cookie) = await Self.request(of: connection) else { return }
        targets.append(target)
        cookies[target] = cookie
        guard !isStopped else { return }
        switch target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target {
            case "/":
                await Self.write(connection, Self.answer(200, Self.shop))
            case "/search":
                await Self.write(connection, Self.answer(200, Self.results))
            case "/remember":
                let cookie = "Set-Cookie: braus_fixture=kept; Max-Age=86400; Path=/"
                await Self.write(connection, Self.answer(200, Self.remember, headers: [cookie]))
            case "/check":
                await Self.write(connection, Self.answer(200, Self.check))
            case "/report":
                await Self.write(connection, Self.answer(200, Self.results))
            case "/refused":
                await Self.write(connection, Self.answer(403, ""))
            default:
                await Self.write(connection, Self.answer(404, "not found"))
        }
    }

    private static func answer(_ status: Int, _ body: String, headers: [String] = []) -> String {
        let reason = [200: "OK", 403: "Forbidden"][status] ?? "Not Found"
        return "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n\(body)"
    }

    /// The target of the request line, path and query, and its `Cookie` header (empty when none), once the head
    /// arrived; nil when the client closed first.
    private static func request(of connection: NWConnection) async -> (target: String, cookie: String)? {
        var head = Data()
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = await receive(connection) else { return nil }
            head.append(chunk)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let cookie = lines.dropFirst().first { $0.lowercased().hasPrefix("cookie:") }
            .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        return (String(parts[1]), cookie)
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
}
