/// TaskEndCheck records the bounded evidence of an end, without asserting the task's goal was proved.
public struct TaskEndCheck: Sendable, Equatable {
    public enum Scope: String, Sendable { case windowPresenceOnly = "window_presence_only", declaredPredicatesOnly = "declared_predicates_only" }
    public let verdict: TodoRevision.RowVerdict
    public let scope: Scope
    /// False includes the existing not-assessed result. Schema 22 has no third state for goal matching.
    public let goalMatch: Bool

    public init(verdict: TodoRevision.RowVerdict, scope: Scope, goalMatch: Bool = false) {
        self.verdict = verdict
        self.scope = scope
        self.goalMatch = goalMatch
    }
}
