@testable import AutomationMCP
import AutomationRuntime
import ChatCore
import CryptoKit
import Foundation
import LocalMCP
import ModelTransports
import Switches
import Testing
@testable import Turn

@MainActor
@Suite("SystemPrompt TurnRunner")
struct TurnRunnerSystemPromptTests {
    @Test func v1GoldenMatrixAndDefault() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/system-prompt-v1.json")
        let golden = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        var checked = 0
        for bits in 0..<8 {
            let channels = AutomationChannels(rawValue: bits)
            for hasTools in [false, true] {
                for offersWeb in [false, true] {
                    for searchesWeb in [false, true] {
                        for role: String? in [nil, "", "  Help with care. \n"] {
                            let key = "\(bits)/\(hasTools)/\(offersWeb)/\(searchesWeb)/\(role ?? "nil")"
                            for values in [[:], ["prompt": "v1"]] {
                                let text = SwitchBoard.$testing.withValue(SwitchBoard(values: values)) {
                                    TurnRunner.systemPrompt(role: role, hasTools: hasTools,
                                        searchesWeb: searchesWeb, offersWeb: offersWeb,
                                        tools: AutomationTools.instructions(for: channels),
                                        toolNames: AutomationTools.definitions(for: channels).compactMap { $0["name"].string })
                                }
                                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                                #expect(digest == golden[key])
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 192)
    }

    @Test(arguments: [true, false])
    func v2IsTheSameForEveryProviderAndEntry(_ allowsSuspension: Bool) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root, allowsSuspension: allowsSuspension)
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["prompt": "v2", "tool_surface": "v2"])) {
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
        }
        try await runner.close()
    }

    @Test func textOnlyRetainsLegacyWithV2() {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["prompt": "v2"])) {
            #expect(TurnRunner.systemPrompt(role: "Help.", hasTools: false, searchesWeb: true,
                tools: "Unavailable", toolNames: ["observe"]) == TurnInstructions.compose(role: "Help.",
                    hasTools: false, searchesWeb: true, tools: "Unavailable"))
        }
    }

    @Test func switchesKeepSurfaceAndOutcomeIndependent() {
        for surface in ["v1", "v2"] {
            for outcome in ["v1", "v2"] {
                SwitchBoard.$testing.withValue(SwitchBoard(values: ["prompt": "v2", "tool_surface": surface,
                                                                         "outcome": outcome])) {
                    let text = TurnRunner.systemPrompt(role: nil, tools: "Legacy", toolNames: ["observe"])
                    #expect(text.contains("<scene>") == (surface == "v2"))
                    #expect(text.contains("gesture · effect · recovery") == (outcome == "v2"))
                }
            }
        }
    }

    @Test func rulesRemainPresentAcrossFourArms() {
        for version in ["v1", "v2"] {
            for surface in ["v1", "v2"] {
                SwitchBoard.$testing.withValue(SwitchBoard(values: ["prompt": version, "tool_surface": surface])) {
                    let definitions = AutomationTools.definitions(for: .all)
                    let text = TurnRunner.systemPrompt(role: nil, tools: AutomationTools.instructions,
                        toolNames: definitions.compactMap { $0["name"].string })
                    let description = definitions.first { $0["name"].string == "memory_task" }?["description"].string ?? ""
                    #expect(!description.isEmpty)
                    let descriptions = definitions.compactMap { $0["description"].string }.joined(separator: "\n").lowercased()
                    func count(_ phrase: String, in value: String) -> Int {
                        value.lowercased().components(separatedBy: phrase.lowercased()).count - 1
                    }
                    for rule in ["if the object is missing, say so", "claim success only with evidence"] {
                        #expect(count(rule, in: descriptions) == 0)
                        if version == "v2" { #expect(count(rule, in: text) == 1) }
                    }
                    if version == "v2" {
                        for sentence in ["Before acting, begin the app task", "After checking, end with a result check"] {
                            // Prompt v2 with surface v1 retains the legacy description's duplicate task guidance.
                            #expect(count(sentence, in: text) == 1)
                            #expect(count(sentence, in: description) == 0)
                        }
                    }
                    if surface == "v1" {
                        #expect(count("begin: before acting on apps for a new request", in: description) == 1)
                        #expect(count("end: with outcome completed, failed or abandoned", in: description) == 1)
                        let copies = version == "v2" ? 2 : 1
                        #expect(count("Before acting, begin the app task", in: text)
                            + count("begin: before acting on apps for a new request", in: description) == copies)
                        #expect(count("After checking, end with a result check", in: text)
                            + count("end: with outcome completed, failed or abandoned", in: description) == copies)
                    }
                    if surface == "v2" {
                        #expect(count("Before acting, begin the app task", in: text)
                            + count("Before acting on apps for a new request, begin its task", in: description) == 1)
                        #expect(count("After checking, end with a result check", in: text)
                            + count("After checking the result, end the task", in: description) == 1)
                    }
                }
            }
        }
    }
}

