import LocalMCP
import AutomationMCP
import AutomationRuntime
import ChatCore
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests batch contract")
struct BatchSwitchTests {
    @Test func ordinaryTurnServesOneBatchContract() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let tools = AutomationTools(session: TurnTestSession())
        let names = tools.toolDefinitions.compactMap { $0["name"].string }
        #expect(names.contains("plan") && names.contains("end"))
        #expect(names.filter { $0 == "batch" }.count == 1)
        let batch = try #require(tools.toolDefinitions.first { $0["name"].string == "batch" })
        #expect(batch["inputSchema"]["properties"]["steps"]["maxItems"] == .number(20))
        for definition in tools.toolDefinitions {
            #expect(definition["inputSchema"]["properties"].object?["then"] == nil)
        }
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        #expect(host.began == 1 && transport.messages.count == 1)
        try await runner.close()
    }
}
