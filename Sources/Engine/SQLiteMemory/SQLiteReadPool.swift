import Memory
import Synchronization

/// SQLiteReadPool publishes readers without a hop through the writer and gates their lifecycle.
/// Its mutex protects only references and callbacks; no database work runs while holding it.
final class SQLiteReadPool: Sendable {
    /// The store owns readers; this registry borrows them to avoid a reader/pool ownership cycle.
    private struct ReaderReference {
        weak var value: SQLiteReader?
    }

    private struct State {
        var readers: [ReaderReference] = []
        var error = MemoryStoreError.unavailable(.notOpened)
        var refusal: SQLiteConnection.Failure?
        var slow: (threshold: Duration, report: @Sendable (SQLiteMemoryStore.SlowOperation) -> Void)?
        var waits: (@Sendable (SQLiteMemoryStore.WaitEvent) -> Void)?
    }

    private let state = Mutex(State())

    func publish(_ readers: [SQLiteReader]) {
        precondition(readers.count == 3)
        state.withLock { $0.readers = readers.map { ReaderReference(value: $0) } }
    }

    func stop(with error: MemoryStoreError) {
        state.withLock {
            $0.readers = []
            $0.error = error
        }
    }

    func reader(for priority: ReadPriority) throws -> SQLiteReader {
        try state.withLock {
            guard !$0.readers.isEmpty else { throw $0.error }
            guard let reader = $0.readers[priority.index].value else {
                throw MemoryStoreError.unavailable(.closed)
            }
            return reader
        }
    }

    func check() throws {
        try state.withLock { if $0.readers.isEmpty { throw $0.error } }
    }

    func refuseRollback(_ refusal: SQLiteConnection.Failure?) {
        state.withLock { $0.refusal = refusal }
    }

    func takeRefusal() -> SQLiteConnection.Failure? {
        state.withLock {
            let refusal = $0.refusal
            $0.refusal = nil
            return refusal
        }
    }

    func observeWaits(_ observer: (@Sendable (SQLiteMemoryStore.WaitEvent) -> Void)?) {
        state.withLock { $0.waits = observer }
    }

    func pausing(attempt: Int, phase: MemoryStoreError.Phase) {
        let observer = state.withLock { $0.waits }
        observer?(.pausing(phase, attempt: attempt))
    }

    func observeSlowOperations(
        threshold: Duration,
        report: (@Sendable (SQLiteMemoryStore.SlowOperation) -> Void)?
    ) {
        state.withLock { $0.slow = report.map { (threshold, $0) } }
    }

    func reportRead(since start: ContinuousClock.Instant) {
        guard let observer = state.withLock({ $0.slow }) else { return }
        let end = ContinuousClock.now
        let duration = start.duration(to: end)
        guard duration >= observer.threshold else { return }
        observer.report(.init(kind: "read", label: SQLiteMemoryStore.operationLabel, duration: duration, endedAt: end))
    }
}
