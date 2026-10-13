//
//  ModelCatalogueTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation
import Testing
@testable import ModelTransports

@Suite("A provider's model catalogue")
struct ModelCatalogueTests {

    /// The shape `codex debug models` prints, cut to the fields the catalogue reads.
    static let codexOutput = Data("""
    {"models": [
      {"slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list", "priority": 7,
       "default_reasoning_level": "xhigh",
       "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}]},
      {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide", "priority": 3,
       "supported_reasoning_levels": [{"effort": "low"}]},
      {"slug": "gpt-6-sol", "display_name": "GPT-6-Sol", "visibility": "list", "priority": 0,
       "default_reasoning_level": "medium",
       "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"},
                                      {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}, {"effort": "turbo"}]}
    ]}
    """.utf8)

    @Test("Codex's listed models come in priority order with their own levels, hidden ones and unknown levels left out")
    func codexCatalogueReadsTheCLI() throws {
        let models = try ProviderCatalog.codexCatalogue(from: Self.codexOutput)

        #expect(models.map(\.id) == ["gpt-6-sol", "gpt-5.5"])
        #expect(models[0].title == "GPT-6-Sol")
        #expect(models[0].efforts == [.low, .medium, .high, .xhigh, .max, .ultra])
        #expect(models[0].defaultEffort == .medium)
        #expect(models[1].efforts == [.low, .medium, .high, .xhigh])
        #expect(models[1].defaultEffort == .xhigh)
    }

    @Test("Output that is not a catalogue is an error, not an empty list")
    func codexCatalogueRefusesNoise() {
        #expect(throws: (any Error).self) { try ProviderCatalog.codexCatalogue(from: Data("login required".utf8)) }
    }

    /// What `claude -p --input-format stream-json` prints for `initialize`, cut to the fields
    /// the catalogue reads, after a line of another kind.
    static let claudeOutput = Data("""
    {"type":"system","subtype":"hook_started"}
    {"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[ \
      {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}, \
      {"value":"claude-opus-5","resolvedModel":"claude-opus-5","displayName":"Opus 5","supportedEffortLevels":["low","medium","high","xhigh","max"]}, \
      {"value":"claude-opus-5-20260601","resolvedModel":"claude-opus-5-20260601","displayName":"Opus 5 again"}, \
      {"value":"claude-opus-4-6","resolvedModel":"claude-opus-4-6","displayName":"Opus 4.6","supportedEffortLevels":["low","medium","high","max","turbo"]} \
    ]}}}
    """.utf8)

    @Test("Claude Code's models come in its order by resolved id, once each, with their own levels")
    func claudeCatalogueReadsTheCLI() throws {
        let models = try ProviderCatalog.claudeCatalogue(from: Self.claudeOutput)

        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5", "claude-opus-5", "claude-opus-4-6"])
        #expect(models.map(\.title) == ["Opus 5.5", "Haiku 4.5", "Opus 5", "Opus 4.6"])
        #expect(models[0].efforts == [.low, .medium, .high, .xhigh, .max])
        #expect(models[1].efforts.isEmpty, "Haiku takes no effort")
        #expect(models[3].efforts == [.low, .medium, .high, .max], "an unknown level is left out")
    }

