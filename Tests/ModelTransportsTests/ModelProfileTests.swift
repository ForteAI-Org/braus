import Foundation
import Testing
@testable import ModelTransports

@Suite("ModelProfile")
struct ModelProfileTests {
    private enum EffortParityFixture {
        static let large = [
            "claude-opus-5-5", "claude-opus-5", "claude-opus-4-6", "claude-opus-4-1", "claude-fable-5-1",
        ]
        static let medium = [
            "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4", "gpt-5.6-luna", "gemini-3-pro-preview",
        ]
        static let smallWithoutEffort = [
            "claude-haiku-4-5", "claude-3-5-haiku", "claude-3-5-haiku-latest", "claude-3-haiku", "haiku",
        ]
        static let smallWithEffort = ["gemini-3-flash-preview"]
        static let ids = Array(Set(
            ModelProvider.claudeCode.defaultModels + ModelProvider.anthropic.defaultModels
                + large + medium + smallWithoutEffort + smallWithEffort + [
                    "claude-haiku-4-5-20251001", "claude-sonnet-4-20250514", "claude-opus-5-5[1m]",
                    "claude-opus-5-20260601",
                ]
        )).sorted()
    }

    private func todaysEffortRule(_ id: String) -> Bool { !id.contains("haiku") }

    private func profile(_ id: String, window: Int? = nil) -> ModelProfile {
        ModelProfiles.profile(
            provider: .anthropic,
            modelID: id,
            info: window.map { ModelInfo(id: id, efforts: [], contextWindow: $0) }
        )
    }

    private func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @Test
    func unknownModelGetsThePrudentProfile() {
        let value = profile("unlisted-model")
        #expect(value == ModelProfiles.prudent)
        #expect(value.origin == .prudentDefault)
    }

    @Test
    func noThresholdDependsOnTheNameShape() {
        #expect(profile("unknown-haiku") == ModelProfiles.prudent)
        #expect(profile("unknown-opus") == ModelProfiles.prudent)
    }

    @Test
    func catalogueWindowWins() {
        for id in ["claude-opus-5-5", "unlisted-model"] {
            #expect(profile(id, window: 123_456).contextWindowTokens == 123_456)
        }
    }

    @Test
    func guardIsMinOfProfileAndHalfWindow() {
        for (window, expected) in [(20_000, 10_000), (60_000, 30_000), (200_000, 30_000)] {
            #expect(profile("claude-opus-5-5", window: window).effectiveSessionSwitchGuard == expected)
        }
    }

    @Test
    func veryLargeWindowHasAnAbsoluteCeiling() throws {
        let value = profile("claude-opus-5-5", window: 1_000_000)
        let ceiling = try #require(value.compactionCeilingTokens)
        #expect(min(Double(value.contextWindowTokens) * value.compactionFraction, Double(ceiling)) == 400_000)
    }

