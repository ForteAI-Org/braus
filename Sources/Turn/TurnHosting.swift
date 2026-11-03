import AutomationRuntime
import LocalMCP

/// TurnHosting supplies admission, approval scope and the host's current seat facts.
@MainActor
public protocol TurnHosting: AnyObject {
    func admission(of tool: String, _ arguments: JSONValue) -> String?
    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T
    func turnBegan()
    func turnStopping()
    func seatFacts() -> SeatFacts?
}
