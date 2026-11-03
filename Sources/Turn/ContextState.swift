@_exported import enum AutomationMCP.SceneContextReset

/// ContextState records why the runner last discarded scene references.
nonisolated public struct ContextState: Sendable, Equatable {
    public typealias Reason = SceneContextReset
    public private(set) var lastReset: Reason?
    public private(set) var resets = 0
    public init() {}
    mutating func reset(_ reason: Reason) {
        lastReset = reason
        resets += 1
    }
}
