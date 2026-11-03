import EngineCore

/// BatchStepBoundary stops only post-delivery waits, retaining the in-flight delivery's result.
@MainActor
public enum BatchStepBoundary {
    @TaskLocal nonisolated private static var active = false
    @TaskLocal nonisolated private static var hostResultWait: InterruptibleWait?

    /// A step's deadline stops post-delivery waits, not the scene that its caller still consumes.
    nonisolated package static var sceneReadWait: InterruptibleWait? {
        active ? hostResultWait : InterruptibleWait.current
    }

    public static func perform<T>(
        until deadline: ContinuousClock.Instant,
        operation: () async throws -> T
    ) async rethrows -> T {
        let stepWait = InterruptibleWait()
        let hostWait = InterruptibleWait.current
        let interruption = AutomationCallInterruption.current
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            stepWait.requestStop()
        }
        let forwarding = Task {
            while !Task.isCancelled {
                if hostWait?.stopRequested == true || interruption?.wasInterrupted == true {
                    stepWait.requestStop()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { return }
            }
        }
        defer { timer.cancel(); forwarding.cancel() }
        return try await $active.withValue(true) {
            try await $hostResultWait.withValue(hostWait) {
                try await InterruptibleWait.$current.withValue(stepWait, operation: operation)
            }
        }
    }
}
