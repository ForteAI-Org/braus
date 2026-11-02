/// ContextState records why the runner last discarded scene references.
nonisolated public struct ContextState: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case compaction, newSession, sessionSwitch, personHadApp, turnStart
    }
    public private(set) var lastReset: Reason?
    public private(set) var resets = 0
    public init() {}
    mutating func reset(_ reason: Reason) {
        lastReset = reason
        resets += 1
    }
}
