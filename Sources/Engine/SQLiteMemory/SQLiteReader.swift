import Memory
import SQLiteAmalgamation

/// SQLiteReader owns one connection on its serial executor. A read never hops through the writer.
actor SQLiteReader {
    struct FailedCleanup: Error {
        let primary: any Error
        let fault: MemoryStoreFault
    }

    nonisolated let role: ConnectionRole
    nonisolated let executor: SQLiteConnectionExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let pool: SQLiteReadPool
    private let configuration: SQLiteMemoryStore.Configuration
    private var connection: SQLiteConnection?
    private(set) var busyRetries = 0
    private(set) var waited = Duration.zero

    init(role: ConnectionRole, configuration: SQLiteMemoryStore.Configuration, pool: SQLiteReadPool) {
        self.role = role
        executor = SQLiteConnectionExecutor(role: role)
        self.configuration = configuration
        self.pool = pool
    }

    func open(path: String, role: ConnectionRole) throws {
        let connection = try SQLiteConnection(path: path, mayCreate: false)
        do {
            try connection.disableAutomaticCloseCheckpoint()
            try connection.execute("PRAGMA foreign_keys = ON")
            try connection.execute("PRAGMA synchronous = FULL")
            try connection.execute("PRAGMA query_only = ON")
            try connection.execute("PRAGMA cache_size = -\(role.cacheSizeKiB(in: configuration))")
            let keys = try connection.query("PRAGMA foreign_keys") { $0.integer(0) }.first
            let mode = try connection.query("PRAGMA journal_mode") { try $0.text(0) }.first
            guard keys == 1, mode == "wal" else {
                throw SQLiteConnection.Failure(primary: SQLITE_ERROR, extended: SQLITE_ERROR,
                                               message: "reader requires foreign keys and WAL")
            }
            self.connection = connection
        } catch {
            connection.close()
            throw error
        }
    }

    func close() {
        connection?.close()
        connection = nil
    }

    func releaseMemory() throws {
        try pool.check()
        guard let connection else { throw MemoryStoreError.unavailable(.closed) }
        try connection.releaseMemory()
    }

    /// Copies WAL frames outside a read transaction on the bulk executor.
    func checkpoint(gate: (@Sendable () -> Void)?) throws -> SQLiteMemoryStore.Checkpoint {
        try pool.check()
        guard let connection else { throw MemoryStoreError.unavailable(.closed) }
        let started = ContinuousClock.now
        gate?()
        let before = try connection.checkpoint(mode: SQLITE_CHECKPOINT_NOOP)
        let result = try connection.checkpoint()
        let outcome: SQLiteMemoryStore.Checkpoint.Outcome = result.wasBusy ? .busy
            : (result.checkpointed == result.frames ? .complete : .partial)
        return SQLiteMemoryStore.Checkpoint(
            frames: result.frames,
            checkpointedFrames: result.checkpointed,
            framesCopied: max(0, max(0, result.checkpointed) - max(0, before.checkpointed)),
            outcome: outcome,
            duration: ContinuousClock.now - started
        )
    }

    func read<T: Sendable>(_ body: @Sendable (SQLiteSnapshot) throws -> T) async throws -> T {
        let started = ContinuousClock.now
        defer { pool.reportRead(since: started) }
        var cycle = SQLiteMemoryStore.WaitingCycle(configuration)
        defer { waited += cycle.waited }
        while true {
            try pool.check()
            guard let connection else { throw MemoryStoreError.unavailable(.closed) }
            if Task.isCancelled { throw MemoryStoreError.cancelled(.begin) }
            cycle.attempting()
            do {
                return try attempt(on: connection, body)
            } catch let error as MemoryStoreError {
                guard case .contention(let fault, _, _) = error else { throw error }
                guard let pause = cycle.nextPause else {
                    throw MemoryStoreError.contention(fault, attempts: cycle.attempts, waited: cycle.waited)
                }
                pool.pausing(attempt: cycle.attempts, phase: fault.phase)
                let now = ContinuousClock.now
                do {
                    try await Task.sleep(for: pause)
                } catch {
                    cycle.interrupted(after: now.duration(to: .now))
                    throw MemoryStoreError.cancelled(fault.phase)
                }
                cycle.paused(for: now.duration(to: .now))
                busyRetries += 1
            }
        }
    }

    private func attempt<T>(
        on connection: SQLiteConnection,
        _ body: (SQLiteSnapshot) throws -> T
    ) throws -> T {
        var phase = MemoryStoreError.Phase.begin
        do {
            try connection.execute("BEGIN")
            phase = .statement
            let value = try body(SQLiteSnapshot(connection: connection))
            phase = .commit
            try connection.execute("COMMIT")
            return value
        } catch {
            let cleanup: MemoryStoreFault.Cleanup
            if connection.isInTransaction, let refusal = pool.takeRefusal() {
                cleanup = SQLiteMemoryStore.cleanupOutcome(
                    inTransaction: connection.isInTransaction,
                    rollback: { refusal },
                    stillInTransaction: { connection.isInTransaction }
                )
            } else {
                cleanup = SQLiteMemoryStore.endTransaction(on: connection)
            }
            let primary: any Error
            if let failure = error as? SQLiteConnection.Failure {
                if failure.isReadContention {
                    let fault = MemoryStoreFault(
                        code: .init(primary: failure.primary, extended: failure.extended),
                        phase: phase,
                        message: failure.message,
                        cleanup: cleanup
                    )
                    primary = MemoryStoreError.contention(fault, attempts: 1, waited: .zero)
                } else {
                    primary = MemoryStoreError(failure, phase: phase, cleanup: cleanup)
                }
            } else {
                primary = SQLiteMemoryStore.classified(error, phase: phase)
            }
            if case .failed = cleanup {
                let failure = error as? SQLiteConnection.Failure
                let fault = MemoryStoreFault(
                    code: .init(primary: failure?.primary ?? SQLITE_OK, extended: failure?.extended ?? SQLITE_OK),
                    phase: phase,
                    message: failure?.message ?? "the read transaction could not be ended after the body's error",
                    cleanup: cleanup
                )
                pool.stop(with: .unavailable(.failed(fault)))
                throw FailedCleanup(primary: primary, fault: fault)
            }
            throw primary
        }
    }
}
