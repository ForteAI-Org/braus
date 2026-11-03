import Foundation
@testable import LocalMCP
import Network
import Testing

@Suite("MCPPeerLimit", .timeLimit(.minutes(1)))
@MainActor
struct MCPPeerLimitTests {
    @Test
    func cancellationReachesAFullQueue() async throws {
        let fixture = Fixture()
        let (host, client, token) = try await fixture.connect()
        defer { client.close(); host.stop() }
        try await fill(client, token: token)
        try await send(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(2)])
        ]), client: client, token: token)
        try await send(.object([
            "jsonrpc": .string("2.0"), "id": .number(90), "result": .object([:])
        ]), client: client, token: token)
        #expect(try await client.read()?["error"]["code"] == .number(-32600))
        fixture.release()
        var ids: [JSONValue] = []
        for _ in 0..<31 { ids.append(try #require(try await client.read())["id"]) }
        #expect(!ids.contains(.number(2)))
        for id in 1...32 where id != 2 { #expect(ids.contains(.number(Double(id)))) }
        #expect(fixture.calls == 31)
        #expect(fixture.closes == 0)
        try await ping(client, token: token)
        client.close()
        await host.stopAndDrain()
        #expect(fixture.closes == 1)
    }

    @Test
    func overloadAnswersAndKeepsTheConnection() async throws {
        let fixture = Fixture()
        let (host, client, token) = try await fixture.connect()
        defer { client.close(); host.stop() }
        try await fill(client, token: token)
        #expect(fixture.calls == 1)
        #expect(fixture.closes == 0)
        fixture.release()
        for _ in 0..<32 {
            #expect(try await client.read()?["result"]["isError"] == .bool(false))
        }
        #expect(fixture.calls == 32)
        try await send(request(34), client: client, token: token)
        #expect(try await client.read()?["id"] == .number(34))
        #expect(fixture.calls == 33)
        try await ping(client, token: token)
        client.close()
        await host.stopAndDrain()
        #expect(fixture.closes == 1)
    }

    @Test
    func clientResponsesAreNeverCounted() async throws {
        let fixture = Fixture()
        let (host, client, token) = try await fixture.connect()
        defer { client.close(); host.stop() }
        try await fill(client, token: token)
        try await send(.object([
            "jsonrpc": .string("2.0"), "id": .number(91), "result": .object([:])
        ]), client: client, token: token)
        let answer = try #require(try await client.read())
        #expect(answer["id"] == .number(91))
        #expect(answer["error"]["code"] == .number(-32600))
        #expect(fixture.closes == 0)
        fixture.release()
        for _ in 0..<32 { _ = try #require(try await client.read()) }
        try await ping(client, token: token)
        client.close()
        await host.stopAndDrain()
        #expect(fixture.closes == 1)
    }

    @Test
    func disconnectWithAFullQueueDrainsOnce() async throws {
        let fixture = Fixture()
        let (host, client, token) = try await fixture.connect()
        defer { client.close(); host.stop() }
        try await fill(client, token: token)
        client.close()
        await host.stopAndDrain()
        #expect(fixture.closes == 1)
        #expect(fixture.calls == 1)
        #expect(fixture.cancelled)
        #expect(!fixture.router.isAcceptingTools)
        await fixture.router.drain()
    }

    private func request(_ id: Int, method: String = "tools/call") -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
            "params": .object(["name": .string("observe"), "arguments": .object([:])])
        ])
    }

    private func send(_ message: JSONValue, client: MCPChannel, token: String) async throws {
        try await client.write(.object(["token": .string(token), "message": message]))
    }

    private func fill(_ client: MCPChannel, token: String) async throws {
        for id in 1...33 { try await send(request(id), client: client, token: token) }
        let overloaded = try #require(try await client.read())
        #expect(overloaded["id"] == .number(33))
        #expect(overloaded["error"]["code"] == .number(-32000))
        #expect(overloaded["error"]["message"] == .string(
            "Too many pending requests; wait for an answer before sending more."
        ))
    }

    private func ping(_ client: MCPChannel, token: String) async throws {
        try await send(request(100, method: "ping"), client: client, token: token)
        let answer = try #require(try await client.read())
        #expect(answer["id"] == .number(100))
        #expect(answer["result"] == .object([:]))
    }

    @MainActor
    private final class Fixture {
        var calls = 0
        var closes = 0
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?
        lazy var router = MCPRouter(
            tools: [.object(["name": .string("observe")])], instructions: nil
        ) { [self] _, _ in
            calls += 1
            if calls == 1 {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation = $0 }
                } onCancel: {
                    Task { @MainActor in self.release() }
                }
                cancelled = Task.isCancelled
            }
            return MCPRouter.toolResult(.object(["status": .string("ok")]))
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        func connect() async throws -> (LocalMCPHost, MCPChannel, String) {
            let host = LocalMCPHost(maximumConnections: 1) { [self] in
                MCPHostSession(router: router) { [self] in closes += 1 }
            }
            let endpoint = try await host.start()
            let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
            let client = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            try await client.start()
            return (host, client, endpoint.token)
        }
    }
}
