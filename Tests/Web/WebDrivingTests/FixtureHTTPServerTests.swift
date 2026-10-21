//
//  FixtureHTTPServerTests.swift
//  Braus
//

import Foundation
import Network
import TestScratch
import Testing

/// The request tests' own server on 127.0.0.1, without Chrome: it answers its routes, and `stop` ends every task it
/// started, during a request too, and closes its port. A start that fails leaves nothing behind. Loopback only.
@Suite("Fixture HTTP server", .serialized)
struct FixtureHTTPServerTests {

    static func get(_ path: String, from server: FixtureHTTPServer) async throws -> (Int, String) {
        let (data, response) = try await URLSession.shared.data(from: server.url.appending(path: path))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test("it answers the page, /slow after 600 ms and 404; stop ends every task and closes the port")
    func answersAndStops() async throws {
        let server = try await FixtureHTTPServer.start(page: "<p>fixture</p>")
        #expect(try await Self.get("/", from: server) == (200, "<p>fixture</p>"))
        let started = ContinuousClock.now
        #expect(try await Self.get("/slow", from: server) == (200, "ok"))
        #expect(ContinuousClock.now - started >= .milliseconds(600))
        #expect(try await Self.get("/other", from: server).0 == 404)
        #expect(await server.counts == ["/": 1, "/slow": 1, "/other": 1])
        await server.stop()
        #expect(await server.runningTasks == 0)
        #expect(FixtureHTTPServer.refuses(port: server.port))
    }

    @Test("stop while a request hangs and another waits: it returns once their tasks ended, and the clients see an error")
    func stopDuringRequests() async throws {
        let server = try await FixtureHTTPServer.start(page: "")
        let hanging = Task { try await Self.get("/hang", from: server) }
        let slow    = Task { try await Self.get("/slow", from: server) }
        try await Task.sleep(for: .milliseconds(200))
        let counts = await server.counts
        #expect(counts["/hang"] == 1 && counts["/slow"] == 1)
        let stopped = ContinuousClock.now
        await server.stop()
        #expect(ContinuousClock.now - stopped < .seconds(2))
        #expect(await server.runningTasks == 0)
        await #expect(throws: (any Error).self) { try await hanging.value }
        await #expect(throws: (any Error).self) { try await slow.value }
        #expect(FixtureHTTPServer.refuses(port: server.port))
        await server.stop()
    }

    @Test("a start on a port already taken fails, and leaves the first server serving")
    func failedStart() async throws {
        let first = try await FixtureHTTPServer.start(page: "first")
        let port = try #require(NWEndpoint.Port(rawValue: first.port))
        await #expect(throws: (any Error).self) { _ = try await FixtureHTTPServer.start(page: "second", port: port) }
        #expect(try await Self.get("/", from: first) == (200, "first"))
        await first.stop()
        #expect(FixtureHTTPServer.refuses(port: first.port))
    }
}
