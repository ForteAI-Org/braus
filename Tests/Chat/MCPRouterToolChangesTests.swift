import Foundation
@testable import LocalMCP
import Network
import Testing

@Suite("MCP router tool list changes", .timeLimit(.minutes(1)))
struct MCPRouterToolChangesTests {

    private func request(_ method: String, id: Int = 1, name: String = "observe") -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
                 "params": .object(["name": .string(name), "arguments": .object([:])])])
    }

    @Test @MainActor
    func fixedListKeepsItsCapabilityAndSendsNothing() async throws {
        let router = MCPRouter(tools: [.object(["name": .string("observe")])]) { _, _ in .object([:]) }
        var notifications: [JSONValue] = []
        _ = router.addNotificationSink { notifications.append($0) }
        let initialized = try #require(await router.handle(request("initialize")))
        #expect(initialized["result"]["capabilities"] == .object(["tools": .object([:])]))
        router.replaceTools([.object(["name": .string("other")])])
        #expect(notifications.isEmpty)
        let listed = try #require(await router.handle(request("tools/list")))
        #expect(listed["result"]["tools"] == .array([.object(["name": .string("other")])]))
    }

    @Test @MainActor
    func announcedChangesReachEveryConnectionAndCallsFollowTheNewList() async throws {
        let router = MCPRouter(
            tools                   : [.object(["name": .string("observe")])],
            announcesToolListChanges: true
        ) { name, _ in .object(["called": .string(name)]) }
        let initialized = try #require(await router.handle(request("initialize")))
        #expect(initialized["result"]["capabilities"]["tools"]["listChanged"] == .bool(true))
        var first: [JSONValue] = [], second: [JSONValue] = []
        _ = router.addNotificationSink { first.append($0) }
        let key = router.addNotificationSink { second.append($0) }
        router.replaceTools([.object(["name": .string("observe")]), .object(["name": .string("slack__search")])])
        router.replaceTools([.object(["name": .string("observe")]), .object(["name": .string("slack__search")])])
        #expect(first == [.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")])])
        #expect(second.count == 1)
        router.removeNotificationSink(key)
        router.replaceTools([.object(["name": .string("observe")])])
        #expect(first.count == 2)
        #expect(second.count == 1)
        let unknown = try #require(await router.handle(request("tools/call", name: "slack__search")))
        #expect(unknown["error"]["code"] == .number(-32602))
    }

    @Test @MainActor
    func aConnectedClientReceivesTheNotification() async throws {
        let router = MCPRouter(tools: [], announcesToolListChanges: true) { _, _ in .object([:]) }
        let host = LocalMCPHost(router: router)
        let endpoint = try await host.start()
        defer { host.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let client = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await client.start()
        try await client.write(.object(["token": .string(endpoint.token), "message": request("tools/list")]))
        #expect(try await client.read()?["result"]["tools"] == .array([]))
        router.replaceTools([.object(["name": .string("notion__search")])])
        #expect(try await client.read()?["method"] == .string("notifications/tools/list_changed"))
        client.close()
    }
}
