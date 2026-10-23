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
    func humanSuspensionDrainsAnAdmittedCallWithoutCancellingIt() async throws {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var cancelled = false
        let router = MCPRouter(tools: [.object(["name": .string("observe")])]) { _, _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
            cancelled = Task.isCancelled
            return .string("finished")
        }
        let first = Task { await router.handle(request("tools/call")) }
        for _ in 0..<1000 where release == nil { await Task.yield() }
        let finish = try #require(release)
        router.suspendForHumanIntervention()
        _ = await router.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(1)])
        ]))
        let refused = try #require(await router.handle(request("tools/call", id: 2)))
        #expect(refused["error"] != .null)
        finish.resume()
        #expect(await first.value?["result"] == .string("finished"))
        await router.drain()
        #expect(calls == 1)
        #expect(!cancelled)
        #expect(!router.isAcceptingTools)
        router.resume()
        #expect(router.isAcceptingTools)
    }

    @Test @MainActor
    func ordinaryStopOverridesHumanSuspension() async throws {
        var release: CheckedContinuation<Void, Never>?
        var cancelled = false
        let router = MCPRouter(tools: [.object(["name": .string("observe")])]) { _, _ in
            await withCheckedContinuation { release = $0 }
            cancelled = Task.isCancelled
            return .null
        }
        let first = Task { await router.handle(request("tools/call")) }
        for _ in 0..<1000 where release == nil { await Task.yield() }
        let finish = try #require(release)
        router.suspendForHumanIntervention()
        router.pause()
        finish.resume()
        _ = await first.value
        #expect(cancelled)
        #expect(!router.isAcceptingTools)
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
