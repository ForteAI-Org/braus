//
//  RecallConfiguration.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation
import LocalEmbedding
import Memory

/// RecallConfiguration is how the Recall searches: the channel, the local model of the semantic channel and the
/// folder its files are installed in, the document format, the thresholds of each channel and the weight of the
/// lexical score in the combined one. The defaults are the configuration the D3 comparison chose
/// (Documentation/Engine/MemoryRecall.md); `MECUM_RECALL` and `MECUM_RECALL_MODELS` override them for a process,
/// for the comparison itself and for diagnosis. The model's files are installed by an explicit setup step; when
/// they are missing the semantic channel is unavailable and the lexical one answers, the answer saying so.
nonisolated public struct RecallConfiguration: Sendable, Equatable {

    public enum Channel: String, Sendable, Equatable, CaseIterable {
        case semantic, lexical, hybrid
    }

    public var channel: Channel
    public var model: EmbeddingModelManifest?
    public var modelsDirectory: URL?
    public var format: RecallDocument.Format
    public var semanticThresholds: SelectionThresholds
    public var lexicalThresholds: SelectionThresholds
    public var hybridThresholds: SelectionThresholds
    /// The lexical score's share of the combined score: `(1 − w) · semantic + w · lexical`.
    public var hybridWeight: Double
    /// How the lexical score weighs a query's words (`LexicalIndex.Weighting`).
    public var lexicalWeighting: LexicalIndex.Weighting
    /// Whether this configuration owns the archive's index. The product's configuration does, in the app, the MCP
    /// server and the command line alike, so their workers build the same generation together. A configuration chosen
    /// for one process by `MECUM_RECALL` (a comparison, a diagnosis) is a guest: its worker keeps the live generations in
    /// line with the catalogue and never starts, abandons or promotes one, and its queries answer over the owner's index,
    /// saying so. Two owners of different configurations on one archive would retire each other's generations.
    public var ownsIndex: Bool = true

    public init(channel: Channel, model: EmbeddingModelManifest?, modelsDirectory: URL?, format: RecallDocument.Format,
                semanticThresholds: SelectionThresholds, lexicalThresholds: SelectionThresholds, hybridThresholds: SelectionThresholds,
                hybridWeight: Double, lexicalWeighting: LexicalIndex.Weighting = .uniform) {
        self.channel            = channel
        self.model              = model
        self.modelsDirectory    = modelsDirectory
        self.format             = format
        self.semanticThresholds = semanticThresholds
        self.lexicalThresholds  = lexicalThresholds
        self.hybridThresholds   = hybridThresholds
        self.hybridWeight       = hybridWeight
        self.lexicalWeighting   = lexicalWeighting
    }

    /// The thresholds of the channel that answers.
    public func thresholds(for channel: RecallChannel) -> SelectionThresholds {
        switch channel {
            case .semantic: semanticThresholds
            case .lexical : lexicalThresholds
            default       : hybridThresholds
        }
    }

    /// The folder models are installed in when nothing overrides it: `Models` beside the user's knowledge.
    public static func defaultModelsDirectory(environment: [String: String]) -> URL {
        KnowledgeLocation.support(environment: environment).appendingPathComponent("Models", isDirectory: true)
    }

    /// The configuration of this process: the chosen default, with what the environment overrides.
    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> RecallConfiguration {
        var configuration = Self.chosen
        configuration.modelsDirectory = environment["MECUM_RECALL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultModelsDirectory(environment: environment)
        if let word = environment["MECUM_RECALL"] {
            let parts = word.split(separator: ":").map(String.init)
            if let channel = parts.first.flatMap(Channel.init(rawValue:)) { configuration.channel = channel }
            if parts.count > 1 { configuration.model = EmbeddingModelManifest.known[parts[1]] }
            if configuration.channel == .lexical { configuration.model = nil }
            configuration.ownsIndex = configuration == Self.resolvedDefault(configuration.modelsDirectory)
        }
        return configuration
    }

    /// The chosen configuration with a models folder, to tell an override that changes nothing from one that does.
    static func resolvedDefault(_ modelsDirectory: URL?) -> RecallConfiguration {
        var configuration = Self.chosen
        configuration.modelsDirectory = modelsDirectory
        if configuration.channel == .lexical { configuration.model = nil }
        return configuration
    }

    /// The product's configuration, before any override. It is provisional: the second comparison
    /// (Documentation/Engine/MemoryRecall.md#the-second-comparison) validated no configuration, every one failing its
    /// frozen criteria on the final split. Until one is validated the product keeps, by a rule that reads no final result,
    /// the lexical channel over the labelled documents (it needs no model file, so the Recall works on a fresh install)
    /// with the uniform weighting (a part's score does not depend on the rest of the archive, review F01), at the
    /// thresholds frozen for it on the second development split in `recall-calibration-v2.json`. The semantic and
    /// hybrid channels a process may ask for (`MECUM_RECALL`) use Granite, the best of the development split, at its
    /// frozen thresholds; such a process is a guest of the archive's index.
    public static let chosen = RecallConfiguration(
        channel           : .lexical,
        model             : .graniteEmbedding107MMultilingual,
        modelsDirectory   : nil,
        format            : .labelled,
        semanticThresholds: SelectionThresholds(absolute: 0.82, stepMargin: 0, partMargin: -0.1, adequacy: 0.05, tie: 0.04),
        lexicalThresholds : SelectionThresholds(absolute: 0.62, stepMargin: 0, partMargin: -0.3, adequacy: 0, tie: 0.04),
        hybridThresholds  : SelectionThresholds(absolute: 0.66, stepMargin: 0.1, partMargin: -0.4, adequacy: 0.05, tie: 0.04),
        hybridWeight      : 0.2,
        lexicalWeighting  : .uniform
    )
}