    /// An `initialize` answer carrying `rows`, on the one line the command line prints it.
    private static func claudeAnswer(_ rows: String) -> Data {
        let line = rows.replacing("\n", with: "")
        return Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[\#(line)]}}}"#.utf8)
    }

    @Test("The model the default row resolves to comes first, under the name of its own row")
    func claudeCatalogueStartsOnTheDefault() throws {
        let models = try ProviderCatalog.claudeCatalogue(from: Self.claudeAnswer("""
        {"value":"default","resolvedModel":"claude-sonnet-5-5","displayName":"Default (recommended)"},
        {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5"},
        {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5","supportedEffortLevels":["low","high"]},
        {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}
        """))

        #expect(models.map(\.id) == ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5"])
        #expect(models[0].title == "Sonnet 5.5")
        #expect(models[0].efforts == [.low, .high])
    }

    @Test("A default that no other row lists is listed first, named by its id")
    func claudeCatalogueListsAnUnlistedDefault() throws {
        let models = try ProviderCatalog.claudeCatalogue(from: Self.claudeAnswer("""
        {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5"},
        {"value":"default","resolvedModel":"claude-fable-5-1","supportedEffortLevels":["medium"]}
        """))

        #expect(models.map(\.id) == ["claude-fable-5-1", "claude-opus-5-5"])
        #expect(models[0].title == "Fable 5.1")
        #expect(models[0].efforts == [.medium])
    }

    @Test("A model listed again with the 1M tag is one model, and a default with the tag starts on it")
    func claudeCatalogueFoldsTheOneMillionTag() throws {
        let models = try ProviderCatalog.claudeCatalogue(from: Self.claudeAnswer("""
        {"value":"default","resolvedModel":"claude-opus-5-5[1m]","displayName":"Default (recommended)"},
        {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5"},
        {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5"},
        {"value":"opus[1m]","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus 5.5 (1M context)"}
        """))

        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(models[0].title == "Opus 5.5")
    }

    @Test("A Claude id loses only a trailing snapshot date")
    func claudeIDDropsTheSnapshotDate() {
        #expect(ProviderCatalog.claudeID("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ProviderCatalog.claudeID("claude-opus-5-5") == "claude-opus-5-5")
        #expect(ProviderCatalog.claudeID("claude-sonnet-4-20250514") == "claude-sonnet-4")
        #expect(ProviderCatalog.claudeID("claude-20251001-x") == "claude-20251001-x")
        #expect(ProviderCatalog.claudeID("claude-opus-5-5[1m]") == "claude-opus-5-5")
        #expect(ProviderCatalog.claudeID("claude-sonnet-4-20250514[1m]") == "claude-sonnet-4")
    }

    @Test("A model known only by id reads by its family and version, an id of another shape as itself")
    func displayNameReadsTheID() {
        #expect(ModelInfo.displayName(for: "claude-haiku-4-5") == "Haiku 4.5")
        #expect(ModelInfo.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelInfo.displayName(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(ModelInfo.displayName(for: "claude-opus-5") == "Opus 5")
        #expect(ModelInfo.displayName(for: "claude-fable-5-1") == "Fable 5.1")
        #expect(ModelInfo.displayName(for: "gpt-5.4-mini") == "GPT-5.4-Mini")
        #expect(ModelInfo.displayName(for: "gpt-6-sol") == "GPT-6-Sol")
        #expect(ModelInfo.displayName(for: "gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(ModelInfo.displayName(for: "qwen3:8b") == "qwen3:8b")
        #expect(ModelInfo.displayName(for: "claude-3-5-sonnet") == "claude-3-5-sonnet")
        #expect(ModelInfo(id: "claude-opus-5-5", efforts: []).title == "Opus 5.5", "a catalogue without names uses it")
    }

    @Test("Claude Code's output without an answer to initialize is an error, not an empty list")
    func claudeCatalogueRefusesNoise() {
        #expect(throws: (any Error).self) {
            try ProviderCatalog.claudeCatalogue(from: Data(#"{"type":"result","is_error":true}"#.utf8))
        }
    }

    private struct ListingFailed: Error {}

    private static let live = [ModelInfo(id: "claude-opus-5-5", efforts: [.low])]
    private static let kept = [ModelInfo(id: "claude-sonnet-5-5", efforts: [.low])]

    @Test("A listing that came is the catalogue, whatever was kept")
    func resolvedCatalogueIsTheLiveListing() throws {
        let models = try ProviderCatalog.resolvedCatalogue(.success(Self.live), for: .claudeCode, kept: Self.kept)
        #expect(models == Self.live)
    }

    @Test("A listing that failed leaves the catalogue kept from an earlier one")
    func resolvedCatalogueKeepsTheKeptOne() throws {
        let models = try ProviderCatalog.resolvedCatalogue(.failure(ListingFailed()), for: .claudeCode, kept: Self.kept)
        #expect(models == Self.kept)
    }

    @Test("A listing that failed with nothing kept leaves the provider's fixed list, one that is empty counting as nothing")
    func resolvedCatalogueFallsBackToTheFixedList() throws {
        for kept in [nil, []] as [[ModelInfo]?] {
            let models = try ProviderCatalog.resolvedCatalogue(.failure(ListingFailed()), for: .claudeCode, kept: kept)
            #expect(models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
            #expect(models[0].efforts == [.low, .medium, .high, .xhigh, .max])
            #expect(models[2].efforts.isEmpty, "Haiku takes no effort")
        }
        let codex = try ProviderCatalog.resolvedCatalogue(.failure(ListingFailed()), for: .codex, kept: nil)
        #expect(codex.map(\.id) == ["gpt-5.6-luna"])
    }

    @Test("A command line that is not installed and a missing key are thrown, kept list or not")
    func resolvedCatalogueRefusesToHideAMissingConnection() {
        let missing: [(ModelProvider, any Error)] = [
            (.claudeCode, ClaudeClientError.unavailable),
            (.codex, CodexClientError.unavailable),
            (.anthropic, ProviderError.missingAPIKey(.anthropic)),
        ]
        for (provider, error) in missing {
            #expect(throws: (any Error).self) {
                try ProviderCatalog.resolvedCatalogue(.failure(error), for: provider, kept: Self.kept)
            }
        }
    }

    @Test("A provider with nothing kept and nothing fixed throws the failure")
    func resolvedCatalogueThrowsWhenThereIsNothingToStandIn() throws {
        #expect(ModelProvider.ollama.defaultModels.isEmpty)
        #expect(throws: ListingFailed.self) {
            try ProviderCatalog.resolvedCatalogue(.failure(ListingFailed()), for: .ollama, kept: nil)
        }
        let models = try ProviderCatalog.resolvedCatalogue(.failure(ListingFailed()), for: .ollama, kept: Self.kept)
        #expect(models == Self.kept)
    }

    @Test("The fixed lists name only models their provider still has")
    func fixedListsAreCurrent() {
        #expect(ModelProvider.claudeCode.defaultModels == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
        #expect(!ModelProvider.codex.defaultModels.contains("gpt-5.4-mini"))
    }

    @Test("Ultra is Codex's alone")
    func ultraIsOfferedOnlyByCodex() {
        #expect(ModelSelection.supportedEfforts(provider: .codex, model: "gpt-6-sol").contains(.ultra))
        for provider in [ModelProvider.claudeCode, .anthropic, .gemini, .ollama] {
            #expect(!ModelSelection.supportedEfforts(provider: provider, model: "any").contains(.ultra))
        }
    }
}
