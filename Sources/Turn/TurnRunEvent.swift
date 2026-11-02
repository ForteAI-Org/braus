import ChatCore
import CLIProviders

/// TurnRunEvent preserves provider and tool order; usage is emitted once at the end on both routes.
nonisolated public enum TurnRunEvent: Sendable, Equatable {
    case provider(ProviderEvent)
    case tool(String)
    case processStarted(ChildProcessIdentity)
    case usage(ProviderUsage, TurnTokenUsage)
    case contextReset(ContextState.Reason)
}
