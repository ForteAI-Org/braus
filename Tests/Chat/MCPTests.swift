import Foundation
@testable import LocalMCP
import Network
import Testing

@Suite("Local MCP lifecycle")
struct MCPTests {
    private let definition: JSONValue = .object(["name": .string("observe")])

    private func request(_ method: String, id: Int = 1) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                 "params": .object(["name": .string("observe"), "arguments": .object([:])])])
    }

    @Test
    func initializeNegotiatesAndNotificationsHaveNoResponse() async throws {
        let router = MCPRouter(tools: [definition], instructions: nil) { _, _ in .object([:]) }
        let initialized = try #require(await router.handle(request("initialize")))
        #expect(initialized["result"]["protocolVersion"].string == "2025-11-25")
        #expect(await router.handle(.object(["jsonrpc": .string("2.0"),
                                            "method": .string("notifications/initialized")])) == nil)
        let missing = try #require(await router.handle(request("unsupported")))
        #expect(missing["error"]["code"] == .number(-32601))
    }

    @Test
    func concurrentActionsQueueAndPauseCancelsThenDrains() async throws {
        var calls = 0
        let router = MCPRouter(tools: [definition], instructions: nil) { _, _ in
            calls += 1
            try await Task.sleep(for: .seconds(30))
            return .object([:])
        }
        let first = Task { await router.handle(request("tools/call")) }
        while calls == 0 { await Task.yield() }
        var secondFinished = false
        let second = Task {
            let answer = await router.handle(request("tools/call", id: 2))
            secondFinished = true
            return answer
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!secondFinished)
        #expect(calls == 1)
        router.pause()
        await router.drain()
        #expect(await second.value?["error"]["code"] == .number(-32000))
        #expect(await second.value?["error"]["message"] == .string(
            "Braus is stopping. No further actions accepted."
        ))
        let interrupted = try #require(await first.value)
        #expect(interrupted["result"]["isError"].bool == true)
        #expect((await router.handle(request("tools/call")))?["error"]["message"].string?.contains("stopping") == true)
    }

    @Test
    func loopbackAuthenticationAndReconnect() async throws {
        var calls = 0
        let router = MCPRouter(tools: [definition], instructions: nil) { _, _ in
            calls += 1
            return MCPRouter.toolResult(.object(["status": .string("ok")]))
        }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let bad = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await bad.start()
        try await bad.write(.object(["token": .string("wrong"), "message": request("tools/call")]))
        #expect(try await bad.read() == nil)
        bad.close()
        #expect(calls == 0)
        for _ in 0..<2 {
            let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            try await channel.start()
            try await channel.write(.object(["token": .string(endpoint.token), "message": request("tools/call")]))
            let answer = try #require(try await channel.read())
            #expect(answer["result"]["structuredContent"] == .null)
            #expect(answer["result"].payload["status"].string == "ok")
            channel.close()
        }
        #expect(calls == 2)
    }

    /// A provider child that connects and exits before it says anything hands the host's connection two
    /// states at once, ready and cancelled; the host's channel takes the first and the process goes on.
    @Test
    func aConnectionCancelledAsItBecomesReadyDoesNotEndTheHost() async throws {
        let router = MCPRouter(tools: [definition], instructions: nil) { _, _ in MCPRouter.toolResult(.object(["status": .string("ok")])) }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        for _ in 0..<20 {
            let fleeting = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            fleeting.start(queue: .global(qos: .userInitiated))
            fleeting.cancel()
            let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
            try await channel.start()
            channel.close()
        }
        // One channel's own start, ready and then cancelled by its owner before the handler ran.
        let own = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        let starting = Task { try await own.start() }
        own.close()
        _ = try? await starting.value
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await channel.start()
        try await channel.write(.object(["token": .string(endpoint.token), "message": request("tools/call")]))
        let answer = try #require(try await channel.read())
        #expect(answer["result"].payload["status"].string == "ok")
        channel.close()
    }
}

extension JSONValue {

    /// Reads the structured result when present, otherwise the JSON text of its first content item.
    var payload: JSONValue {
        if self["structuredContent"] != .null { return self["structuredContent"] }
        guard let text = self["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return .null }
        return value
    }
}