@MainActor
@Suite("SystemPrompt fixed part budget")
struct FixedPartBudgetTests {
    @Test(arguments: ["v1", "v2"], ["tool", "in_gestures"])
    func fixedPartBudgetWithRealPrompt(batch: String, batchForm: String) throws {
        for channels: AutomationChannels in [[], .all] {
            for searchesWeb in [false, true] {
                for cycle in ["v1", "v2"] where batch == "v1" || cycle == "v2" {
                    for outcome in ["v1", "v2"] {
                        try SwitchBoard.$testing.withValue(SwitchBoard(values: [
                            "prompt": "v2", "tool_surface": "v2", "outcome": outcome, "task_cycle": cycle,
                            "batch": batch, "batch_form": batchForm
                        ])) {
                            let tools = AutomationTools(session: TurnTestSession(), channels: channels)
                            let definitions = tools.toolDefinitions
                                .filter { $0["name"].string != "human_step" }
                            let text = productPrompt(tools, definitions: definitions, searchesWeb: searchesWeb)
                            let bytes = try ToolCatalogue.fixedPartBytes(instructions: text, definitions: definitions)
                            print("EA1_FIXED prompt=v2 tool_surface=v2 task_cycle=\(cycle) outcome=\(outcome) channels=\(channels) "
                                + "searchesWeb=\(searchesWeb) batch=\(batch) batch_form=\(batchForm) bytes=\(bytes)")
                            #expect(ToolCatalogue.fixedPartCeiling == 15_360)
                            #expect(try ToolCatalogue.isFixedPartWithinBudget(instructions: text, definitions: definitions))
                        }
                    }
                }
            }
        }
    }

    @Test func coreSizeWithRealPrompt() throws {
        try SwitchBoard.$testing.withValue(SwitchBoard(values: [
            "prompt": "v2", "tool_surface": "v2", "task_cycle": "v2", "outcome": "v1"
        ])) {
            let tools = AutomationTools(session: TurnTestSession(), channels: .all)
            let definitions = tools.toolDefinitions.filter { $0["name"].string != "human_step" }
            let names = definitions.compactMap { $0["name"].string }
            #expect(names == ToolList.core.map(\.rawValue))
            let text = productPrompt(tools, definitions: definitions, searchesWeb: false)
            let bytes = try ToolCatalogue.fixedPartBytes(instructions: text, definitions: definitions)
            let digest = SHA256.hash(data: Data(text.utf8)
                + (try JSONValue.canonicalEncoder().encode(JSONValue.array(definitions))))
                .map { String(format: "%02x", $0) }.joined()
            print("EA1_CORE prompt=v2 tool_surface=v2 task_cycle=v2 outcome=v1 channels=all bytes=\(bytes) "
                + "names=\(names) sha256=\(digest)")
            #expect(bytes <= ToolCatalogue.fixedPartCeiling)
            let approved = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Chat/Fixtures/core-size-approved.json")
            if FileManager.default.fileExists(atPath: approved.path) {
                struct ApprovedSize: Decodable { let bytes: Int }
                let size = try JSONDecoder().decode(ApprovedSize.self, from: Data(contentsOf: approved))
                if ToolCatalogue.coreSizeWarns(bytes: bytes, approvedBytes: size.bytes) {
                    print("WARNING core exceeds the approved size by more than 20 percent")
                }
            } else {
                print("WARNING core baseline unapproved; prompt=v2 tool_surface=v2 task_cycle=v2 outcome=v1 bytes=\(bytes)")
            }
        }
    }

    private func productPrompt(
        _ tools: AutomationTools,
        definitions: [JSONValue],
        searchesWeb: Bool
    ) -> String {
        let servedNames = definitions.compactMap { $0["name"].string }
        let names = servedNames.contains("find")
            ? ToolList.names(attendance: tools.toolList.attendance, level: tools.toolList.level).map(\.rawValue)
            : servedNames
        return TurnRunner.systemPrompt(role: nil, searchesWeb: searchesWeb,
            tools: tools.instructions, toolNames: names,
            groupIndex: tools.groupIndex, guidesEnabled: tools.guidesEnabled)
    }

}
