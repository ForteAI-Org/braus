import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Synchronization
import Testing
@testable import AgentLoop

@MainActor
@Suite struct LoopParityTests {
    private func loop(parallelSafe: @escaping ParallelSafety = { _, _ in false },
                      call: @escaping @MainActor (String, JSONValue) async throws -> JSONValue = { _, _ in .null }) -> ModelToolLoop {
        ModelToolLoop(call: call, definitions: [], instructions: Instructions(), parallelSafe: parallelSafe)
    }

    @Test func twoRetriesThenSuccess() async throws {
        let transport = RetryTransport(failures: 2)
        let loop = loop()
        var delays: [Duration] = []
        loop.waitBeforeRetry = { delays.append($0) }
        try await loop.run(transport: transport, role: nil, history: [], prompt: "Hello", instructions: "") { _ in }
        #expect(transport.count == 3)
        #expect(delays == [.seconds(1), .seconds(3)])
    }

    @Test func thirdFailureEndsTheTurn() async {
        let transport = RetryTransport(failures: 3)
        let loop = loop()
        loop.waitBeforeRetry = { _ in }
        await #expect(throws: ProviderError.self) {
            try await loop.run(transport: transport, role: nil, history: [], prompt: "Hello", instructions: "") { _ in }
        }
        #expect(transport.count == 3)
    }

    @Test func takeoverDuringBackoffSendsNothingElse() async {
        let transport = RetryTransport(failures: 1)
        let loop = loop()
        loop.waitBeforeRetry = { _ in loop.suspendForHumanIntervention() }
        var events: [ProviderEvent] = []
        await #expect(throws: CancellationError.self) {
            try await loop.run(transport: transport, role: nil, history: [], prompt: "Hello", instructions: "") { events.append($0) }
        }
        #expect(transport.count == 1)
        #expect(events.isEmpty)
    }

    @Test func takeoverKeepsThePartialReplyOfTheInterruptedRequest() async {
        let transport = RetryTransport(failures: 1, partialFailure: true)
        let loop = loop()
        loop.waitBeforeRetry = { _ in loop.suspendForHumanIntervention() }
        var events: [ProviderEvent] = []
        await #expect(throws: CancellationError.self) {
            try await loop.run(transport: transport, role: nil, history: [], prompt: "Hello", instructions: "") { events.append($0) }
        }
        #expect(events == [.assistant("Partial")])
        #expect(transport.count == 1)
    }

    @Test func failureAfterAToolIsNotRetried() async {
        let transport = RetryTransport(failures: 1, toolFirst: true)
        var calls = 0
        let loop = loop(call: { _, _ in calls += 1; return .null })
        loop.waitBeforeRetry = { _ in Issue.record("A request after a tool was retried.") }
        await #expect(throws: ProviderError.self) {
            try await loop.run(transport: transport, role: nil, history: [], prompt: "Hello", instructions: "") { _ in }
        }
        #expect(transport.count == 2)
        #expect(calls == 1)
    }

    @Test func admittedCallsOverlapAndResultsKeepTheirOrder() async throws {
        var active = 0
        var maximum = 0
        var ended: [String] = []
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        let loop = loop(parallelSafe: { _, _ in true }, call: { name, _ in
            active += 1
            maximum = max(maximum, active)
            await withCheckedContinuation { waiting[name] = $0 }
            active -= 1
            ended.append(name)
            return .object(["content": .array([.object(["text": .string(name)])])])
        })
        let run = Task { try await loop.results(of: calls(["1", "2", "3"])) }
        while waiting.count < 3 { await Task.yield() }
        for name in ["3", "2", "1"] {
            waiting.removeValue(forKey: name)?.resume()
            while ended.last != name { await Task.yield() }
        }
        let results = try await run.value
        #expect(maximum == 3)
        #expect(ended == ["3", "2", "1"])
        #expect(results.map(\.text) == ["1", "2", "3"])
    }

    @Test(arguments: [true, false]) func serialCallsDivideGroups(_ admission: Bool) async throws {
        var active = 0
        var order: [String] = []
        let loop = loop(parallelSafe: { name, _ in admission && name != "write" }, call: { name, _ in
            #expect(active == 0)
            active += 1
            order.append(name)
            await Task.yield()
            active -= 1
            return .null
        })
        _ = try await loop.results(of: calls(["1", "write", "2"]))
        #expect(order == ["1", "write", "2"])
    }

    @Test func canonicalSchemasAndStructuredResultsKeepSortedKeys() async throws {
        let definitions: [JSONValue] = [.object([
            "name": .string("read"), "description": .string("Read."),
            "inputSchema": .object(["z": .number(1), "a": .object(["z": .number(2), "a": .number(3)])])
        ])]
        let encoded = try ModelToolLoop.toolDefinitions(definitions)
        #expect(String(decoding: encoded[0].parameters, as: UTF8.self) == #"{"a":{"a":3,"z":2},"z":1}"#)
        let loop = loop(call: { _, _ in
            .object(["content": .array([.object(["text": .string("Result")])]),
                     "structuredContent": .object(["z": .number(1), "a": .number(2)])])
        })
        let result = try await loop.results(of: calls(["read"]))
        #expect(result[0].text == "Result\n" + #"{"a":2,"z":1}"#)
    }

    private func calls(_ names: [String]) -> [ToolCall] {
        names.map { ToolCall(id: $0, name: $0, arguments: Data("{}".utf8)) }
    }

    private struct Instructions: LoopInstructionComposing {
        func systemText(role: String?, hasTools: Bool, tools: String) -> String { tools }
    }
}

private final class RetryTransport: ModelTransport {
    private struct State { var count = 0; var failures: Int }
    private let state: Mutex<State>
    private let toolFirst: Bool
    private let partialFailure: Bool
    init(failures: Int, toolFirst: Bool = false, partialFailure: Bool = false) {
        state = Mutex(State(failures: failures))
        self.toolFirst = toolFirst
        self.partialFailure = partialFailure
    }
    var count: Int { state.withLock { $0.count } }
    var streaming: StreamingSupport { .incremental }
    func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ProviderError.badResponse("unused")
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let next = state.withLock { state -> Int in state.count += 1; return state.count }
        return AsyncThrowingStream { continuation in
            if toolFirst && next == 1 {
                continuation.yield(.toolCall(ToolCall(id: "read", name: "read", arguments: Data("{}".utf8))))
            } else if next <= state.withLock({ $0.failures }) + (toolFirst ? 1 : 0) {
                if partialFailure {
                    continuation.yield(.delta("Partial"))
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                } else {
                    continuation.finish(throwing: ProviderError.http(status: toolFirst ? 529 : 429, message: "test"))
                }
                return
            }
            continuation.yield(.completed(ModelUsage(inputTokens: 1, outputTokens: 1, duration: .zero)))
            continuation.finish()
        }
    }
}
