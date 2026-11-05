@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import ModelTransports
import Testing
import Turn

@MainActor
struct CapabilityPromptTests {
    @Test func fixedPartBudgetAndGroupIndex() throws {
        let tools = AutomationTools(session: TurnTestSession(), channels: .all)
        let names = tools.toolDefinitions.compactMap { $0["name"].string }
        #expect(names == ToolList.core.map(\.rawValue))
        for searchesWeb in [false, true] {
            let text = TurnRunner.systemPrompt(role: nil, searchesWeb: searchesWeb, tools: tools.instructions,
                toolNames: names, groupIndex: tools.groupIndex)
            #expect(text.contains(tools.groupIndex))
            let bytes = try ToolCatalogue.fixedPartBytes(instructions: text, definitions: tools.toolDefinitions)
            print("EA2_FIXED channels=all searchesWeb=\(searchesWeb) bytes=\(bytes) tools=\(names.count)")
            #expect(bytes <= 15_360)
        }
    }

    @Test func systemPromptGetsListAndIndex() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let tools = AutomationTools(session: TurnTestSession())
        let transport = TurnTestTransport([[.delta("Done.")]])
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false), host: host)
        _ = try await runner.run(.init(prompt: "Inspect", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in }
        #expect(host.began == 1)
        let message = try #require(transport.messages.first?.first { $0.role == .system })
        #expect(message.text.contains(tools.groupIndex))
        try await runner.close()
    }

    @Test func runnerUsesInstanceInterruptionClass() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        var entered = false
        host.scope = {
            entered = true
            try await Task.sleep(for: .seconds(30))
        }
        let tools = AutomationTools(session: TurnTestSession(), capabilities: [InterruptibleCapability()])
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true), host: host)
        let transport = TurnTestTransport([[
            .toolCall(.init(id: "one", name: "call", arguments: Data(#"{"name":"demo.read","arguments":{}}"#.utf8)))
        ]])
        let run = Task {
            try await runner.run(.init(prompt: "Read", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try runner.suspend()
        #expect(await runner.waitForCallsToDrain(within: .seconds(1)))
        runner.stop(marksTaskInterrupted: false)
        await #expect(throws: TurnSuspended.self) { try await run.value }
        try await runner.close()
    }
}

private nonisolated struct InterruptibleCapability: CapabilityProviding {
    let family = "demo"
    var contracts: [CapabilityContract] {
        [.init(id: .init(rawValue: "demo.read"), group: "inspection", description: "Read state.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            effect: .read, interruption: .readOnly, verification: .none(reason: "read only"), channel: .braus,
            origin: .registered(provider: "demo"), memory: .capabilityStep, takesSession: false)]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue { .null }
}