    @Test
    func profileIsCodableAndStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let measured = ModelProfile.Origin.measured(revision: "test-revision")
        #expect(try JSONDecoder().decode(ModelProfile.Origin.self, from: encoder.encode(measured)) == measured)
        for id in ["unlisted-model", "claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"] {
            let value = profile(id)
            let first = try encoder.encode(value)
            #expect(first == (try encoder.encode(value)))
            #expect(try JSONDecoder().decode(ModelProfile.self, from: first) == value)
        }
    }

    @Test
    func effortRuleIsTodaysForEveryListedID() {
        for provider in [ModelProvider.claudeCode, .anthropic] {
            for id in EffortParityFixture.ids {
                let expected: [ReasoningEffort] = todaysEffortRule(id) ? [.low, .medium, .high, .xhigh, .max] : []
                #expect(ModelSelection.supportedEfforts(provider: provider, model: id) == expected)
            }
            for id in ["claude-haiku-9-9", "unlisted-model", "sonnet", "opus", "default",
                       "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-5",
                       "claude-sonnet-4-6", "claude-sonnet-4-5"] {
                #expect(ModelSelection.supportedEfforts(provider: provider, model: id).isEmpty)
                #expect(!profile(id).acceptsEffort)
            }
        }
        #expect(ModelSelection.supportedEfforts(provider: .codex, model: "haiku") == ReasoningEffort.allCases)
        #expect(ModelSelection.supportedEfforts(provider: .gemini, model: "haiku") == [.low, .medium, .high])
        #expect(ModelSelection.supportedEfforts(provider: .ollama, model: "haiku") == [.low, .high])
    }

    @Test
    func requestBodiesUnchanged() throws {
        let schema = Data(#"{"type":"object","properties":{"answer":{"type":"string"}}}"#.utf8)
        let schemaObject = try JSONSerialization.jsonObject(with: schema)
        let tool = ToolDefinition(name: "status", description: "Read status.", parameters: schema)
        for id in EffortParityFixture.ids {
            for effort in ReasoningEffort.allCases {
                let client = AnthropicClient(model: id, effort: effort, apiKey: "fake-test-key")
                var output: [String: Any] = ["format": ["type": "json_schema", "schema": schemaObject]]
                if todaysEffortRule(id) { output["effort"] = effort.rawValue }
                let expected: [String: Any] = [
                    "model": id, "max_tokens": 16000, "output_config": output,
                    "messages": [["role": "user", "content": "Hello"]],
                ]
                #expect(try bytes(client.structuredBody(prompt: "Hello", schema: schema)) == bytes(expected))
                for includeTools in [false, true] {
                    var streamed: [String: Any] = [
                        "model": id, "max_tokens": 16000, "stream": true,
                        "cache_control": ["type": "ephemeral"], "system": "Be helpful.",
                        "messages": [["role": "user", "content": "Hello"]],
                    ]
                    if todaysEffortRule(id) { streamed["output_config"] = ["effort": effort.rawValue] }
                    if includeTools {
                        streamed["tools"] = [[
                            "name": "status", "description": "Read status.", "input_schema": schemaObject,
                        ]]
                    }
                    let actual = try client.requestBody(
                        messages: [
                            TurnMessage(role: .system, text: "Be helpful."),
                            TurnMessage(role: .user, text: "Hello"),
                        ],
                        tools: includeTools ? [tool] : []
                    )
                    #expect(try bytes(actual) == bytes(streamed))
                }
                var arguments = [
                    "-p", "--output-format", "json", "--json-schema", String(decoding: schema, as: UTF8.self),
                    "--model", id, "--tools", "", "--max-turns", "3", "--no-session-persistence",
                    "--disable-slash-commands", "--strict-mcp-config",
                ]
                if todaysEffortRule(id) { arguments += ["--effort", effort.rawValue] }
                #expect(ClaudeCLIClient.completionArguments(model: id, effort: effort, schema: schema) == arguments)
            }
        }
    }

    @Test(arguments: ["claude-haiku-9-9", "unlisted-model"])
    func unknownModelRequestsOmitEffort(_ id: String) throws {
        let schema = Data(#"{"type":"object"}"#.utf8)
        let client = AnthropicClient(model: id, effort: .high, apiKey: "fake-test-key")
        let structured = try client.structuredBody(prompt: "Hello", schema: schema)
        let output = try #require(structured["output_config"] as? [String: Any])
        #expect(output["effort"] == nil)
        let streamed = try client.requestBody(messages: [TurnMessage(role: .user, text: "Hello")], tools: [])
        #expect(streamed["output_config"] == nil)
        #expect(!ClaudeCLIClient.completionArguments(model: id, effort: .high, schema: schema).contains("--effort"))
    }

    @Test
    func tableValuesAreTheInitialOnes() {
        let groups: [(ids: [String], modelClass: ModelProfile.ModelClass, guardTokens: Int, acceptsEffort: Bool)] = [
            (EffortParityFixture.large, .large, 30_000, true),
            (EffortParityFixture.medium, .medium, 20_000, true),
            (EffortParityFixture.smallWithoutEffort, .small, 12_000, false),
            (EffortParityFixture.smallWithEffort, .small, 12_000, true),
        ]
        for group in groups {
            for id in group.ids {
                for provider in ModelProvider.allCases {
                    let value = ModelProfiles.profile(provider: provider, modelID: id, info: nil)
                    #expect(value.modelClass == group.modelClass)
                    #expect(value.contextWindowTokens == 200_000)
                    #expect(value.compactionFraction == 0.9)
                    #expect(value.compactionCeilingTokens == 400_000)
                    #expect(value.sessionSwitchGuardTokens == group.guardTokens)
                    #expect(value.sessionSwitchRoundCeiling == 15)
                    #expect(value.noProgressRoundCeiling == 50)
                    #expect(value.turnTokenBudget == nil)
                    #expect(value.securityNote == nil)
                    #expect(value.acceptsEffort == group.acceptsEffort)
                    #expect(value.origin == .classDefault)
                }
            }
        }
        let prudent = ModelProfiles.prudent
        #expect(prudent.modelClass == .small)
        #expect(prudent.contextWindowTokens == 32_768)
        #expect(prudent.compactionFraction == 0.8)
        #expect(prudent.compactionCeilingTokens == nil)
        #expect(prudent.sessionSwitchGuardTokens == 12_000)
        #expect(prudent.sessionSwitchRoundCeiling == 15)
        #expect(prudent.noProgressRoundCeiling == 50)
        #expect(prudent.turnTokenBudget == nil)
        #expect(prudent.securityNote == nil)
        #expect(!prudent.acceptsEffort)
        #expect(prudent.origin == .prudentDefault)
        for provider in [ModelProvider.anthropic, .claudeCode] {
            for (raw, canonical) in [
                ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
                ("claude-opus-5-5[1m]", "claude-opus-5-5"),
                ("claude-sonnet-4-20250514[1m]", "claude-sonnet-4"),
            ] {
                #expect(ModelProfiles.profile(provider: provider, modelID: raw, info: nil) == profile(canonical))
                #expect(ModelProfiles.profile(provider: .ollama, modelID: raw, info: nil) == prudent)
            }
        }
    }
}
