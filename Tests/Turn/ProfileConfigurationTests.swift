import LocalMCP
import AutomationMCP
import AutomationRuntime
import Foundation
import ModelTransports
import Testing
@testable import Turn

@MainActor
struct ProfileConfigurationTests {
    @Test func runnerUsesTheCurrentContractWithoutAnActivationProfile() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let tools = AutomationTools(session: TurnTestSession(), profile: .cli)
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools,
            configuration: .init(workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true), host: host)
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in }
        #expect(transport.messages.count == 1)
        #expect(runner.currentTaskState != nil)
        #expect(tools.configurationEvidence["contract"].string == "braus-t2-single-path")
        try await runner.close()
    }
}

extension ProfileConfigurationTests {
    @Test func rejectedRouterRequestIsCountedBeforeDispatch() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let tools = AutomationTools(session: TurnTestSession(), profile: .cli)
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools,
            configuration: .init(workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true), host: host)
        runner.toolRouter.resume()
        let result = await runner.toolRouter.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("memory_task"), "arguments": .object([:])])]))
        #expect(result?["error"] != .null)
        #expect(tools.configurationEvidence["tool_attempts"]["memory_task"] == .number(1))
        try await runner.close()
    }
}
