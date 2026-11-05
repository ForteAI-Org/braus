import AutomationRuntime

/// RouteHandoffHolding releases a staged claim after a handoff attempt without discarding an older app.
@MainActor
public protocol RouteHandoffHolding: AutomationSessionOperating {
    func releaseHandoff() async
}
