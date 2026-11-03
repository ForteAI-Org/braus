import Foundation
@testable import LocalMCP
import Network
import Testing

@MainActor
@Suite("MCP response draining", .serialized, .timeLimit(.minutes(1)))
struct MCPPeerDrainTests {
    @Test func shutdownDeliversTheAcceptedResponseWithoutWaitingForClientEOF() async throws {
        var calls = 0
        var held: CheckedContinuation<Void, Never>?
        let router = MCPRouter(tools: [.object(["name": .string("observe")])], instructions: nil) { _, _ in
            calls += 1
            await withCheckedContinuation { held = $0 }
            return MCPRouter.toolResult(.object(["status": .string("ok")]))
        }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let client = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        defer { client.close(); host.stop(); held?.resume() }
        try await client.start()
        func request(_ id: Int) -> JSONValue {
            .object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                "params": .object(["name": .string("observe"), "arguments": .object([:])])
            ])
        }
        try await client.write(.object(["token": .string(endpoint.token), "message": request(1)]))
        while held == nil { await Task.yield() }
        let response = Task { try await client.read() }
        var joining = false
        var joined = false
        let shutdown = Task {
            joining = true
            await host.stopAndDrain()
            joined = true
        }
        while !joining { await Task.yield() }
        #expect(!joined)
        try? await client.write(.object(["token": .string(endpoint.token), "message": request(2)]))
        held?.resume()
        held = nil
        let answer = try #require(try await response.value)
        await shutdown.value
        #expect(joined)
        #expect(calls == 1)
        #expect(answer["id"] == .number(1))
        #expect(answer["result"]["isError"] == .bool(false))
    }
}
