@testable import AutomationMCP
import AutomationRuntime
import ChatCore
import CryptoKit
import Foundation
import LocalMCP
import ModelTransports
import Testing
@testable import Turn

@MainActor
@Suite("SystemPrompt TurnRunner")
struct TurnRunnerSystemPromptTests {
    @Test(arguments: [true, false])
    func samePromptForEveryProviderAndEntry(_ allowsSuspension: Bool) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root, allowsSuspension: allowsSuspension)
        var systems: [String] = []
        for provider in [ChatProvider.claude, .codex] {
            let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: provider,
                executable: URL(filePath: "/bin/cat"), model: nil, effort: nil, environment: [:],
                allowsWebSearch: false), role: "Help with care.")
            systems.append(runner.providerTurn(request, prompt: "Hello", session: nil,
                connection: root.appending(path: "fake.json")).instructions)
        }
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil), role: "Help with care.")) { _ in }
        systems.append(try #require(transport.messages.first?.first?.text))
        #expect(Set(systems).count == 1)
        #expect(systems[0].contains("## Identity"))
        #expect(systems[0].contains("Scene: <scene>"))
        #expect(systems[0].contains("gesture · effect · recovery"))
        try await runner.close()
    }

    @Test func textOnlyTurnHasNoAutomationInstructions() {
        #expect(TurnRunner.systemPrompt(role: "Help.", hasTools: false, searchesWeb: true,
            tools: "Unavailable", toolNames: []) == TurnInstructions.compose(role: "Help.",
                hasTools: false, searchesWeb: true))
    }

    @Test func sharedRulesHaveOneOwnerAndNoLegacyTaskTool() {
        let definitions = AutomationTools.definitions(for: .all)
        let text = TurnRunner.systemPrompt(role: nil, tools: AutomationTools.instructions,
            toolNames: definitions.compactMap { $0["name"].string })
        #expect(!text.contains("memory_task"))
        #expect(!definitions.contains { $0["name"].string == "memory_task" })
        let descriptions = definitions.compactMap { $0["description"].string }.joined(separator: "\n").lowercased()
        for rule in ["if the object is missing, say so", "claim success only with evidence"] {
            #expect(descriptions.components(separatedBy: rule).count == 1)
            #expect(text.lowercased().components(separatedBy: rule).count == 2)
        }
        #expect(text.contains("Before acting, open the task with `plan`"))
        #expect(text.contains("After checking, close with `end` and a result check"))
        #expect(text.contains("Pass step:\"r1\" on gestures or batches; step is an argument, not a tool"))
    }
}

@MainActor
@Suite("SystemPrompt fixed part budget")
struct FixedPartBudgetTests {
    @Test func fixedPartBudgetWithRealPrompt() throws {
        for channels: AutomationChannels in [[], .all] {
            for searchesWeb in [false, true] {
                let tools = AutomationTools(session: TurnTestSession(), channels: channels)
                let definitions = tools.toolDefinitions
                let text = productPrompt(tools, definitions: definitions, searchesWeb: searchesWeb)
                let bytes = try ToolCatalogue.fixedPartBytes(instructions: text, definitions: definitions)
                print("EA1_FIXED channels=\(channels) searchesWeb=\(searchesWeb) bytes=\(bytes)")
                #expect(ToolCatalogue.fixedPartCeiling == 15_360)
                #expect(try ToolCatalogue.isFixedPartWithinBudget(instructions: text, definitions: definitions))
            }
        }
    }

    @Test func coreSizeWithRealPrompt() throws {
        let tools = AutomationTools(session: TurnTestSession(), channels: .all)
        let definitions = tools.toolDefinitions
        let names = definitions.compactMap { $0["name"].string }
        #expect(names == ToolList.core.map(\.rawValue))
        let text = productPrompt(tools, definitions: definitions, searchesWeb: false)
        let bytes = try ToolCatalogue.fixedPartBytes(instructions: text, definitions: definitions)
        let digest = SHA256.hash(data: Data(text.utf8)
            + (try JSONValue.canonicalEncoder().encode(JSONValue.array(definitions))))
            .map { String(format: "%02x", $0) }.joined()
        print("EA1_CORE channels=all bytes=\(bytes) names=\(names) sha256=\(digest)")
        #expect(bytes <= ToolCatalogue.fixedPartCeiling)
        let approved = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Chat/Fixtures/core-size-approved.json")
        if FileManager.default.fileExists(atPath: approved.path) {
            struct ApprovedSize: Decodable { let bytes: Int }
            let size = try JSONDecoder().decode(ApprovedSize.self, from: Data(contentsOf: approved))
            if ToolCatalogue.coreSizeWarns(bytes: bytes, approvedBytes: size.bytes) {
                print("WARNING core exceeds the approved size by more than 20 percent")
            }
        } else { print("WARNING core baseline unapproved; bytes=\(bytes)") }
    }

    private func productPrompt(_ tools: AutomationTools, definitions: [JSONValue], searchesWeb: Bool) -> String {
        TurnRunner.systemPrompt(role: nil, searchesWeb: searchesWeb, tools: tools.instructions,
            toolNames: definitions.compactMap { $0["name"].string }, groupIndex: tools.groupIndex,
            guidesEnabled: tools.guidesEnabled)
    }
}
