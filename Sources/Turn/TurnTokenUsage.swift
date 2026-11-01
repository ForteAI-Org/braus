import ChatCore

/// TurnTokenUsage separates additive token kinds; reasoning is already part of output.
nonisolated public struct TurnTokenUsage: Sendable, Hashable, Codable {
    public var uncachedInput: Int
    public var cacheWrites5m: Int
    public var cacheWrites1h: Int
    public var cacheReads: Int
    public var output: Int
    public var reasoning: Int
    public var total: Int { uncachedInput + cacheWrites5m + cacheWrites1h + cacheReads + output }

    public init(_ reported: ProviderUsage.Tokens) {
        uncachedInput = max(0, reported.input - reported.cacheReads - reported.cacheWrites)
        cacheWrites1h = max(0, min(reported.cacheWrites, reported.cacheWritesHour))
        cacheWrites5m = max(0, reported.cacheWrites - cacheWrites1h)
        cacheReads = reported.cacheReads
        output = reported.output
        reasoning = reported.reasoning
    }

    /// The original count representation, with hour writes contained in all writes.
    public var tokens: ProviderUsage.Tokens {
        .init(input: uncachedInput + cacheWrites5m + cacheWrites1h + cacheReads,
              cacheReads: cacheReads, cacheWrites: cacheWrites5m + cacheWrites1h,
              cacheWritesHour: cacheWrites1h, output: output, reasoning: reasoning)
    }

    public static func + (lhs: Self, rhs: Self) -> Self { Self(lhs.tokens + rhs.tokens) }

    /// Converts a session total to the current process's count before aggregation.
    public static func own(
        _ reported: ProviderUsage,
        session: String?,
        previous: (session: String, tokens: ProviderUsage.Tokens)?
    ) -> ProviderUsage.Tokens {
        let current = reported.tokens
        guard reported.isSessionTotal, let previous, previous.session == session,
              current.input >= previous.tokens.input else { return current }
        let earlier = previous.tokens
        return .init(input: max(0, current.input - earlier.input),
                     cacheReads: max(0, current.cacheReads - earlier.cacheReads),
                     cacheWrites: max(0, current.cacheWrites - earlier.cacheWrites),
                     cacheWritesHour: max(0, current.cacheWritesHour - earlier.cacheWritesHour),
                     output: max(0, current.output - earlier.output),
                     reasoning: max(0, current.reasoning - earlier.reasoning))
    }
}
