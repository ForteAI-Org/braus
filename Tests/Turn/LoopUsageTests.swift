import LocalMCP
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests loop usage") struct LoopUsageTests {
    @Test func tokenPartsAccumulateAcrossRoundsWithoutDuplicatingReasoningOrCache() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        defer { withExtendedLifetime(host) {} }
        let runner = testTurnRunner(host: host, root: root)
        let usage = ModelUsage(inputTokens: 100, outputTokens: 80, duration: .zero,
            cacheReadTokens: 900, cacheWriteTokens: 200, cacheWriteHourTokens: 50, reasoningTokens: 30)
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "read", name: "observe", arguments: Data("{}".utf8))), .completed(usage)],
            [.completed(usage)]
        ])
        let result = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in }
        let tokens = try #require(result.usage)
        #expect(tokens.uncachedInput == 200)
        #expect(tokens.cacheWrites5m == 300)
        #expect(tokens.cacheWrites1h == 100)
        #expect(tokens.cacheReads == 1800)
        #expect(tokens.output == 160)
        #expect(tokens.reasoning == 60)
        #expect(tokens.total == 2560)
        #expect(result.rounds == 2)
        try await runner.close()
    }
}
