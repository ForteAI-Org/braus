import Foundation
import EngineCore

/// AutomationCallInterruption carries a host's human-takeover request through one tool task.
/// Only an explicitly marked opening scene read may retain an opened session after cancellation.
@MainActor
public final class AutomationCallInterruption {
    @TaskLocal
    public static var current: AutomationCallInterruption?

    public private(set) var isReadingOpeningScene = false
    public private(set) var wasInterrupted = false

    public nonisolated let wait = InterruptibleWait()

    public init() {}

    /// Requests the engine's stop without requiring the host to import its low-level types.
    public nonisolated func requestWaitStop() { wait.requestStop() }

    /// Binds the low-level wait without exposing an engine dependency to the host.
    public func withWait<T>(_ body: () async throws -> T) async rethrows -> T {
        try await InterruptibleWait.$current.withValue(wait, operation: body)
    }

    /// Marks the reason before the host cancels the task at a safe boundary.
    public func interruptForHumanControl() { wasInterrupted = true }

    /// Marks only the read after launch, adoption and window movement have completed.
    public static func openingScene<T>(
        _ read: @MainActor () async throws -> T
    ) async throws -> T {
        let call = current
        call?.isReadingOpeningScene = true
        defer { call?.isReadingOpeningScene = false }
        try Task.checkCancellation()
        return try await read()
    }
}
