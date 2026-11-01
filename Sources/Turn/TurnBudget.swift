/// TurnBudget prepares optional ceilings. Off counts work without stopping it.
nonisolated public struct TurnBudget: Sendable, Equatable {
    public var maximumRounds: Int?
    public var maximumInputTokens: Int?
    public static let off = TurnBudget(maximumRounds: nil, maximumInputTokens: nil)

    public init(maximumRounds: Int?, maximumInputTokens: Int?) {
        self.maximumRounds = maximumRounds
        self.maximumInputTokens = maximumInputTokens
    }
}
