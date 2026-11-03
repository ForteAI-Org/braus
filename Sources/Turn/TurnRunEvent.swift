import ChatCore
import CLIProviders
import AutomationRuntime

/// TurnRunEvent preserves provider and tool order; usage is emitted once at the end on both routes.
nonisolated public enum TurnRunEvent: Sendable, Equatable {
    case provider(ProviderEvent)
    case tool(String)
    case todo(TodoEvent)
    case processStarted(ChildProcessIdentity)
    case usage(ProviderUsage, TurnTokenUsage)
    case contextReset(ContextState.Reason)
}
