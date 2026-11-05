import EngineCore
import Foundation
import Memory
import SQLiteMemory

/// CallRecoveryReview pairs an unresolved call with whether a known running executor prevents acknowledgement.
public struct CallRecoveryReview: Identifiable, Sendable {
    public let call: AgentCall
    public let canAcknowledge: Bool
    public var id: String { call.event.eventID }
}

extension MemoryService {
    /// Reads a producer's unresolved history and marks known ended executors before offering recovery.
    /// Missing archives remain absent; reading this list never invokes an application.
    public func callsRequiringReview(source: MemoryEventSource, streamID: String) async throws -> [CallRecoveryReview] {
        guard archiveExists else { return [] }
        if let executor = try await MemoryExecutor.current(memory: self, source: source) {
            await MemoryExecutor.sweep(self, folder: directory, current: executor)
        }
        var reviews: [CallRecoveryReview] = []
        for unresolved in try await unresolvedCalls(source: source, streamID: streamID, excludingExecutor: nil) {
            guard let call = try await call(unresolved.eventID) else { continue }
            let history = try await perform { try await $0.facts.reconciliations(of: unresolved.eventID) }
            let stopped = call.progress.status != .started || history.contains {
                $0.kind == .executorTerminated && $0.declaredBy == .braus
            }
            let executor = try await perform { try await $0.facts.executor(of: unresolved.eventID) }
            let running = executor.flatMap { MemoryExecutor.isRunning($0, in: directory) } == true
            reviews.append(CallRecoveryReview(call: call, canAcknowledge: stopped || !running))
        }
        return reviews
    }

    /// Records one explicit person confirmation. Hosts call this from a person-operated control only.
    /// The store rechecks the producer and execution state atomically; no model tool exposes this authority.
    public func acknowledgeUnresolvedCall(_ eventID: String, source: MemoryEventSource, streamID: String) async throws {
        let at = clock.calendarMS()
        let folder = directory
        _ = try await perform {
            try await $0.facts.acknowledgeUnresolvedCall(eventID, source: source, streamID: streamID, atMS: at,
                executorIsRunning: { MemoryExecutor.isRunning($0, in: folder) })
        }
    }
}
