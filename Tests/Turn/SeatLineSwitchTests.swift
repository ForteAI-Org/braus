import LocalMCP
import AutomationMCP
import AutomationRuntime
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests structured seat facts")
struct SeatLineSwitchTests {
    @Test func structuredFactsAndPromptAreOrdinaryTurnBehavior() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        let messages = try #require(transport.messages.first)
        let system = try #require(messages.first).text
        #expect(!system.contains("call status and observe"))
        #expect(!system.contains("which replaces the status call"))
        #expect(system.contains("Scene: <scene>"))
        #expect(system.contains("gesture · effect · recovery"))
        #expect(try #require(messages.last).text == "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\nHello")
        #expect(host.began == 1)
        try await runner.close()
    }
}
