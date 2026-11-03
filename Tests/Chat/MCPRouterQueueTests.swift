import Foundation
@testable import LocalMCP
import Testing

@Suite("MCPRouterQueue", .timeLimit(.minutes(1)))
@MainActor
struct MCPRouterQueueTests {
    private var expectedNotSent: JSONValue {
        MCPRouter.toolResult(.object([
            "gesture": .string("not_sent"), "effect": .string("not_applicable"),
            "recovery": .string("do_not_repeat"), "cause": .string("human_intervention")
        ]))
    }

    private let tools: [JSONValue] = ["observe", "click"].map { .object(["name": .string($0)]) }

    private func request(_ id: Int) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
            "params": .object([
                "name": .string(id.isMultiple(of: 2) ? "click" : "observe"),
                "arguments": .number(Double(id))
            ])
        ])
    }

    private func enqueue(_ id: Int, on router: MCPRouter) async -> Task<JSONValue?, Never> {
        var task: Task<JSONValue?, Never>!
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            task = Task {
                entered.resume()
                return await router.handle(request(id))
            }
        }
        return task
    }

    @Test
    func removedQueuedToolGetsTheSameErrorAsANewCall() async throws {
        var release: CheckedContinuation<Void, Never>?
        var called: [JSONValue] = []
        let router = MCPRouter(tools: tools, instructions: nil) { _, arguments in
            called.append(arguments)
            if arguments == .number(1) { await withCheckedContinuation { release = $0 } }
            return arguments
        }
        let first = await enqueue(1, on: router)
        while release == nil { await Task.yield() }
        let second = await enqueue(2, on: router)
        let third = await enqueue(3, on: router)
        router.replaceTools([.object(["name": .string("observe")])])
        let fresh = try #require(await router.handle(request(4)))
        release?.resume()
        _ = await first.value
        let queued = try #require(await second.value)
        #expect(queued["id"] == .number(2))
        #expect(queued["error"] == fresh["error"])
        #expect(queued["error"]["code"] == .number(-32602))
        #expect(await third.value?["result"] == .number(3))
        await router.drain()
        #expect(called == [.number(1), .number(3)])
    }

    @Test
    func secondCallWaitsAndRunsAfterTheFirst() async throws {
        let gate = Gate()
        let router = MCPRouter(tools: tools, instructions: nil, call: gate.call)
        let first = await enqueue(1, on: router)
        await gate.waitFor(1)
        let second = await enqueue(2, on: router)
        #expect(gate.started == [1])
        gate.release(1)
        #expect(await first.value?["result"] == .number(1))
        await gate.waitFor(2)
        gate.release(2)
        #expect(await second.value?["result"] == .number(2))
        #expect(gate.started == [1, 2])
    }

    @Test
    func queueKeepsArrivalOrder() async {
        let gate = Gate()
        let router = MCPRouter(tools: tools, instructions: nil, call: gate.call)
        var tasks: [Task<JSONValue?, Never>] = []
        for id in 1...5 { tasks.append(await enqueue(id, on: router)) }
        for id in 1...5 {
            await gate.waitFor(id)
            #expect(gate.started == Array(1...id))
            gate.release(id)
            #expect(await tasks[id - 1].value?["result"] == .number(Double(id)))
        }
        await router.drain()
    }

    @Test
    func suspensionLetsTheAdmittedCallFinishAndAnswersQueuedNotSent() async {
        let gate = Gate()
        let router = MCPRouter(tools: tools, instructions: nil, call: gate.call)
        let first = await enqueue(1, on: router)
        await gate.waitFor(1)
        let second = await enqueue(2, on: router)
        let third = await enqueue(3, on: router)
        router.suspendForHumanIntervention()
        #expect(await second.value?["result"] == expectedNotSent)
        #expect(await third.value?["result"] == expectedNotSent)
        gate.release(1)
        #expect(await first.value?["result"] == .number(1))
        await router.drain()
        #expect(gate.started == [1])
    }

    @Test
    func newCallWhileSuspendedIsNotSent() async {
        var calls = 0
        let router = MCPRouter(tools: tools, instructions: nil) { _, _ in
            calls += 1
            return .string("unchanged")
        }
        router.suspendForHumanIntervention()
        #expect(await router.handle(request(1))?["result"] == expectedNotSent)
        #expect(calls == 0)
        router.resume()
        #expect(await router.handle(request(2))?["result"] == .string("unchanged"))
        #expect(calls == 1)
    }

    @Test
    func pauseCancelsTheActiveAndStopsTheQueue() async {
        var started = false
        let router = MCPRouter(tools: tools, instructions: nil) { _, _ in
            started = true
            try await Task.sleep(for: .seconds(30))
            return .null
        }
        let first = await enqueue(1, on: router)
        while !started { await Task.yield() }
        let second = await enqueue(2, on: router)
        router.pause()
        await router.drain()
        #expect(await first.value?["result"]["isError"] == .bool(true))
        #expect(await second.value?["error"]["code"] == .number(-32000))
        #expect(await second.value?["error"]["message"].string?.contains("stopping") == true)
    }

    @Test
    func cancelledQueuedRequestLeavesTheQueue() async {
        let gate = Gate()
        let router = MCPRouter(tools: tools, instructions: nil, call: gate.call)
        let first = await enqueue(1, on: router)
        await gate.waitFor(1)
        let second = await enqueue(2, on: router)
        let third = await enqueue(3, on: router)
        #expect(await router.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(2)])
        ])) == nil)
        #expect(await second.value == nil)
        gate.release(1)
        _ = await first.value
        await gate.waitFor(3)
        gate.release(3)
        #expect(await third.value?["result"] == .number(3))
        #expect(gate.started == [1, 3])
    }

    @Test
    func drainWaitsForTheQueue() async {
        let gate = Gate()
        let router = MCPRouter(tools: tools, instructions: nil, call: gate.call)
        let first = await enqueue(1, on: router)
        await gate.waitFor(1)
        let second = await enqueue(2, on: router)
        var drained = false
        let draining = Task { await router.drain(); drained = true }
        gate.release(1)
        _ = await first.value
        await gate.waitFor(2)
        #expect(!drained)
        gate.release(2)
        _ = await second.value
        await draining.value
        #expect(drained)
    }

    @Test
    func notSentIsTypedAndHasNoProse() async throws {
        let router = MCPRouter(tools: tools, instructions: nil) { _, _ in .null }
        router.suspendForHumanIntervention()
        let answer = try #require(await router.handle(request(1)))
        #expect(answer["result"]["isError"] == .bool(false))
        #expect(answer["result"].payload == .object([
            "gesture": .string("not_sent"), "effect": .string("not_applicable"),
            "recovery": .string("do_not_repeat"), "cause": .string("human_intervention")
        ]))
    }

    @MainActor
    private final class Gate {
        var started: [Int] = []
        var releases: [Int: CheckedContinuation<Void, Never>] = [:]

        func call(_ name: String, _ arguments: JSONValue) async -> JSONValue {
            guard case .number(let value) = arguments else { return .null }
            let id = Int(value)
            started.append(id)
            await withCheckedContinuation { releases[id] = $0 }
            return .number(Double(id))
        }

        func waitFor(_ id: Int) async {
            for _ in 0..<1000 where releases[id] == nil { await Task.yield() }
            #expect(releases[id] != nil)
        }

        func release(_ id: Int) { releases.removeValue(forKey: id)?.resume() }
    }
}
