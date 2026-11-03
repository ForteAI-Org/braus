import ChatCore

/// CompactionTrigger identifies who requested context compaction.
nonisolated public enum CompactionTrigger: String, Sendable, Hashable, Codable {
    case manual, automatic
}

/// CompactionOutcome contains context sizes and provider counts without application storage types.
nonisolated public struct CompactionOutcome: Sendable {
    public let trigger: CompactionTrigger
    public let preTokens: Int?
    public let postTokens: Int?
    public let contextWindow: Int?
    public let summary: String?
    public let reported: ProviderUsage?
    public let usage: TurnTokenUsage?
}
