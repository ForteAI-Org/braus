import AutomationRuntime
import ChatCore
import LocalMCP
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests budget")
struct TurnBudgetTests {
    @Test func offPreservesTheExistingToolCeiling() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let call = ToolCall(id: "s", name: "status", arguments: Data("{}".utf8))
        let transport = TurnTestTransport(Array(repeating: [.toolCall(call),
            .completed(.init(inputTokens: 10, outputTokens: 2, duration: .zero))], count: 150))
        var events: [TurnRunEvent] = []
        let error = await #expect(throws: (any Error).self) {
            try await runner.run(.init(prompt: "Check", route: .modelLoop(transport: transport, contextWindow: nil),
                                       budget: .off)) { events.append($0) }
        }
        #expect((error as? AutomationFailure)?.description.contains("100 rounds") == true)
        #expect(runner.toolCalls == 100)
        #expect(events.filter { event in
            if case .tool(let text) = event { text.hasPrefix("→ status") } else { false }
        }.count == 100)
        #expect(runner.rounds == 101)
        #expect(events.filter { if case .usage = $0 { true } else { false } }.count == 1)
        try await runner.close()
    }
}
