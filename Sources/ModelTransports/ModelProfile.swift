/// ModelProfile describes the context limits and thresholds Braus assumes for one model.
/// Values come from a class default unless measured values replace them.
public struct ModelProfile: Sendable, Hashable, Codable {
    /// ModelClass groups models that share initial context thresholds.
    public enum ModelClass: String, Sendable, Codable {
        case small, medium, large
    }

    /// Origin identifies whether values are provisional or come from a measured revision.
    public enum Origin: Sendable, Hashable, Codable {
        case prudentDefault, classDefault, measured(revision: String)
    }

    public let modelClass: ModelClass
    public let contextWindowTokens: Int
    /// The fraction of the context window at which compaction is due, from zero to one.
    public let compactionFraction: Double
    /// An absolute compaction limit in tokens, when one is defined.
    public let compactionCeilingTokens: Int?
    public let sessionSwitchGuardTokens: Int
    public let sessionSwitchRoundCeiling: Int
    public let noProgressRoundCeiling: Int
    /// The prepared per-turn token limit. Nil leaves this limit disabled.
    public let turnTokenBudget: Int?
    /// Information for a person, never a policy input or a security defense.
    public let securityNote: String?
    /// Whether the provider accepts an effort parameter for this exact model id.
    public let acceptsEffort: Bool
    public let origin: Origin

    /// The session guard in tokens, capped at half the context window.
    public var effectiveSessionSwitchGuard: Int {
        min(sessionSwitchGuardTokens, contextWindowTokens / 2)
    }
}

/// ModelProfiles resolves exact catalogue ids to provisional context assumptions.
/// It depends on catalogue values only and performs no storage, network or process work.
public enum ModelProfiles {
    /// The conservative fallback for an id absent from the table, without assuming effort support.
    public static let prudent = ModelProfile(
        modelClass: .small,
        contextWindowTokens: 32_768,
        compactionFraction: 0.8,
        compactionCeilingTokens: nil,
        sessionSwitchGuardTokens: 12_000,
        sessionSwitchRoundCeiling: 15,
        noProgressRoundCeiling: 50,
        turnTokenBudget: nil,
        securityNote: nil,
        acceptsEffort: false,
        origin: .prudentDefault
    )

    private static let small = classProfile(.small, guardTokens: 12_000)
    private static let medium = classProfile(.medium, guardTokens: 20_000)
    private static let large = classProfile(.large, guardTokens: 30_000)

    private static let table: [String: (ModelProfile.ModelClass, acceptsEffort: Bool)] = [
        "claude-opus-5-5": (.large, true),
        "claude-opus-5": (.large, true),
        "claude-opus-4-6": (.large, true),
        "claude-opus-4-1": (.large, true),
        "claude-fable-5-1": (.large, true),
        "claude-sonnet-5-5": (.medium, true),
        "claude-sonnet-5": (.medium, true),
        "claude-sonnet-4": (.medium, true),
        "gpt-5.6-luna": (.medium, true),
        "gemini-3-pro-preview": (.medium, true),
        "claude-haiku-4-5": (.small, false),
        "claude-3-5-haiku": (.small, false),
        "claude-3-5-haiku-latest": (.small, false),
        "claude-3-haiku": (.small, false),
        "haiku": (.small, false),
        "gemini-3-flash-preview": (.small, true),
    ]

    /// Resolves an exact id, normalizing Claude snapshot dates and context tags first.
    /// A catalogue window in tokens takes precedence over the selected profile's window.
    public static func profile(
        provider: ModelProvider,
        modelID: String,
        info: ModelInfo?
    ) -> ModelProfile {
        let id = provider == .claudeCode || provider == .anthropic ? ProviderCatalog.claudeID(modelID) : modelID
        let base: ModelProfile
        let acceptsEffort: Bool
        if let entry = table[id] {
            switch entry.0 {
            case .small: base = small
            case .medium: base = medium
            case .large: base = large
            }
            acceptsEffort = entry.acceptsEffort
        } else {
            base = prudent
            // An empty id selects the provider's default model and preserves its existing effort argument.
            acceptsEffort = modelID.isEmpty || base.acceptsEffort
        }
        return ModelProfile(
            modelClass: base.modelClass,
            contextWindowTokens: info?.contextWindow ?? base.contextWindowTokens,
            compactionFraction: base.compactionFraction,
            compactionCeilingTokens: base.compactionCeilingTokens,
            sessionSwitchGuardTokens: base.sessionSwitchGuardTokens,
            sessionSwitchRoundCeiling: base.sessionSwitchRoundCeiling,
            noProgressRoundCeiling: base.noProgressRoundCeiling,
            turnTokenBudget: base.turnTokenBudget,
            securityNote: base.securityNote,
            acceptsEffort: acceptsEffort,
            origin: base.origin
        )
    }

    private static func classProfile(
        _ modelClass: ModelProfile.ModelClass,
        guardTokens: Int
    ) -> ModelProfile {
        ModelProfile(
            modelClass: modelClass,
            contextWindowTokens: 200_000,
            compactionFraction: 0.9,
            compactionCeilingTokens: 400_000,
            sessionSwitchGuardTokens: guardTokens,
            sessionSwitchRoundCeiling: 15,
            noProgressRoundCeiling: 50,
            turnTokenBudget: nil,
            securityNote: nil,
            acceptsEffort: true,
            origin: .classDefault
        )
    }
}
