import AgentLoop
import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Synchronization
import Testing

@MainActor
@Suite("ModelToolLoopLibrary")
struct ModelToolLoopLibraryTests {

    private let tool = ToolCall(id: "call_0", name: "status", arguments: Data("{}".utf8))
    private let definitions: [JSONValue] = [.object([
        "name": .string("status"),
        "description": .string("Read status."),
        "inputSchema": .object(["type": .string("object")]),
    ])]
    private let usage = ModelUsage(inputTokens: 10, outputTokens: 2, duration: .zero)

    @Test func aToolRoundThenAnAnswer() async throws {
        let transport = LibraryTransport(rounds: [
            [.delta("Checking."), .toolCall(tool), .completed(usage)],
            [.delta("Done."), .completed(usage)],
        ])
        var calls: [String] = []
        var events: [ProviderEvent] = []
        let loop = ModelToolLoop(
            call: { name, _ in
                calls.append(name)
                return MCPRouter.toolResult(.string("Ready."))
            },
            definitions: definitions,
            instructions: LibraryInstructions()
        )

        try await loop.run(
            transport: transport,
            role: nil,
            history: [],
            prompt: "Check.",
            contextWindow: 4096,
            instructions: "Use status."
        ) { events.append($0) }

        #expect(calls == ["status"])
        #expect(events == [
            .assistant("Checking."), .assistant("Done."), .completed,
            .usage(ProviderUsage(
                tokens: ProviderUsage.Tokens(input: 20, output: 4),
                contextTokens: 12,
                contextWindow: 4096
            )),
        ])
        #expect(transport.sent.count == 2)
        #expect(transport.sent.first?.tools.map(\.name) == ["status"])
        let answer = try #require(transport.sent.last?.messages.last)
        #expect(answer.role == .tool)
        #expect(answer.call == tool)
        #expect(!answer.isError)
    }

    @Test func systemTextComesFromTheComposer() async throws {
        let composer = LibraryInstructions()
        let transport = LibraryTransport(rounds: [[.delta("Done."), .completed(usage)]])
        let loop = ModelToolLoop(
            call: { _, _ in .null },
            definitions: definitions,
            instructions: composer
        )

        try await loop.run(
            transport: transport,
            role: "Be brief.",
            history: [TurnMessage(role: .assistant, text: "Earlier.")],
            prompt: "Check.",
            instructions: "Use status."
        ) { _ in }

        #expect(composer.received == [.init(role: "Be brief.", hasTools: true, tools: "Use status.")])
        #expect(transport.sent.first?.messages.first?.role == .system)
        #expect(transport.sent.first?.messages.first?.text == "Role: Be brief.\nTools: true\nUse status.")
    }

    @Test func aModelWithoutToolsIsSentNone() async throws {
        let composer = LibraryInstructions()
        let transport = LibraryTransport(supportsTools: false, rounds: [[.completed(usage)]])
        let loop = ModelToolLoop(
            call: { _, _ in
                Issue.record("A model without tools called one.")
                return .null
            },
            definitions: definitions,
            instructions: composer
        )

        try await loop.run(
            transport: transport,
            role: nil,
            history: [],
            prompt: "Hello.",
            instructions: "Use status."
        ) { _ in }

        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.tools.isEmpty == true)
        #expect(composer.received == [.init(role: nil, hasTools: false, tools: "Use status.")])
    }

    @Test func aThrowingToolAnswersWithTheRouterFailure() async throws {
        let failure = AutomationFailure("The tool refused.")
        let transport = LibraryTransport(rounds: [
            [.toolCall(tool), .completed(usage)],
            [.delta("Done."), .completed(usage)],
        ])
        let loop = ModelToolLoop(
            call: { _, _ in throw failure },
            definitions: definitions,
            instructions: LibraryInstructions()
        )

        try await loop.run(
            transport: transport,
            role: nil,
            history: [],
            prompt: "Check.",
            instructions: "Use status."
        ) { _ in }

        let answer = try #require(transport.sent.last?.messages.last)
        let expected = MCPRouter.failureResult(failure)
        let text = try #require(expected["content"].array?.first?["text"].string)
        #expect(answer.role == .tool)
        #expect(answer.call == tool)
        #expect(answer.isError)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(answer.text.utf8))
            == JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        #expect(expected["structuredContent"] == .null)
    }

    @Test func theCeilingIsAnAutomationFailure() async throws {
        let transport = LibraryTransport(rounds: Array(
            repeating: [.toolCall(tool), .completed(usage)],
            count: ModelToolLoop.toolRoundLimit + 1
        ))
        var calls = 0
        let loop = ModelToolLoop(
            call: { _, _ in
                calls += 1
                return .null
            },
            definitions: definitions,
            instructions: LibraryInstructions()
        )

        let failure = await #expect(throws: AutomationFailure.self) {
            try await loop.run(
                transport: transport,
                role: nil,
                history: [],
                prompt: "Check.",
                instructions: "Use status."
            ) { _ in }
        }

        #expect(failure?.description == "The model kept calling tools after 100 rounds in one "
            + "response, so Braus stopped it. Review the app before continuing.")
        #expect(calls == ModelToolLoop.toolRoundLimit)
        #expect(transport.sent.count == ModelToolLoop.toolRoundLimit + 1)
    }

    private final class LibraryInstructions: LoopInstructionComposing {
        struct Request: Equatable {
            let role: String?
            let hasTools: Bool
            let tools: String
        }

        private(set) var received: [Request] = []

        func systemText(role: String?, hasTools: Bool, tools: String) -> String {
            received.append(Request(role: role, hasTools: hasTools, tools: tools))
            return "Role: \(role ?? "none")\nTools: \(hasTools)\n\(tools)"
        }
    }
}

private final class LibraryTransport: ModelTransport {
    struct Sent: Sendable {
        let messages: [TurnMessage]
        let tools: [ToolDefinition]
    }

    private struct State {
        var rounds: [[TurnEvent]]
        var sent: [Sent] = []
    }

    private let supportsTools: Bool
    private let state: Mutex<State>

    init(supportsTools: Bool = true, rounds: [[TurnEvent]]) {
        self.supportsTools = supportsTools
        state = Mutex(State(rounds: rounds))
    }

    var streaming: StreamingSupport { .incremental }
    var sent: [Sent] { state.withLock { $0.sent } }

    func capabilities() async throws -> ModelCapabilities {
        ModelCapabilities(supportsTools: supportsTools)
    }

    func complete(prompt: String, schema: Data, timeout: TimeInterval)
        async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("This transport only serves scripted turns.")
    }

    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let events = state.withLock { state -> [TurnEvent]? in
            state.sent.append(Sent(messages: messages, tools: tools))
            return state.rounds.isEmpty ? nil : state.rounds.removeFirst()
        }
        guard let events else {
            throw ModelTransportError.streamEndedEarly(deltas: 0)
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
