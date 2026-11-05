import AutomationRuntime
import ModelTransports
import LocalMCP

/// TurnHosting supplies admission, approval scope and the host's current seat facts.
@MainActor
public protocol TurnHosting: AnyObject {
    func admission(of tool: String, _ arguments: JSONValue) -> String?
    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T
    func turnBegan()
    func turnStopping()
    func seatFacts() -> SeatFacts?
    func answered(tool: String, result: JSONValue) throws
    func recordResult(_ call: ToolCall, _ result: JSONValue, startedAt: ContinuousClock.Instant) throws
}

extension TurnHosting {
    public func answered(tool: String, result: JSONValue) throws {}
    public func recordResult(_ call: ToolCall, _ result: JSONValue, startedAt: ContinuousClock.Instant) throws {}
}
