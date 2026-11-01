//
//  SQLiteMemoryStore.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
import SQLiteAmalgamation
import Synchronization
#if BRAUS_PHASES
import Darwin
import os
#endif

/// SQLiteMemoryStore is the living memory's one SQLite file, opened explicitly at a path the
/// composition root chose and used through typed transactions. A writer and three readers each own
/// a serial executor with fixed QoS. The writer runs every change inside `BEGIN IMMEDIATE ... COMMIT`;
/// readers see committed state independently of it. Between processes the file's own locks serialize
/// writes. Every transaction holds no `await` and is retried with the same identifiers when the lock is busy.
///
/// A write is answered only after its commit. The ordinary `write` holds the work while the lock
/// is busy: the body and the caller's task are the work, and they stay where they are, cycle after
/// cycle of the lock budget, until the commit, the caller's cancellation, the store's close or a
/// failure that is not contention. Nothing is queued elsewhere and nothing is dropped, so nothing
/// is ever reported as saved before it is. `attemptWrite` is the single cycle underneath, for a
/// caller that wants to classify a spent budget itself. Every cycle contains at least one real
/// pause: a configuration that would allow a retry without one is refused at `open`.
///
/// The store never scans or imports JSON, never opens a database elsewhere when the path fails,
/// and never resets or downgrades a file it does not recognise. Waiting for a busy lock happens
/// between attempts, outside any transaction, and honours the caller's cancellation. A `close`
/// prevails over an `open` still waiting: that open ends with `unavailable(.closed)` and lets go of
/// the connection it had, and no handle survives the close. `close` is not a flush: work still
/// waiting ends with that error, so a producer awaits the writes it means to keep before closing.
///
/// After a failure of the device or the file the store looks at the transaction it interrupted,
/// ends it if the library had not, and reports which (`MemoryStoreFault.cleanup`). A transaction
/// it could not end makes the connection untrusted: the store lets go of all connections and
/// answers `unavailable(.failed)` until it is closed, and recovery is a new instance opened on
/// the same path once the cause is removed. Nothing is retried on the store's own initiative.
///
/// A snapshot copies the file through the library's backup API into a path of the caller's,
/// consistent as of one read transaction, verified before it is handed over; a checkpoint moves
/// the write-ahead log into the file passively, never waiting on readers or other processes.
///
/// The store holds the archive's presence lock shared (`SQLiteMemoryPresence`) from before its first
/// connection until its last one, and the last one of a copy still in flight, has closed: a
/// recovery, which takes the lock exclusive, is refused meanwhile, and an open waits for a recovery
/// in progress within one lock budget, then answers `contention`. An open that finds the record of a
/// recovery that stopped half way opens nothing and makes nothing (`interruptedRecovery`).
public actor SQLiteMemoryStore {

    nonisolated let executor = SQLiteConnectionExecutor(role: .writer)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private nonisolated let readPool = SQLiteReadPool()

    /// Configuration is the store's waiting policy, chosen at composition. The defaults are what
    /// the module's tests run with; they are not a measured guarantee of availability. A policy
    /// that would let a cycle end without one real pause is refused at `open` (`problem`).
    public struct Configuration: Sendable, Equatable {

        /// One cycle of waiting for a busy lock: the pauses of the cycle add up to at most this.
        /// A spent cycle is `contention` from `attemptWrite` and another cycle from `write`. It
        /// must cover at least one `retryPause`.
        public var lockBudget: Duration

        /// The pause before the first retry, above zero. Each retry doubles it, up to
        /// `maximumRetryPause`, which must not be shorter.
        public var retryPause: Duration

        public var maximumRetryPause: Duration

        /// Pages one step of a snapshot copies before the store yields to other work and checks
        /// for cancellation. Above zero.
        public var snapshotPagesPerStep: Int32

        /// Page cache budgets, in KiB, applied as negative SQLite cache_size values.
        public var writerCacheKiB: Int32
        public var readerCacheKiB: Int32
        public var bulkCacheKiB: Int32

        /// Passive checkpoint thresholds in WAL frames, during a pause and during continuous work.
        public var checkpointFrames: Int
        public var forcedCheckpointFrames: Int

        public init(
            lockBudget          : Duration = .seconds(2),
            retryPause          : Duration = .milliseconds(5),
            maximumRetryPause   : Duration = .milliseconds(100),
            snapshotPagesPerStep: Int32    = 256,
            writerCacheKiB      : Int32    = 8192,
            readerCacheKiB      : Int32    = 4096,
            bulkCacheKiB        : Int32    = 2048,
            checkpointFrames    : Int      = 1000,
            forcedCheckpointFrames: Int    = 16000
        ) {
            self.lockBudget           = lockBudget
            self.retryPause           = retryPause
            self.maximumRetryPause    = maximumRetryPause
            self.snapshotPagesPerStep = snapshotPagesPerStep
            self.writerCacheKiB = writerCacheKiB
            self.readerCacheKiB = readerCacheKiB
            self.bulkCacheKiB = bulkCacheKiB
            self.checkpointFrames = checkpointFrames
            self.forcedCheckpointFrames = forcedCheckpointFrames
        }

        /// The rule this configuration breaks, or nil when every cycle of waiting it allows holds
        /// at least one real pause and every step of a snapshot copies something.
        public var problem: String? {
            if retryPause <= .zero {
                return "retryPause must be above zero: a retry without a pause is a spin"
            }
            if maximumRetryPause < retryPause {
                return "maximumRetryPause must not be shorter than retryPause"
            }
            if lockBudget < retryPause {
                return "lockBudget must cover at least one retryPause, or a cycle would end without waiting"
            }
            if snapshotPagesPerStep <= 0 {
                return "snapshotPagesPerStep must be above zero"
            }
            if writerCacheKiB <= 0 || readerCacheKiB <= 0 || bulkCacheKiB <= 0 {
                return "connection cache sizes must be above zero"
            }
            if checkpointFrames <= 0 || forcedCheckpointFrames < checkpointFrames {
                return "checkpoint thresholds must be positive and ordered"
            }
            return nil
        }
    }

    /// Diagnostics is what the store can say about itself without reading the schema's rows:
    /// enough to tell an empty archive from an unreadable one, a busy file from a broken one, and
    /// work still waiting from work on disk.
    public struct Diagnostics: Sendable, Equatable {

        public let path              : String
        public let libraryVersion    : String
        public let librarySourceID   : String
        public let schemaVersion     : Int32
        public let journalMode       : String
        public let synchronous       : Int64
        public let foreignKeysEnabled: Bool

        /// Whether this open created the schema in an empty file, as opposed to finding it.
        public let bootstrappedNow: Bool

        /// The migration this open ran on an archive of an earlier schema, nil when it ran none.
        public let migration: Migration?

        /// Committed write transactions since the open.
        public let commits: Int

        /// Pauses taken because a lock was busy, and their total length, since the open.
        public let busyRetries: Int
        public let waited     : Duration

        /// Writes offered through `write` that are waiting for the lock right now: work the store
        /// holds in its callers' tasks, on disk only once `commits` moves.
        public let retainedWrites: Int

        /// Lock budgets that ran out since the open. Each was followed by another cycle of the
        /// same write, never by a dropped one.
        public let exhaustedCycles: Int

        /// The writer's automatic checkpoint threshold, disabled so checkpoints run explicitly.
        public let autoCheckpointFrames: Int64

        /// Explicit checkpoints run since the open, and the last one's report.
        public let checkpoints   : Int
        public let lastCheckpoint: Checkpoint?

        /// Pages emitted to WAL by committed write calls since open and by the latest call.
        public let framesAdded: Int
        public let lastWriteFramesAdded: Int
        /// Logical frames not yet copied and physical WAL allocation, which can remain after a passive checkpoint.
        public let residualWALFrames: Int
        public let walBytes: UInt64
        public let checkpointedFrames: Int
        public let checkpointDuration: Duration
        public let pauseCheckpoints: Int
        public let forcedCheckpoints: Int
        public let lastCheckpointError: MemoryStoreError?
        package let connectionRoles: [ConnectionRole]

        /// Snapshots handed over since the open.
        public let snapshots: Int
        /// Duration of the most recent snapshot attempt, including a failed attempt.
        public let lastSnapshotDuration: Duration?
    }

    /// Checkpoint is the report of one explicit passive checkpoint: how many frames the log held,
    /// how many reached the file, and why not all of them when not all did. Neither outcome but
    /// `complete` is a failure: the rest of the log waits for the next checkpoint.
    public struct Checkpoint: Sendable, Equatable {

        public enum Outcome: Sendable, Equatable {

            /// Every frame reached the file, which was then synced.
            case complete

            /// A reader on an older snapshot, in this or another process, keeps the rest in the log.
            case partial

            /// Another connection was checkpointing; this one did nothing.
            case busy
        }

        public let frames            : Int
        public let checkpointedFrames: Int
        /// Frames newly copied by this checkpoint, excluding those already in the database file.
        public let framesCopied      : Int
        public let outcome           : Outcome
        public let duration          : Duration
    }

    /// Snapshot is the report of one copy handed over at its destination: verified, in rollback
    /// journal mode, self-contained in one file.
    public struct Snapshot: Sendable, Equatable {

        public let destination: URL
        public let pageCount  : Int
        public let pageSize   : Int
        public let steps      : Int
        public let duration   : Duration
    }

    /// WaitEvent is one step of the store's waiting or yielding, offered to the observer a test or
    /// a diagnostic sink installs: a point to synchronize on, not a promise about the file.
    package enum WaitEvent: Sendable, Equatable {

        /// The store is about to pause because the lock was busy at this phase.
        case pausing(MemoryStoreError.Phase, attempt: Int)

        /// A whole lock budget passed without the lock; `write` begins another cycle.
        case cycleExhausted(MemoryStoreError.Phase, attempts: Int, waited: Duration)

        /// The store is about to yield between the steps of a long operation, with this much left.
        case yielding(MemoryStoreError.Phase, remaining: Int)
    }

    public nonisolated let url          : URL
    public nonisolated let configuration: Configuration

    /// Connections this store holds open: four while open, zero once closed or failed, whatever
    /// an open in flight was doing when the close arrived. A snapshot in flight holds two more
    /// until its next step finds the store closed.
    private(set) var liveHandles = 0

    private var writer          : SQLiteConnection?
    private var readers: [SQLiteReader] = []
    private var readerShutdown: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    /// A failure of the final checkpoint or of an open interrupted by close, nil when none occurred.
    public private(set) var lastCloseError: MemoryStoreError?
    private var framesAdded = 0
    private var lastWriteFramesAdded = 0
    private var checkpointedFrames = 0
    private var checkpointDuration = Duration.zero
    private var pauseCheckpoints = 0
    private var forcedCheckpoints = 0
    private var lastCheckpointError: MemoryStoreError?
    private var lifecycle       = Lifecycle.notOpened
    private var opening         : Task<Void, any Error>?
    private var bootstrappedNow = false
    private var migration       : Migration?
    private var commits         = 0
    private var busyRetries     = 0
    private var waited          = Duration.zero
    private var retainedWrites  = 0
    private var exhaustedCycles = 0
    private var checkpoints     = 0
    private var lastCheckpoint  : Checkpoint?
    private var snapshots       = 0
    private var lastSnapshotDuration: Duration?
    private var waitObserver    : (@Sendable (WaitEvent) -> Void)?
    private var slowObserver    : (threshold: Duration, report: @Sendable (SlowOperation) -> Void)?
    private var stepGate        : (@Sendable () async throws -> Void)?
    private var verificationGate: (@Sendable () async -> Void)?
    private var migrationFault  : (@Sendable () throws -> Void)?
    private var presence        : SQLiteMemoryPresence?
    private let clock           = ContinuousClock()

    /// CommitTally counts the write transactions one task committed, through any store, for an owner
    /// that must tell a write that saved nothing from one that saved a part of its work: the owner
    /// binds a tally to `tally` around the work, and every commit of `write` in it counts once.
    package final class CommitTally: Sendable {

        private let count = Mutex(0)

        package init() {}

        package var commits: Int { count.withLock { $0 } }

        fileprivate func committed() { count.withLock { $0 += 1 } }
    }

    /// The tally the commits of the current task count into, when its owner bound one.
    @TaskLocal package static var tally: CommitTally?

    /// WriteTiming adds up, for an owner that measures where a write path's time goes, how long the current task's write
    /// transactions took inside the store, from their begin to their commit, apart from the time they waited to reach it.
    package final class WriteTiming: Sendable {

        private let state = Mutex((transactions: 0, inside: Duration.zero))

        package init() {}

        package var transactions: Int { state.withLock { $0.transactions } }
        package var inside: Duration { state.withLock { $0.inside } }

        fileprivate func add(_ duration: Duration) { state.withLock { $0.transactions += 1; $0.inside += duration } }
    }

    /// The timing the write transactions of the current task add to, when its owner bound one.
    @TaskLocal package static var timing: WriteTiming?

    /// The label the store's operations of the current task are reported with when they are slow: what the measures use
    /// to tell which work held the store while another waited.
    @TaskLocal package static var operationLabel: String?

    /// SlowOperation is one read or write transaction that took at least the observer's threshold inside the store:
    /// every other operation of the store waited for it.
    package struct SlowOperation: Sendable {
        package let kind: String
        package let label: String?
        package let duration: Duration
        package let endedAt: ContinuousClock.Instant
    }

    /// Reports the transactions that take at least `threshold` inside the store, or stops when nil: for the measures only.
    package func observeSlowOperations(threshold: Duration, _ report: (@Sendable (SlowOperation) -> Void)?) {
        slowObserver = report.map { (threshold, $0) }
        readPool.observeSlowOperations(threshold: threshold, report: report)
    }

    private func reportIfSlow(_ kind: String, since started: ContinuousClock.Instant) {
        guard let (threshold, report) = slowObserver else { return }
        let ended = clock.now
        let duration = started.duration(to: ended)
        if duration >= threshold { report(SlowOperation(kind: kind, label: Self.operationLabel, duration: duration, endedAt: ended)) }
    }

    /// Lifecycle is the store's state: `opening` while an open is in flight, so a second open
    /// joins it and a close ends it; `failed` once a connection could not be trusted, until close.
    private enum Lifecycle: Equatable {
        case notOpened, opening, open, closed
        case failed(MemoryStoreFault)
    }

    /// WaitingCycle is one cycle's retry rule apart from the lock and the clock: the attempts made,
    /// the next pause and the pauses taken so far, which the budget bounds. The store gives it what
    /// each pause really lasted; a test gives it chosen lengths and reads the schedule, which no
    /// sleep of the system decides.
    package struct WaitingCycle: Sendable, Equatable {

        package private(set) var attempts = 0
        package private(set) var pause   : Duration
        package private(set) var waited  = Duration.zero

        private let budget      : Duration
        private let maximumPause: Duration

        package init(_ configuration: Configuration) {
            pause        = configuration.retryPause
            budget       = configuration.lockBudget
            maximumPause = configuration.maximumRetryPause
        }

        /// Counts the attempt about to run.
        package mutating func attempting() {
            attempts += 1
        }

        /// The pause to take after a busy attempt, or nil when it would overrun the budget.
        package var nextPause: Duration? {
            waited + pause <= budget ? pause : nil
        }

        /// Counts a pause that lasted `measured` and doubles the next one, up to the maximum.
        package mutating func paused(for measured: Duration) {
            waited += measured
            pause   = min(pause * 2, maximumPause)
        }

        /// Counts the part of a pause a cancellation cut short; no attempt follows it.
        package mutating func interrupted(after measured: Duration) {
            waited += measured
        }
    }

    /// Busy is a library failure met at a phase, thrown inside a `retrying` step so the loop
    /// pauses and tries the step again while keeping the phase for the report.
    private struct Busy: Error {
        let failure: SQLiteConnection.Failure
        let phase  : MemoryStoreError.Phase
    }

    /// Remembers the path and the policy. Nothing is opened until `open`.
    public init(url: URL, configuration: Configuration = Configuration()) {
        self.url           = url
        self.configuration = configuration
    }

    /// Opening is what an open may do to the file it finds. `producer` is the open of whoever
    /// writes the memory: it creates a missing file and bootstraps the current schema in an empty one, as S1
    /// decided. `existingArchive` is the open of a reader: it takes only a file that is already a
    /// Braus archive at the schema this build knows, and never creates the file, bootstraps a
    /// schema or sets the journal of a file it refuses (`uninitialized` for a file with no schema
    /// yet, and every refusal `producer` makes). Both decide on the file as it is when they open it
    /// (the producer under its write lock, the reader in a read transaction, which writes nothing),
    /// so a file that appears, vanishes or changes before the decision is judged as it is then.
    /// `existingCopy` is the open of a copy made to be read through the store (a unification's staging
    /// copy): like a reader it never creates the file and refuses one with no schema, since a copy that
    /// is missing or empty is not the copy that was made; like a producer it migrates an archive of an
    /// earlier schema, the copy being its own. Once open, a store is the same whichever opening made it.
    public enum Opening: Sendable, Equatable {
        case producer
        case existingArchive
        case existingCopy

        /// Whether the open may create the file and bootstrap a schema in it.
        var creates: Bool { self == .producer }

        /// Whether the open may write: bootstrap or migrate.
        var writes: Bool { self != .existingArchive }
    }

    /// Opens and bootstraps a store at the URL, ready for use.
    public static func open(
        at url       : URL,
        configuration: Configuration = Configuration(),
        opening      : Opening = .producer
    ) async throws -> SQLiteMemoryStore {
        let store = SQLiteMemoryStore(url: url, configuration: configuration)
        try await store.open(opening)
        return store
    }

    #if BRAUS_PHASES
    private static let signposter = OSSignposter(subsystem: "dev.forte.Braus.phases", category: "phases")

    private static func recordOpening(at url: URL) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            signposter.emitEvent("memory.open",
                "archive_bytes=\(size) phys_footprint=\(info.phys_footprint) task_info_result=\(result)")
        } catch {
            signposter.emitEvent(
                "memory.open",
                "archive_bytes=-1 phys_footprint=\(info.phys_footprint) task_info_result=\(result) archive_size_error=\(String(describing: error), privacy: .public)"
            )
        }
    }
    #endif

    // MARK: Lifecycle

    /// Opens the writer and the readers, checks the linked library, enables foreign keys, sets WAL
    /// and `synchronous=FULL`, then bootstraps (`producer` only) or verifies the schema under the write
    /// lock (a reader inspects in a read transaction); `existingArchive` creates no file and refuses
    /// one with no schema yet (`Opening`). A second
    /// opener of the same file waits for the first and then finds the schema. Throws without
    /// creating anything when the configuration is refused or the path cannot be opened, and
    /// without touching a file whose schema it does not recognise. A second `open` on the same
    /// instance joins the one in flight, whatever its kind, and shares its answer; an open store answers at once; a
    /// closed one stays closed, and so does one closed while this open was waiting for the lock.
    /// A failed instance stays failed: recovery is a new instance on the same path.
    public func open(_ kind: Opening = .producer) async throws {
        if let problem = configuration.problem {
            throw MemoryStoreError.unavailable(.misconfigured(problem))
        }
        switch lifecycle {
        case .open              : return
        case .closed            : throw MemoryStoreError.unavailable(.closed)
        case .failed(let fault) : throw MemoryStoreError.unavailable(.failed(fault))
        case .opening           : break
        case .notOpened:
            lifecycle = .opening
            opening   = Task { try await self.performOpen(kind) }
        }
        guard let inFlight = opening else { throw MemoryStoreError.unavailable(.closed) }
        do {
            try await inFlight.value
        } catch {
            if lifecycle == .closed { throw MemoryStoreError.unavailable(.closed) }
            throw error
        }
        if lifecycle == .closed { throw MemoryStoreError.unavailable(.closed) }
    }

    /// Closes every connection on its owner executor. A final TRUNCATE is attempted after readers
    /// close; another process can keep it busy. Any close checkpoint error remains in lastCloseError.
    public func close() async {
        if let closing { await closing.value; return }
        let inFlight = opening
        opening?.cancel()
        lifecycle = .closed
        readPool.stop(with: .unavailable(.closed))
        let closing = Task {
            if let inFlight {
                switch await inFlight.result {
                case .success: break
                case .failure(let error):
                    switch error as? MemoryStoreError {
                    case .unavailable(.closed), .cancelled: break
                    default: lastCloseError = Self.maintenanceError(error)
                    }
                }
            }
            await readerShutdown?.value
            await closeReaders()
            if let writer {
                do { _ = try writer.checkpoint(mode: SQLITE_CHECKPOINT_TRUNCATE) }
                catch { lastCloseError = Self.maintenanceError(error) }
                release(writer)
            }
            writer = nil
            releasePresenceWhenIdle()
        }
        self.closing = closing
        await closing.value
    }

    private func closeReaders() async {
        let closingReaders = readers
        readers = []
        for reader in closingReaders {
            await reader.close()
            liveHandles -= 1
        }
        releasePresenceWhenIdle()
    }

    /// Reads connection settings and accumulated waiting, WAL and checkpoint diagnostics.
    public func diagnostics() async throws -> Diagnostics {
        let writer = try writerConnection()
        var readerRetries = 0
        var readerWaited = Duration.zero
        for reader in readers {
            readerRetries += await reader.busyRetries
            readerWaited += await reader.waited
        }
        try stillOpen()
        do {
            return Diagnostics(
                path                : url.path,
                libraryVersion      : SQLiteLibrary.version,
                librarySourceID     : SQLiteLibrary.sourceID,
                schemaVersion       : Int32(try Self.integerPragma(writer, "user_version")),
                journalMode         : try Self.textPragma(writer, "journal_mode"),
                synchronous         : try Self.integerPragma(writer, "synchronous"),
                foreignKeysEnabled  : try Self.integerPragma(writer, "foreign_keys") == 1,
                bootstrappedNow     : bootstrappedNow,
                migration           : migration,
                commits             : commits,
                busyRetries         : busyRetries + readerRetries,
                waited              : waited + readerWaited,
                retainedWrites      : retainedWrites,
                exhaustedCycles     : exhaustedCycles,
                autoCheckpointFrames: try Self.integerPragma(writer, "wal_autocheckpoint"),
                checkpoints         : checkpoints,
                lastCheckpoint      : lastCheckpoint,
                framesAdded         : framesAdded,
                lastWriteFramesAdded: lastWriteFramesAdded,
                residualWALFrames   : max(0, try writer.checkpoint(mode: SQLITE_CHECKPOINT_NOOP).remaining),
                walBytes            : try Self.walBytes(at: url),
                checkpointedFrames  : checkpointedFrames,
                checkpointDuration  : checkpointDuration,
                pauseCheckpoints    : pauseCheckpoints,
                forcedCheckpoints   : forcedCheckpoints,
                lastCheckpointError : lastCheckpointError,
                connectionRoles     : [.writer] + readers.map(\.role),
                snapshots           : snapshots,
                lastSnapshotDuration: lastSnapshotDuration
            )
        } catch {
            throw Self.classified(error, phase: .statement)
        }
    }

    /// Installs, or removes, the observer of the store's waiting. Called on the actor, before the
    /// pause or the yield it announces; it must not call back into the store synchronously.
    package func observeWaits(_ observer: (@Sendable (WaitEvent) -> Void)?) {
        waitObserver = observer
        readPool.observeWaits(observer)
    }

    /// A test's seam into the cleanup, for the package's tests only (never public): the next rollback
    /// the store runs after a failure inside a transaction is not run, and answers the library's code
    /// and message given here instead. The connection stays inside its transaction, as after a
    /// rollback that truly failed, and the store's own decision (`cleanupOutcome`) and its
    /// consequences (`invalidate`) follow unchanged. One use; nothing is broken on the device, so what
    /// it proves is the store's path and its owner's, not a real fault.
    package func refuseNextRollback(primary: Int32, extended: Int32, message: String) {
        readPool.refuseRollback(SQLiteConnection.Failure(primary: primary, extended: extended, message: message))
    }

    /// The same seam, with the library's failure as the module's own type.
    func refuseNextRollback(with failure: SQLiteConnection.Failure) {
        readPool.refuseRollback(failure)
    }

    /// A test's seam into a snapshot, for the package's tests only: awaited between two steps of every
    /// copy, after the yield, while the copy holds its connections and its partial file. The store is
    /// free meanwhile, so a close can run; the copy sees it, or its task's cancellation, when the gate
    /// returns or throws.
    package func holdSnapshots(between gate: (@Sendable () async throws -> Void)?) {
        stepGate = gate
    }

    /// A test's seam into a snapshot, for the package's tests only: awaited off the store before the finished copy is
    /// checked, while the copy holds its connection and its partial file.
    package func holdVerifications(_ gate: (@Sendable () async -> Void)?) {
        verificationGate = gate
    }

    /// A value one task owns and hands to another while it waits for it: the copy's connection, which only the
    /// snapshot that opened it uses.
    private struct Unshared<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: Transactions

    /// Runs the body inside one write transaction and answers after its commit, holding the work
    /// while the lock is busy. The work is the body and its inputs, owned by the caller's task; it
    /// is offered again with the same identifiers at every cycle of the lock budget, and it ends
    /// only with the commit, the caller's cancellation, the store's close or a failure that is
    /// not contention. Order is the caller's: its next write is offered after this one's answer.
    /// Nothing is queued elsewhere, so nothing is reported as saved before it is; a body that
    /// throws rolls the transaction back and its error is answered unchanged.
    package func write<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) async throws -> T {
        retainedWrites += 1
        defer { retainedWrites -= 1 }
        let limit = Self.cycleLimit
        var cycles = 0
        while true {
            do {
                return try await attemptWrite(body)
            } catch MemoryStoreError.contention(let fault, attempts: let attempts, waited: let cycleWaited) {
                exhaustedCycles += 1
                cycles += 1
                waitObserver?(.cycleExhausted(fault.phase, attempts: attempts, waited: cycleWaited))
                if let limit, cycles >= limit {
                    throw MemoryStoreError.contention(fault, attempts: attempts, waited: cycleWaited)
                }
            }
        }
    }

    /// The most lock budgets a `write` of the current task waits through before it answers `contention`,
    /// when its owner bound one: an essential write, which an action waits for, is bounded; an ordinary
    /// one, bound to nothing, waits until the lock goes.
    @TaskLocal package static var cycleLimit: Int?

    /// One cycle of `write`: begins, runs the body, commits, waiting for a busy lock only within
    /// the configured budget and answering `contention` when it is spent, with nothing written.
    /// The body runs again on each attempt of the cycle. For a caller that classifies the spent
    /// budget itself; the ordinary path is `write`.
    package func attemptWrite<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) async throws -> T {
        let writer  = try writerConnection()
        let started = clock.now
        let committed: (value: T, cacheWritesBefore: Int)
        do {
            committed = try await transaction(
                on: writer,
                begin: "BEGIN IMMEDIATE",
                phase: .statement,
                didCommit: { self.recordWAL(on: writer, since: $0.cacheWritesBefore) }
            ) {
                let before = try writer.cacheWrites()
                return (value: try body(SQLiteTransaction(connection: writer)), cacheWritesBefore: before)
            }
        } catch {
            await readerShutdown?.value
            throw error
        }
        commits += 1
        Self.tally?.committed()
        Self.timing?.add(started.duration(to: clock.now))
        reportIfSlow("write", since: started)
        return committed.value
    }

    /// Maintenance follows the commit synchronously so another writer cannot enter its accounting interval.
    private func recordWAL(on writer: SQLiteConnection, since before: Int) {
        do {
            lastWriteFramesAdded = max(0, try writer.cacheWrites() - before)
            framesAdded += lastWriteFramesAdded
            let status = try writer.checkpoint(mode: SQLITE_CHECKPOINT_NOOP)
            if status.remaining > configuration.forcedCheckpointFrames {
                _ = try checkpoint()
                forcedCheckpoints += 1
            }
        } catch {
            // The commit already succeeded. Report maintenance failure without inviting a replay.
            lastCheckpointError = Self.maintenanceError(error)
        }
    }

    private static func maintenanceError(_ error: any Error) -> MemoryStoreError {
        if let error = error as? MemoryStoreError { return error }
        if let failure = error as? SQLiteConnection.Failure { return MemoryStoreError(failure, phase: .checkpoint) }
        return .failed(MemoryStoreFault(code: .init(primary: 0, extended: 0), phase: .checkpoint,
                                       message: String(describing: error)))
    }

    /// Runs the body on the reader inside one deferred transaction: every query in it sees the same
    /// committed state, and the transaction ends when the body returns. A write in progress on
    /// another connection is neither seen nor waited for; a busy answer, rare in WAL, is waited
    /// for within one budget.
    package nonisolated func read<T: Sendable>(
        priority: ReadPriority = .common,
        _ body: @Sendable (SQLiteSnapshot) throws -> T
    ) async throws -> T {
        let reader = try readPool.reader(for: priority)
        do {
            return try await reader.read(body)
        } catch let failure as SQLiteReader.FailedCleanup {
            await failRead(with: failure.fault)
            throw failure.primary
        }
    }

    private func failRead(with fault: MemoryStoreFault) async {
        invalidate(with: fault)
        await readerShutdown?.value
    }

    /// Reads a cache token from the reserved reader, whose data_version values are comparable.
    public nonisolated func dataVersion() async throws -> Int64 {
        try await read(priority: .critical) { snapshot in
            try snapshot.query("PRAGMA data_version") { $0.integer(0) ?? 0 }.first ?? 0
        }
    }

    /// Reads the cache token before the body, in one transaction on the reserved reader.
    package nonisolated func readVersioned<T: Sendable>(
        _ body: @Sendable (SQLiteSnapshot) throws -> T
    ) async throws -> (version: Int64, value: T) {
        try await read(priority: .critical) { snapshot in
            let version = try snapshot.query("PRAGMA data_version") { $0.integer(0) ?? 0 }.first ?? 0
            return (version, try body(snapshot))
        }
    }

    /// Releases unused page cache memory on each connection's own executor.
    public func releaseMemory() async throws {
        let writer = try writerConnection()
        try writer.releaseMemory()
        for reader in readers { try await reader.releaseMemory() }
        try stillOpen()
    }

    // MARK: Checkpoint

    /// Runs one passive checkpoint on the writer: frames of the log are copied into the file as far
    /// as no reader, in this process or another, still needs them; nothing is waited for and the
    /// log is neither truncated nor restarted, so other processes on the file are never assumed
    /// absent. A partial or busy outcome is reported, not thrown. Automatic checkpoints are disabled.
    public func checkpoint() throws -> Checkpoint {
        let writer  = try writerConnection()
        let started = clock.now
        do {
            let before = try writer.checkpoint(mode: SQLITE_CHECKPOINT_NOOP)
            let result  = try writer.checkpoint()
            let outcome: Checkpoint.Outcome
            if result.wasBusy {
                outcome = .busy
            } else {
                outcome = result.checkpointed == result.frames ? .complete : .partial
            }
            let report = Checkpoint(
                frames            : result.frames,
                checkpointedFrames: result.checkpointed,
                framesCopied      : max(0, max(0, result.checkpointed) - max(0, before.checkpointed)),
                outcome           : outcome,
                duration          : clock.now - started
            )
            checkpoints   += 1
            lastCheckpoint = report
            checkpointedFrames += report.framesCopied
            checkpointDuration += report.duration
            lastCheckpointError = nil
            #if BRAUS_PHASES
            Self.signposter.emitEvent("memory.wal",
                "frames=\(report.frames) checkpointed=\(report.checkpointedFrames)")
            #endif
            return report
        } catch let failure as SQLiteConnection.Failure {
            let error = MemoryStoreError(failure, phase: .checkpoint)
            lastCheckpointError = error
            throw error
        }
    }

    /// Runs a passive checkpoint when the caller has observed a pause and the WAL exceeds its threshold.
    /// Continuous writers use the higher forced threshold after their commits instead.
    @discardableResult
    public func checkpointIfDue() throws -> Checkpoint? {
        if Task.isCancelled { return nil }
        let writer = try writerConnection()
        let status = try writer.checkpoint(mode: SQLITE_CHECKPOINT_NOOP)
        guard status.remaining > configuration.checkpointFrames else { return nil }
        let report = try checkpoint()
        pauseCheckpoints += 1
        return report
    }

    private static func walBytes(at url: URL) throws -> UInt64 {
        let path = url.path + "-wal"
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: Snapshot

    /// Copies the file to `destination` through the backup API and answers once the copy is
    /// verified and in place. The copy is consistent as of one read transaction on a connection
    /// of its own, held through every step, so commits by this or another process during the copy
    /// neither appear in it nor restart it; the writer is not stopped. The destination must not be
    /// the store's file or its journals and must not exist: nothing is overwritten. The copy is
    /// built at a temporary path beside the destination that only this call names, checked
    /// (`integrity_check`, `foreign_key_check`, the current schema with every table), put in rollback
    /// journal mode so it is one self-contained file, and then renamed into place without
    /// clobbering. Any refusal, failure, cancellation between steps or close of the store removes
    /// the temporary files this call created and leaves no copy: an interrupted copy is never
    /// handed over, and nothing is restored from a copy on the store's own initiative.
    public func snapshot(to destination: URL) async throws -> Snapshot {
        let attemptStarted = clock.now
        var completedDuration: Duration?
        defer { lastSnapshotDuration = completedDuration ?? (clock.now - attemptStarted) }
        _ = try writerConnection()
        let target = Self.resolved(destination)
        let own    = Self.resolved(url).path
        guard !["", "-wal", "-shm", "-journal", ".lock", ".recovering"].map({ own + $0 }).contains(target.path) else {
            throw MemoryStoreError.snapshot(.destinationIsTheSource)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MemoryStoreError.snapshot(.destinationExists)
        }
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)")
        var copying = SnapshotResources(partialPath: partial.path)
        do {
            let source = try acquire(url.path, readOnly: true)
            copying.source = source
            try await retrying(phase: .snapshot) { try Self.pin(source) }
            try stillOpen()
            let copy: SQLiteConnection
            do {
                copy = try acquire(partial.path)
            } catch MemoryStoreError.open(let fault) {
                throw MemoryStoreError.snapshot(.destinationUnavailable(
                    MemoryStoreFault(code: fault.code, phase: .snapshot, message: fault.message)
                ))
            }
            copying.copy = copy
            let backup = try SQLiteBackup(from: source, to: copy)
            copying.backup = backup
            var steps     = 0
            var pageCount = 0
            while true {
                if Task.isCancelled { throw MemoryStoreError.cancelled(.snapshot) }
                try stillOpen()
                let pages    = configuration.snapshotPagesPerStep
                let progress = try await retrying(phase: .snapshot) { try backup.step(pages: pages) }
                steps    += 1
                pageCount = progress.pageCount
                if progress.remaining == 0 { break }
                waitObserver?(.yielding(.snapshot, remaining: progress.remaining))
                await Task.yield()
                // The gate's own error is not the copy's: what it waited for is seen at the loop's head.
                if let stepGate { try? await stepGate() }
            }
            try backup.finish()
            copying.backup = nil
            release(source)
            copying.source = nil
            try stillOpen()
            // The checks read the whole copy: on an archive of gigabytes they take tens of seconds. They run off the store,
            // on the copy's own connection, which nothing else uses while this call waits, so every other read and write
            // (an action's essential facts among them) goes on meanwhile.
            let owned = Unshared(copy)
            let gate = verificationGate
            let pageSize = try await Task.detached {
                if let gate { await gate() }
                let pageSize = try Self.verify(copy: owned.value)
                try Self.settle(copy: owned.value)
                return pageSize
            }.value
            release(copy)
            copying.copy = nil
            // A cancellation or a close that arrived while the copy was verified still prevails: a copy
            // is handed over only by a snapshot nobody stopped.
            if Task.isCancelled { throw MemoryStoreError.cancelled(.snapshot) }
            try stillOpen()
            try Self.move(copying.partialPath, to: target.path)
            copying.removeJournals()
            snapshots += 1
            let duration = clock.now - attemptStarted
            completedDuration = duration
            return Snapshot(
                destination: target,
                pageCount  : pageCount,
                pageSize   : pageSize,
                steps      : steps,
                duration   : duration
            )
        } catch {
            copying.abandon(releasing: self)
            throw Self.classified(error, phase: .snapshot)
        }
    }

    /// The connections and files one snapshot holds while it runs, so that every way out lets go
    /// of all of them. The partial path and its journal siblings are named by this call alone.
    private struct SnapshotResources {

        let partialPath: String
        var source     : SQLiteConnection?
        var copy       : SQLiteConnection?
        var backup     : SQLiteBackup?

        /// Ends the copy without handing it over: the backup object first, so the connections can
        /// close, then the files. A finish that fails here is not answered: the primary error is
        /// the one that brought the snapshot here.
        mutating func abandon(releasing store: isolated SQLiteMemoryStore) {
            if let backup { try? backup.finish() }
            backup = nil
            if let copy { store.release(copy) }
            copy = nil
            if let source { store.release(source) }
            source = nil
            for path in family { try? FileManager.default.removeItem(atPath: path) }
        }

        /// Removes the journal siblings a verification may have created beside a finished copy.
        func removeJournals() {
            for path in family.dropFirst() { try? FileManager.default.removeItem(atPath: path) }
        }

        private var family: [String] { ["", "-wal", "-shm", "-journal"].map { partialPath + $0 } }
    }

    /// Opens the read transaction the whole copy reads through. A busy answer leaves no
    /// transaction behind, so `retrying` may run this again.
    private static func pin(_ source: SQLiteConnection) throws {
        try source.execute("BEGIN")
        do {
            _ = try source.query("SELECT count(*) FROM sqlite_schema") { $0.integer(0) }
        } catch {
            rollback(source)
            throw error
        }
    }

    /// Checks the finished copy and answers its page size. Anything short of `ok`, no violation
    /// and exactly the schema expected (the current one, or the earlier one a migration copies) is a
    /// refusal, and the copy is removed by the caller.
    private static func verify(copy: SQLiteConnection, expecting wanted: Inspection = .current) throws -> Int {
        let integrity = try copy.query("PRAGMA integrity_check") { try $0.text(0) ?? "" }
        guard integrity == ["ok"] else { throw MemoryStoreError.snapshot(.copyFailedIntegrityCheck(integrity)) }
        let violations = try copy.query("PRAGMA foreign_key_check") { _ in () }.count
        guard violations == 0 else { throw MemoryStoreError.snapshot(.copyHasForeignKeyViolations(violations)) }
        let expected = try Expected()
        do {
            guard try inspect(copy, expected: expected) == wanted else {
                throw MemoryStoreError.snapshot(.copySchema(.missingTables(expected.tables)))
            }
        } catch MemoryStoreError.schema(let mismatch) {
            throw MemoryStoreError.snapshot(.copySchema(mismatch))
        }
        return Int(try integerPragma(copy, "page_size"))
    }

    /// Leaves the copy in rollback journal mode: its header came from a WAL file, and this folds
    /// any log the verification opened back into the one file before it is handed over.
    private static func settle(copy: SQLiteConnection) throws {
        let mode = try copy.query("PRAGMA journal_mode = DELETE") { try $0.text(0) ?? "" }.first ?? ""
        guard mode == "delete" else {
            throw MemoryStoreError.snapshot(.copyFailedIntegrityCheck([
                "journal_mode could not be set to delete; the copy answered '\(mode)'"
            ]))
        }
    }

    /// Renames the finished copy into place, refusing to replace anything that appeared at the
    /// destination meanwhile.
    private static func move(_ partial: String, to target: String) throws {
        guard renamex_np(partial, target, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw MemoryStoreError.snapshot(.destinationExists) }
            throw MemoryStoreError.snapshot(.destinationUnavailable(MemoryStoreFault(
                code   : MemoryStoreFault.Code(primary: 0, extended: code),
                phase  : .snapshot,
                message: String(cString: strerror(code))
            )))
        }
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: Migrating

    /// Migration is what an open did to an archive of an earlier schema: the version it found, the
    /// version it left, and the name of the verified copy of the archive it took first, beside it.
    public struct Migration: Sendable, Equatable {
        public let fromVersion: Int32
        public let toVersion  : Int32
        public let copyName   : String
        /// The historical shape the archive had (`SQLiteMemorySchema.HistoricalShape`), nil for the part of the one text
        /// its version is.
        public var fromShape: String? = nil
    }

    /// Migrates an archive found at an earlier schema to the current one. First a verified copy of the
    /// archive as it is, beside it (`<name>.schema-<version>-<instant>`), kept: the way back to the
    /// earlier build. Then, in one write transaction, the archive is inspected again under the lock,
    /// the migration text from its version runs, the version is set and recorded with the copy's
    /// name, and the result must be exactly the current shape: anything else rolls the whole
    /// migration back and leaves the archive at its earlier schema, with the copy beside it. Answers
    /// nil when another process migrated it meanwhile; this open's copy is then removed.
    private func migrate(
        _ writer    : SQLiteConnection,
        from found  : Inspection,
        expected    : Expected
    ) async throws -> Migration? {
        let shape: SQLiteMemorySchema.HistoricalShape?
        let version: Int32
        switch found {
            case .previous(let earlier): (shape, version) = (nil, earlier)
            case .historical(let name):
                guard let known = SQLiteMemorySchema.historicalShapes.first(where: { $0.name == name }) else { return nil }
                (shape, version) = (known, known.version)
            default: return nil
        }
        let copyName = "\(url.lastPathComponent).schema-\(shape?.name ?? String(version))-\(Self.stamp(Date()))"
        let copy     = url.deletingLastPathComponent().appendingPathComponent(copyName)
        try await copyBeforeMigration(to: copy, expecting: found)
        try stillOpening()
        let text  = shape == nil ? try SQLiteMemorySchema.migrationText(from: version) : ""
        let nowMS = Self.nowMS()
        let fault = migrationFault
        migrationFault = nil
        // A rebuild renames and drops tables that other tables reference: their foreign keys are checked once, at the end
        // of the transaction (`SQLiteMemorySchema.rebuild`). The pragma takes effect only outside a transaction.
        if shape != nil { try writer.execute("PRAGMA foreign_keys = OFF") }
        defer { if shape != nil { try? writer.execute("PRAGMA foreign_keys = ON") } }
        let migrated = try await transaction(on: writer, begin: "BEGIN IMMEDIATE", phase: .bootstrap) {
            guard try Self.inspect(writer, expected: expected) == found else { return false }
            var created: [String] = []
            if let shape {
                created = try SQLiteMemorySchema.rebuild(writer, from: shape)
            } else {
                try writer.execute(text)
            }
            // What a text cannot derive, derived here in the same transaction: the anchors' label keys, which
            // the projection normalizes, and one rebuild of the Recall's index from the catalogue the archive holds.
            if (shape == nil && version == 1) || created.contains("brain_anchor_label_keys") { try SQLiteBrainRows.fillLabelKeys(writer) }
            try writer.run("INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms) VALUES (NULL, 'migration', ?)",
                           [.integer(nowMS)])
            try fault?()
            // A pragma cannot take a bound value; the version is this module's own constant.
            try writer.execute("PRAGMA user_version = \(SQLiteMemorySchema.version)")
            try writer.run(
                """
                INSERT INTO memory_schema_migrations (to_version, from_version, migrated_at_ms, copy_name)
                VALUES (?, ?, ?, ?)
                """,
                [.integer(Int64(SQLiteMemorySchema.version)), .integer(Int64(version)), .integer(nowMS),
                 .text(copyName)]
            )
            guard try Self.inspect(writer, expected: expected) == .current else {
                throw Self.refusal(.bootstrap, "the migration from schema \(shape?.name ?? String(version)) did not reach the current shape")
            }
            return true
        }
        guard migrated else {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: copy.path + suffix)
            }
            return nil
        }
        return Migration(fromVersion: version, toVersion: SQLiteMemorySchema.version, copyName: copyName, fromShape: shape?.name)
    }

    /// Copies the archive, at its earlier schema, to `target` through the backup API, consistent as of
    /// one read transaction, verified (integrity, foreign keys, exactly that schema), in rollback
    /// journal mode and renamed into place without clobbering. Any failure removes what it made.
    private func copyBeforeMigration(to target: URL, expecting found: Inspection) async throws {
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MemoryStoreError.snapshot(.destinationExists)
        }
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID().uuidString)")
        var copying = SnapshotResources(partialPath: partial.path)
        do {
            // Read-write, though it only reads: a file the journal was just switched to WAL may have no
            // shared-memory file yet, which a read-only connection cannot make.
            let source = try acquire(url.path)
            copying.source = source
            try await retrying(phase: .snapshot) { try Self.pin(source) }
            let copy = try acquire(partial.path)
            copying.copy = copy
            let backup = try SQLiteBackup(from: source, to: copy)
            copying.backup = backup
            while true {
                try stillOpening()
                let pages    = configuration.snapshotPagesPerStep
                let progress = try await retrying(phase: .snapshot) { try backup.step(pages: pages) }
                if progress.remaining == 0 { break }
                await Task.yield()
            }
            try backup.finish()
            copying.backup = nil
            release(source)
            copying.source = nil
            _ = try Self.verify(copy: copy, expecting: found)
            try Self.settle(copy: copy)
            release(copy)
            copying.copy = nil
            try Self.move(copying.partialPath, to: target.path)
            copying.removeJournals()
        } catch {
            copying.abandon(releasing: self)
            throw Self.classified(error, phase: .snapshot)
        }
    }

    /// The calendar instant now, in milliseconds since 1970, for the record of a bootstrap or a migration.
    private static func nowMS() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// An instant as a file name's UTC stamp.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.timeZone   = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    // MARK: Opening

    /// What the inspection of a file found: nothing yet, the schema this build knows, or an earlier
    /// schema it migrates from.
    enum Inspection: Equatable {
        case empty, current
        case previous(Int32)
        /// A historical shape this build migrates from (`SQLiteMemorySchema.historicalShapes`), by name.
        case historical(String)
    }

    /// The open in flight. Every step that waited checks that the store is still opening, so a
    /// close that arrived meanwhile prevails: the connection is let go and the answer is `closed`.
    /// A failure of any other kind, from the first step on (the library, the schema resource, the
    /// first connection), leaves the store not opened with no handle held, so a later open on this
    /// instance may try again.
    private func performOpen(_ kind: Opening) async throws {
        #if BRAUS_PHASES
        defer { Self.recordOpening(at: url) }
        #endif
        defer { opening = nil; releasePresenceWhenIdle() }
        let path = url.path
        let ddl     : String
        let expected: Expected
        let writer  : SQLiteConnection
        do {
            if let unmet = SQLiteLibrary.unmetRequirement() {
                throw MemoryStoreError.unavailable(.library(found: SQLiteLibrary.version, required: unmet.minimumVersion))
            }
            ddl      = try SQLiteMemorySchema.text()
            expected = try Expected()
            // A reader of a file that is not there makes nothing beside it, not even the lock file.
            if !kind.creates, !FileManager.default.fileExists(atPath: path) {
                if let pending = SQLiteMemoryRecovery.pending(of: url) {
                    throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
                }
                throw MemoryStoreError(SQLiteConnection.Failure(
                    primary: SQLITE_CANTOPEN, extended: SQLITE_CANTOPEN, message: "unable to open database file"
                ), phase: .open)
            }
            try await takePresence()
            // Under the shared presence no recovery is in progress, so a record beside the archive is one
            // that stopped half way: nothing opens the archive, or makes an empty one, until a recovery
            // completes it from that record.
            if let pending = SQLiteMemoryRecovery.pending(of: url) {
                throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
            }
            // Without the create flag the library itself refuses a file that is not there when it opens.
            writer   = try acquire(path, mayCreate: kind.creates)
        } catch {
            throw abandonedOpen(after: error)
        }
        do {
            // Inspect before touching the journal mode, so a file this build refuses is left as found. A
            // producer inspects under the write lock it may bootstrap under; a reader in a read transaction,
            // since the library writes a header into a zero-byte file at the end of any write transaction.
            let found = try await transaction(on: writer, begin: kind.writes ? "BEGIN IMMEDIATE" : "BEGIN",
                                              phase: .bootstrap) {
                try Self.inspect(writer, expected: expected)
            }
            try stillOpening()
            if found == .empty, !kind.creates {
                // A reader or a copy never makes an archive: a file with no schema yet is refused as found.
                let pages = try Self.integerPragma(writer, "page_count")
                throw MemoryStoreError.schema(.uninitialized(fileIsEmpty: pages == 0))
            }
            if kind == .existingArchive, let version = Self.migratedVersion(found) {
                // A reader never migrates: an archive of an earlier schema is refused as found.
                throw MemoryStoreError.schema(.migrationRequired(found: version, supported: SQLiteMemorySchema.version))
            }
            try await retrying(phase: .open) {
                try Self.setJournal(writer, phase: .open)
            }
            try stillOpening()
            var created = false
            if found == .empty {
                // Another process may have created the schema since the inspection: look again under the lock.
                let nowMS = Self.nowMS()
                created = try await transaction(on: writer, begin: "BEGIN IMMEDIATE", phase: .bootstrap) {
                    guard try Self.inspect(writer, expected: expected) == .empty else { return false }
                    try writer.execute(ddl)
                    // A pragma cannot take a bound value; the version is this module's own constant.
                    try writer.execute("PRAGMA user_version = \(SQLiteMemorySchema.version)")
                    try writer.run(
                        """
                        INSERT INTO memory_schema_migrations (to_version, from_version, migrated_at_ms, copy_name)
                        VALUES (?, 0, ?, NULL)
                        """,
                        [.integer(Int64(SQLiteMemorySchema.version)), .integer(nowMS)]
                    )
                    return true
                }
                try stillOpening()
            }
            var migration: Migration?
            if Self.migratedVersion(found) != nil {
                migration = try await migrate(writer, from: found, expected: expected)
                try stillOpening()
            }
            try writer.execute("PRAGMA cache_size = -\(configuration.writerCacheKiB)")
            for role in [ConnectionRole.reader(index: 0), .reader(index: 1), .bulk] {
                let reader = SQLiteReader(role: role, configuration: configuration, pool: readPool)
                do {
                    try await reader.open(path: path, role: role)
                } catch {
                    await reader.close()
                    throw Self.classified(error, phase: .open)
                }
                readers.append(reader)
                liveHandles += 1
                try stillOpening()
            }
            self.writer = writer
            self.bootstrappedNow = created
            self.migration       = migration
            self.lifecycle       = .open
            readPool.publish(readers)
        } catch {
            await closeReaders()
            release(writer)
            throw abandonedOpen(after: error)
        }
    }

    /// The version of an archive this build migrates, nil for one it opens as it is or bootstraps.
    static func migratedVersion(_ found: Inspection) -> Int32? {
        switch found {
            case .previous(let version): version
            case .historical(let name): SQLiteMemorySchema.historicalShapes.first { $0.name == name }?.version
            case .empty, .current: nil
        }
    }

    /// What an open that did not succeed answers: `closed` when a close arrived meanwhile, which
    /// prevails and stays; otherwise the error, with the store not opened again.
    private func abandonedOpen(after error: any Error) -> any Error {
        defer { releasePresenceWhenIdle() }
        if lifecycle == .closed { return MemoryStoreError.unavailable(.closed) }
        lifecycle = .notOpened
        return error
    }

    /// Takes the archive's presence lock shared, before the first connection. A recovery in progress
    /// holds it exclusive: the open waits for it as for a busy lock, within one budget, and then
    /// answers `contention`.
    private func takePresence() async throws {
        guard presence == nil else { return }
        let path = url.path
        try await retrying(phase: .open) {
            try stillOpening()
            guard let taken = try SQLiteMemoryPresence.take(.shared, of: url) else {
                throw Busy(failure: SQLiteConnection.Failure(
                    primary : SQLITE_BUSY,
                    extended: SQLITE_BUSY,
                    message : "a recovery of \(path) holds its presence lock"
                ), phase: .open)
            }
            presence = taken
        }
    }

    /// Lets go of the presence lock once nothing of this store holds the archive's files: no
    /// connection of its own or of a copy still in flight, and no open in progress or done.
    private func releasePresenceWhenIdle() {
        guard liveHandles == 0, lifecycle != .open, lifecycle != .opening, opening == nil else { return }
        presence?.release()
        presence = nil
    }

    /// Runs `fault` inside the next migration's transaction, once its texts ran and before the version is
    /// set: an error it throws rolls the migration back. For the package's tests only.
    package func injectMigrationFault(_ fault: (@Sendable () throws -> Void)?) {
        migrationFault = fault
    }

    /// Whether the store holds the archive's presence lock now: for the package's tests.
    package var holdsPresence: Bool { presence?.isHeld == true }

    private func stillOpening() throws {
        guard lifecycle == .opening else { throw MemoryStoreError.unavailable(.closed) }
    }

    /// The store is still open after an `await`; otherwise the answer is why not.
    private func stillOpen() throws {
        switch lifecycle {
        case .open             : return
        case .failed(let fault): throw MemoryStoreError.unavailable(.failed(fault))
        default                : throw MemoryStoreError.unavailable(.closed)
        }
    }

    /// Opens one counted connection with foreign keys on and verified.
    private func acquire(_ path: String, readOnly: Bool = false, mayCreate: Bool = true) throws -> SQLiteConnection {
        let connection = try Self.connect(path, readOnly: readOnly, mayCreate: mayCreate)
        liveHandles += 1
        return connection
    }

    /// Closes one counted connection; a connection already closed is not counted twice.
    private func release(_ connection: SQLiteConnection) {
        guard connection.isOpen else { return }
        connection.close()
        liveHandles -= 1
        releasePresenceWhenIdle()
    }

    /// Lets go of every connection after a transaction that could not be ended: nothing more goes
    /// through a connection the store does not trust. The fault stays as the reason, for every
    /// later call, until `close`.
    private func invalidate(with fault: MemoryStoreFault) {
        guard lifecycle == .open else { return }
        if let writer { release(writer) }
        writer = nil
        lifecycle = .failed(fault)
        readPool.stop(with: .unavailable(.failed(fault)))
        readerShutdown = Task { await closeReaders() }
        releasePresenceWhenIdle()
    }

    /// Opens one connection with foreign keys on and verified. The journal is dealt with apart,
    /// because setting it needs the file to be one this build accepts.
    private static func connect(_ path: String, readOnly: Bool, mayCreate: Bool = true) throws -> SQLiteConnection {
        do {
            let connection = try SQLiteConnection(path: path, readOnly: readOnly, mayCreate: mayCreate)
            try connection.execute("PRAGMA foreign_keys = ON")
            guard try integerPragma(connection, "foreign_keys") == 1 else {
                throw refusal(.open, "foreign_keys could not be enabled")
            }
            return connection
        } catch let failure as SQLiteConnection.Failure {
            throw MemoryStoreError(failure, phase: .open)
        }
    }

    /// Puts the file in WAL and this connection in `synchronous=FULL`, verifying both. WAL is a
    /// property of the file: set once here, found by every later connection. A refused journal
    /// mode is an `open` error with code 0, since the library reports it as a value, not an error.
    private static func setJournal(_ connection: SQLiteConnection, phase: MemoryStoreError.Phase) throws {
        let mode = try connection.query("PRAGMA journal_mode = WAL") { try $0.text(0) ?? "" }.first ?? ""
        guard mode == "wal" else {
            throw refusal(phase, "journal_mode=WAL was not accepted; the file answered '\(mode)'")
        }
        try connection.execute("PRAGMA synchronous = FULL")
        try connection.execute("PRAGMA wal_autocheckpoint = 0")
    }

    /// Confirms the file is in WAL, sets `synchronous=FULL`, and makes the connection read-only.
    private static func verifyJournal(_ connection: SQLiteConnection, phase: MemoryStoreError.Phase) throws {
        do {
            let mode = try textPragma(connection, "journal_mode")
            guard mode == "wal" else {
                throw refusal(phase, "journal_mode is not WAL; the file answered '\(mode)'")
            }
            try connection.execute("PRAGMA synchronous = FULL")
            try connection.execute("PRAGMA query_only = ON")
        } catch {
            throw classified(error, phase: phase)
        }
    }

    /// What an inspection compares a file with: for the current schema and each earlier one this build
    /// migrates from, the tables its text creates, for a refusal that names them, and the exact objects
    /// a file bootstrapped from it holds.
    struct Expected {

        struct Shape {
            let tables : [String]
            let objects: Set<SQLiteMemorySchema.SchemaObject>

            init(ddl: String) throws {
                tables  = SQLiteMemorySchema.tableNames(in: ddl)
                objects = try SQLiteMemorySchema.objects(of: ddl)
            }
        }

        let current : Shape
        let previous: [Int32: Shape]

        var tables : [String] { current.tables }
        var objects: Set<SQLiteMemorySchema.SchemaObject> { current.objects }

        /// The shapes of this build: the current schema and every one it migrates from.
        init() throws {
            current  = try Shape(ddl: try SQLiteMemorySchema.text())
            var previous: [Int32: Shape] = [:]
            for version in SQLiteMemorySchema.migrations.keys {
                previous[version] = try Shape(ddl: try SQLiteMemorySchema.text(of: version))
            }
            self.previous = previous
        }

        /// A shape of the given text alone, with nothing to migrate from: for a test or a tool comparing
        /// a file with one text.
        init(ddl: String) throws {
            current  = try Shape(ddl: ddl)
            previous = [:]
        }
    }

    /// Reads the version and the schema under the write lock and says whether the file is empty, at
    /// the schema this build knows, or at an earlier schema it migrates from, each at exactly its
    /// shape. Every other file is refused, untouched: a future version, a version 0 file with tables of
    /// its own, a file with tables missing, a file whose tables lack a column this build writes, and a
    /// file whose tables, indexes or triggers are not exactly the ones its version's text creates (an
    /// earlier development form with other constraints).
    static func inspect(_ connection: SQLiteConnection, expected: Expected) throws -> Inspection {
        let version  = try integerPragma(connection, "user_version")
        let existing = try connection.query(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { try $0.text(0) ?? "" }
        if version == 0 {
            guard existing.isEmpty else { throw MemoryStoreError.schema(.unknownTables(existing)) }
            return .empty
        }
        // A historical shape is recognized whole, by the digest of its objects, before anything is said about its parts.
        let historical = SQLiteMemorySchema.historicalShapes.filter { Int64($0.version) == version }
        if !historical.isEmpty {
            let found = try SQLiteMemorySchema.objects(in: connection)
            if found != expected.current.objects, let shape = historical.first(where: { $0.digest == SQLiteMemorySchema.digest(of: found) }) {
                return .historical(shape.name)
            }
        }
        let shape: Expected.Shape
        let answer: Inspection
        if version == Int64(SQLiteMemorySchema.version) {
            (shape, answer) = (expected.current, .current)
        } else if let earlier = Int32(exactly: version), let known = expected.previous[earlier] {
            (shape, answer) = (known, .previous(earlier))
        } else if version > Int64(SQLiteMemorySchema.version) {
            throw MemoryStoreError.schema(.future(
                found: Int32(clamping: version),
                supported: SQLiteMemorySchema.version
            ))
        } else {
            // A version this build neither opens nor migrates from: refused as found, like a newer one.
            throw MemoryStoreError.schema(.unsupported(
                found: Int32(clamping: version),
                supported: SQLiteMemorySchema.version
            ))
        }
        let missing = shape.tables.filter { !existing.contains($0) }
        guard missing.isEmpty else { throw MemoryStoreError.schema(.missingTables(missing)) }
        var missingColumns: [String] = []
        for (table, column) in SQLiteMemorySchema.requiredColumns {
            // Table names are this module's own literals; nothing from a caller is spliced in.
            let columns = try connection.query("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" }
            if !columns.contains(column) { missingColumns.append("\(table).\(column)") }
        }
        guard missingColumns.isEmpty else { throw MemoryStoreError.schema(.missingColumns(missingColumns)) }
        let differences = SQLiteMemorySchema.differences(
            found: try SQLiteMemorySchema.objects(in: connection), expected: shape.objects
        )
        guard differences.isEmpty else { throw MemoryStoreError.schema(.differentShape(differences)) }
        return answer
    }

    private static func integerPragma(_ connection: SQLiteConnection, _ name: String) throws -> Int64 {
        // Pragma names are this module's own literals; nothing from a caller is spliced in.
        try connection.query("PRAGMA \(name)") { $0.integer(0) ?? 0 }.first ?? 0
    }

    private static func textPragma(_ connection: SQLiteConnection, _ name: String) throws -> String {
        try connection.query("PRAGMA \(name)") { try $0.text(0) ?? "" }.first ?? ""
    }

    private static func refusal(_ phase: MemoryStoreError.Phase, _ message: String) -> MemoryStoreError {
        .open(MemoryStoreFault(
            code   : MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
            phase  : phase,
            message: message
        ))
    }

    /// The store's error for anything a step threw: a library failure by its code and the phase,
    /// an invalid text by its position, the store's own errors unchanged.
    static func classified(_ error: any Error, phase: MemoryStoreError.Phase) -> any Error {
        switch error {
        case let failure as SQLiteConnection.Failure   : MemoryStoreError(failure, phase: phase)
        case let invalid as SQLiteStatement.InvalidText: MemoryStoreError(invalid)
        default                                        : error
        }
    }

    // MARK: Running a transaction

    private func writerConnection() throws -> SQLiteConnection {
        switch lifecycle {
        case .notOpened, .opening: throw MemoryStoreError.unavailable(.notOpened)
        case .closed: throw MemoryStoreError.unavailable(.closed)
        case .failed(let fault): throw MemoryStoreError.unavailable(.failed(fault))
        case .open: break
        }
        guard let writer, writer.isOpen else { throw MemoryStoreError.unavailable(.closed) }
        return writer
    }

    /// Runs the step until it returns or throws anything but `Busy`. A busy answer pauses outside
    /// the step, within the budget, and runs the whole step again; the step must leave the
    /// connection outside any transaction before it throws `Busy`.
    private func retrying<T>(phase: MemoryStoreError.Phase, _ step: () throws -> T) async throws -> T {
        var cycle = WaitingCycle(configuration)
        defer { waited += cycle.waited }
        while true {
            cycle.attempting()
            if Task.isCancelled { throw MemoryStoreError.cancelled(phase) }
            do {
                return try step()
            } catch let busy as Busy {
                try await pauseBeforeRetry(&cycle, after: busy.failure, at: busy.phase)
            } catch let failure as SQLiteConnection.Failure {
                guard failure.isBusy else { throw MemoryStoreError(failure, phase: phase) }
                try await pauseBeforeRetry(&cycle, after: failure, at: phase)
            }
        }
    }

    /// Begins, runs the body, commits, as one retried step. Any failure ends the transaction; a
    /// busy one is retried with the same body, any other is thrown: classified when it is the
    /// library's, unchanged when it is the body's. The connection is never left inside a
    /// transaction: after a failure the store looks at what the library left, rolls back what is
    /// still open, and reports which it found (`cleanup`); a transaction it cannot end makes the
    /// connection untrusted (`invalidate`). While bootstrapping, the begin and the commit are
    /// reported in the bootstrap phase too, since a file that is not a database shows itself at
    /// the first lock.
    private func transaction<T>(
        on connection: SQLiteConnection,
        begin        : String,
        phase        : MemoryStoreError.Phase,
        didCommit    : ((T) -> Void)? = nil,
        _ body       : () throws -> T
    ) async throws -> T {
        let beginPhase  = phase == .bootstrap ? phase : MemoryStoreError.Phase.begin
        let commitPhase = phase == .bootstrap ? phase : MemoryStoreError.Phase.commit
        return try await retrying(phase: beginPhase) {
            switch lifecycle {
            case .closed: throw MemoryStoreError.unavailable(.closed)
            case .failed(let fault): throw MemoryStoreError.unavailable(.failed(fault))
            default: break
            }
            // A connection let go of while this waited: closed by `close`, or by `invalidate`, whose
            // fault is the answer then, as for every later call.
            guard connection.isOpen else {
                try stillOpen()
                throw MemoryStoreError.unavailable(.closed)
            }
            do {
                try connection.execute(begin)
            } catch let failure as SQLiteConnection.Failure {
                if failure.isBusy { throw Busy(failure: failure, phase: beginPhase) }
                throw MemoryStoreError(failure, phase: beginPhase)
            }
            let value: T
            do {
                value = try body()
            } catch {
                throw ended(after: error, on: connection, phase: phase)
            }
            do {
                try connection.execute("COMMIT")
            } catch let failure as SQLiteConnection.Failure {
                throw ended(after: failure, on: connection, phase: commitPhase)
            }
            didCommit?(value)
            return value
        }
    }

    /// Ends the transaction a failure interrupted and answers what to throw: `Busy` for a busy
    /// lock whose transaction ended cleanly, so the step runs again; the classified failure, with
    /// the cleanup beside it, for the library's other answers; the body's own error unchanged. A
    /// cleanup that failed invalidates the store first, whatever the primary error was.
    private func ended(
        after error  : any Error,
        on connection: SQLiteConnection,
        phase        : MemoryStoreError.Phase
    ) -> any Error {
        let cleanup: MemoryStoreFault.Cleanup
        if let refusal = readPool.takeRefusal() {
            cleanup = Self.cleanupOutcome(
                inTransaction     : connection.isInTransaction,
                rollback          : { refusal },
                stillInTransaction: { connection.isInTransaction }
            )
        } else {
            cleanup = Self.endTransaction(on: connection)
        }
        let clean: Bool
        if case .failed = cleanup { clean = false } else { clean = true }
        switch error {
        case let failure as SQLiteConnection.Failure:
            if failure.isBusy, clean { return Busy(failure: failure, phase: phase) }
            if !clean {
                invalidate(with: MemoryStoreFault(
                    code   : MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended),
                    phase  : phase,
                    message: failure.message,
                    cleanup: cleanup
                ))
            }
            return MemoryStoreError(failure, phase: phase, cleanup: cleanup)
        default:
            if !clean {
                invalidate(with: MemoryStoreFault(
                    code   : MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
                    phase  : phase,
                    message: "the transaction could not be ended after the body's error",
                    cleanup: cleanup
                ))
            }
            return Self.classified(error, phase: phase)
        }
    }

    /// Looks at the connection after a failure inside a transaction and ends what is still open.
    /// The library rolls some failures back on its own and not others, so this never assumes:
    /// it reads `autocommit`, rolls back when needed, and reads it again.
    static func endTransaction(on connection: SQLiteConnection) -> MemoryStoreFault.Cleanup {
        cleanupOutcome(
            inTransaction     : connection.isInTransaction,
            rollback          : {
                do {
                    try connection.execute("ROLLBACK")
                    return nil
                } catch let failure as SQLiteConnection.Failure {
                    return failure
                } catch {
                    return SQLiteConnection.Failure(
                        primary : SQLITE_MISUSE,
                        extended: SQLITE_MISUSE,
                        message : "\(error)"
                    )
                }
            },
            stillInTransaction: { connection.isInTransaction }
        )
    }

    /// The cleanup decision on its own, over what was observed: nothing to do when the library
    /// already rolled back; rolled back when the store's rollback answered OK and the connection
    /// is outside any transaction; failed otherwise, with the rollback's code and message, or
    /// code 0 when the rollback answered OK and the connection stayed inside a transaction.
    static func cleanupOutcome(
        inTransaction     : Bool,
        rollback          : () -> SQLiteConnection.Failure?,
        stillInTransaction: () -> Bool
    ) -> MemoryStoreFault.Cleanup {
        guard inTransaction else { return .alreadyRolledBack }
        if let failure = rollback() {
            return .failed(MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended), failure.message)
        }
        guard !stillInTransaction() else {
            return .failed(
                MemoryStoreFault.Code(primary: SQLITE_OK, extended: SQLITE_OK),
                "the connection stayed inside a transaction after ROLLBACK"
            )
        }
        return .rolledBack
    }

    /// Pauses before the next attempt, or answers `contention` when another pause would overrun
    /// the cycle's budget, or `cancelled` when the caller's task was cancelled during the pause.
    /// The budget bounds the pauses of the cycle, not the wall clock, so a cycle always holds the
    /// first pause when the configuration was accepted. Called only with no transaction open on
    /// the connection; the observer hears of the pause before it starts.
    private func pauseBeforeRetry(
        _ cycle      : inout WaitingCycle,
        after failure: SQLiteConnection.Failure,
        at phase     : MemoryStoreError.Phase
    ) async throws {
        guard let pause = cycle.nextPause else {
            let fault = MemoryStoreFault(
                code   : MemoryStoreFault.Code(primary: failure.primary, extended: failure.extended),
                phase  : phase,
                message: failure.message
            )
            throw MemoryStoreError.contention(fault, attempts: cycle.attempts, waited: cycle.waited)
        }
        waitObserver?(.pausing(phase, attempt: cycle.attempts))
        let now = clock.now
        do {
            try await Task.sleep(for: pause)
        } catch {
            cycle.interrupted(after: clock.now - now)
            throw MemoryStoreError.cancelled(phase)
        }
        cycle.paused(for: clock.now - now)
        busyRetries += 1
    }

    // A rollback that fails leaves the primary failure in place: used only where a transaction is
    // about to be abandoned with its connection, so nothing later depends on the connection's state.
    private static func rollback(_ connection: SQLiteConnection) {
        guard connection.isInTransaction else { return }
        _ = try? connection.execute("ROLLBACK")
    }
}
