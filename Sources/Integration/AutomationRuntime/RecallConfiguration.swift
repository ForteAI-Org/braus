//
//  RecallConfiguration.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation
import LocalEmbedding
import Memory

/// RecallConfiguration is how the Recall searches: the channel, the local model of the semantic channel and the
/// folder its files are installed in, the document format, the thresholds of each channel and the weight of the
/// lexical score in the combined one. The defaults are the configuration the Recall by the agent's choice was measured
/// with (`chosen`). `BRAUS_RECALL_MODELS` supplies the installed model directory.
/// The model's files are installed by an explicit setup step; when they are missing the semantic channel is
/// unavailable and the lexical one answers, the answer saying so.
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
    /// Whether this instance owns the archive's index. Product instances share the chosen configuration;
    /// injected comparison configurations can remain guests without promoting or retiring generations.
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

    /// Resolves the single product configuration and its installed model directory.
    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> RecallConfiguration {
        var configuration = Self.chosen
        configuration.modelsDirectory = environment["BRAUS_RECALL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultModelsDirectory(environment: environment)
        return configuration
    }

    /// The product's configuration, before any override: the one the Recall by the agent's choice was measured with on its
    /// independent holdout (Documentation/Engine/RecallAgentChoice.md, K1–K6 met), now the product's one path. The hybrid
    /// channel over the labelled documents, Granite 107m with the lexical score weighing 0.2, the uniform weighting (a
    /// part's score does not depend on the rest of the archive, review F01), the hybrid thresholds frozen for it in
    /// `recall-calibration-v3.json`. The thresholds only shape the automatic selector's suggestion a proposal shows; the
    /// shortlist does not read them. The model's files come from an explicit setup step into the models folder; until
    /// they are installed, or when they are refused, the lexical index answers, at its own thresholds, and every answer
    /// says the semantic channel is unavailable and why.
    public static let chosen = RecallConfiguration(
        channel           : .hybrid,
        model             : .graniteEmbedding107MMultilingual,
        modelsDirectory   : nil,
        format            : .labelled,
        semanticThresholds: SelectionThresholds(absolute: 0.82, stepMargin: 0, partMargin: -0.1, adequacy: 0.05, tie: 0.04),
        lexicalThresholds : SelectionThresholds(absolute: 0.62, stepMargin: 0, partMargin: -0.3, adequacy: 0, tie: 0.04),
        hybridThresholds  : SelectionThresholds(absolute: 0.68, stepMargin: 0, partMargin: 0, adequacy: 0.05, tie: 0.04),
        hybridWeight      : 0.2,
        lexicalWeighting  : .uniform
    )
}
