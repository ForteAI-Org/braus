//
//  SQLiteMemoryInspection.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
import SQLiteAmalgamation

/// SQLiteMemoryInspection says what an archive file is, for a diagnosis, without changing it: whether
/// it is there, its size and its log's, its schema version and what this build's open would make of
/// it, a few row counts when it would open it, and the copies and quarantined files beside it.
///
/// It reads the file as any reader does, with a read-only connection and the library's locks, all in
/// one read transaction, so version, shape and counts describe one committed state even while another
/// process writes. It takes the archive's presence lock shared first (`SQLiteMemoryPresence`): no
/// recovery moves the files while it reads, and while a recovery holds them it reads nothing and says
/// so. It never creates the archive, bootstraps, migrates, recovers or copies; the only file it may
/// make is the archive's empty lock file, the point every opener coordinates on, when the archive
/// was never opened by a build that makes it. The library may update the archive's WAL index
/// (`-shm`), shared memory that every reader updates and that holds no data. It reads nothing about
/// the writes of a running process: those counters live in each process's own memory.
public enum SQLiteMemoryInspection {

    /// Shape is what this build's ordinary open would make of the file as it was read.
    public enum Shape: Sendable, Equatable {
        /// No file at the path.
        case missing
        /// A database with no schema yet: Braus's memory would create its schema in it, and a
        /// reader of an existing archive refuses it.
        case empty
        /// The schema this build opens: its version and exactly its shape.
        case current
        /// Exactly the shape of an earlier schema this build migrates from: Braus's memory migrates it
        /// on its next open, after a verified copy, and a reader refuses it until then.
        case migratable(from: Int32)
        /// A file this build refuses and leaves as it is, and why: a newer version, another shape,
        /// tables of somebody else's.
        case refused(MemorySchemaMismatch)
        /// The file could not be read as a database: the library's reason.
        case unreadable(String)
        /// The file was not read, and why: a recovery holds it, or it cannot be read as it lies.
        case unavailable(String)
        /// A recovery began and did not finish: what its record says. Nothing was read, and the
        /// memory opens nothing until a recovery completes it.
        case interruptedRecovery(String)
    }

    public struct Report: Sendable, Equatable {
        public let path: String
        public let bytes: Int64?
        public let journalBytes: Int64?
        /// The file's `user_version`, when it could be read.
        public let schemaVersion: Int64?
        public let shape: Shape
        /// Row counts, by table, when the shape is current or migratable.
        public let counts: [String: Int]
        /// Copies beside the file, newest first.
        public let backups: [String]
        /// Files a recovery moved aside.
        public let quarantined: [String]
    }

    /// The schema version this build opens.
    public static var supportedVersion: Int32 { SQLiteMemorySchema.version }

    /// The tables whose rows a report counts.
    public static let countedTables = ["memory_events", "memory_agent_actions", "brain_apps", "brain_anchors",
                                       "brain_transitions", "brain_applications"]

    /// How many times a read the library answered busy is tried, and the pause between two tries.
    static let busyAttempts          = 10
    static let busyPauseMicroseconds = UInt32(20_000)

    public static func inspect(_ url: URL) -> Report {
        inspect(url, betweenReads: nil)
    }

    /// The same, with a test's seam, for the package's tests only: `betweenReads` runs inside the read
    /// transaction, once the version was read and before the schema and the counts are.
    package static func inspect(_ url: URL, betweenReads: (() -> Void)?) -> Report {
        let manager = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        func report(_ shape: Shape, version: Int64? = nil, counts: [String: Int] = [:]) -> Report {
            let directory = url.deletingLastPathComponent()
            let siblings  = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted(by: >)
            let name      = url.lastPathComponent
            return Report(path: url.path, bytes: size(url.path), journalBytes: size(url.path + "-wal"),
                          schemaVersion: version, shape: shape, counts: counts,
                          backups: siblings.filter { $0.hasPrefix("\(name).backup-") },
                          quarantined: siblings.filter { $0.hasPrefix("\(name).corrupt-") })
        }
        // A missing archive gets no lock file either: nothing is made beside a file that is not there,
        // unless a recovery's record says one stopped there.
        guard manager.fileExists(atPath: url.path) || SQLiteMemoryRecovery.pending(of: url) != nil else {
            return report(.missing)
        }
        let presence: SQLiteMemoryPresence
        do {
            guard let taken = try SQLiteMemoryPresence.take(.shared, of: url) else {
                return report(.unavailable("a recovery holds the archive; nothing was read"))
            }
            presence = taken
        } catch {
            return report(.unavailable("the archive's presence lock could not be taken: \(error)"))
        }
        defer { presence.release() }
        if let pending = SQLiteMemoryRecovery.pending(of: url) { return report(.interruptedRecovery(pending)) }
        guard manager.fileExists(atPath: url.path) else { return report(.missing) }
        if lacksLogFiles(url) { return report(.unavailable(missingLogFiles)) }
        var attempt = 0
        while true {
            attempt += 1
            switch read(url, betweenReads: betweenReads) {
            case .read(let shape, let version, let counts):
                return report(shape, version: version, counts: counts)
            case .busy where attempt < busyAttempts:
                usleep(busyPauseMicroseconds)
            case .busy:
                return report(.unavailable("the library answered busy \(busyAttempts) times; nothing was read"))
            case .failed(let failure):
                return report(.unreadable("\(failure)"))
            }
        }
    }

    private enum Reading {
        case read(Shape, version: Int64?, counts: [String: Int])
        case busy
        case failed(SQLiteConnection.Failure)
    }

    /// One read of the file in one read transaction: the version, what the store's open would decide
    /// (the same inspection), and the counts when the schema is current or migratable.
    private static func read(_ url: URL, betweenReads: (() -> Void)?) -> Reading {
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
        } catch let failure as SQLiteConnection.Failure {
            return .failed(failure)
        } catch {
            return .read(.unreadable("\(error)"), version: nil, counts: [:])
        }
        defer { connection.close() }
        var version: Int64?
        do {
            let expected = try SQLiteMemoryStore.Expected()
            try connection.execute("BEGIN")
            defer { _ = try? connection.execute("COMMIT") }
            version = try connection.query("PRAGMA user_version") { $0.integer(0) ?? 0 }.first ?? 0
            betweenReads?()
            let inspection = try SQLiteMemoryStore.inspect(connection, expected: expected)
            switch inspection {
            case .empty:
                return .read(.empty, version: version, counts: [:])
            case .current, .previous, .historical:
                var counts: [String: Int] = [:]
                for table in countedTables {
                    // Table names are this module's own literals; nothing from a caller is spliced in.
                    counts[table] = Int(try connection.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0)
                }
                if let earlier = SQLiteMemoryStore.migratedVersion(inspection) {
                    return .read(.migratable(from: earlier), version: version, counts: counts)
                }
                return .read(.current, version: version, counts: counts)
            }
        } catch MemoryStoreError.schema(let mismatch) {
            return .read(.refused(mismatch), version: version, counts: [:])
        } catch let failure as SQLiteConnection.Failure {
            return failure.isBusy ? .busy : .failed(failure)
        } catch {
            return .read(.unreadable("\(error)"), version: version, counts: [:])
        }
    }

    /// TaskReading is what a read of one task by its id found.
    public enum TaskReading: Sendable {
        /// The task and everything the procedures and the Brain hold of it (`ProcedureInspection`).
        case found(ProcedureInspection)
        /// The archive is current and holds no task with that id.
        case notFound
        /// Nothing was read, and why: the archive is missing, not current, held by a recovery or busy.
        case unavailable(String)
    }

    /// Reads one task by its id as `inspect` reads the file: read only, under the shared presence lock,
    /// in one read transaction, and only from an archive of exactly this build's shape. It creates,
    /// migrates and recovers nothing, so an archive of an earlier schema is read by Braus's next open
    /// first.
    public static func task(_ taskID: String, in url: URL) -> TaskReading {
        switch opened(url, { try SQLiteProcedureRows.inspection($0, taskID: taskID) }) {
            case .read(let found?):       return .found(found)
            case .read(nil):              return .notFound
            case .unavailable(let why):   return .unavailable(why)
        }
    }

    /// TaskRow is one task as the listing shows it: who opened it, its status and times, the goal of its
    /// current revision, and how much the procedures and the Recall hold of it, counted.
    public struct TaskRow: Sendable, Equatable {
        public let taskID: String
        public let source: String
        public let streamID: String
        public let status: String
        public let openedAtMS: Int64
        public let closedAtMS: Int64?
        public let currentRevision: Int
        public let goal: String
        public let attempts: Int
        public let versions: Int
        public let proposals: Int
        public let choices: Int
        public let queries: Int
        /// The candidates the task's attempts built, and those no interpretation took: a completed task with one of
        /// these and no version learned nothing (`braus chat --script` reports them).
        public let candidates: Int
        public let uninterpreted: Int
        /// Braus's own verdict on the task's result, from the checks it read (`TaskResultCheck`), guards and `none`
        /// left out: `failed` when one failed, `passed` when one passed and none failed, `unknown` when none could tell,
        /// `none` when the task said it leaves nothing to read, `missing` when it named no result.
        public let result: String
        /// Braus's guards that failed (a file input no check named changed, a file no check named appeared) and that no
        /// check passed on the same path explains: a task that changed its input on purpose and named it later is not
        /// counted. Shown, never part of the result.
        public let guardsFailed: Int

        public init(taskID: String, source: String, streamID: String, status: String, openedAtMS: Int64, closedAtMS: Int64?,
                    currentRevision: Int, goal: String, attempts: Int, versions: Int, proposals: Int, choices: Int, queries: Int,
                    candidates: Int = 0, uninterpreted: Int = 0, result: String = "missing", guardsFailed: Int = 0) {
            self.taskID          = taskID
            self.source          = source
            self.streamID        = streamID
            self.status          = status
            self.openedAtMS      = openedAtMS
            self.closedAtMS      = closedAtMS
            self.currentRevision = currentRevision
            self.goal            = goal
            self.attempts        = attempts
            self.versions        = versions
            self.proposals       = proposals
            self.choices         = choices
            self.queries         = queries
            self.candidates      = candidates
            self.uninterpreted   = uninterpreted
            self.result          = result
            self.guardsFailed    = guardsFailed
        }
    }

    /// TasksReading is what a listing of the tasks found.
    public enum TasksReading: Sendable, Equatable {
        /// The tasks, newest first, at most the limit asked.
        case found([TaskRow])
        /// Nothing was read, and why (as `TaskReading.unavailable`).
        case unavailable(String)
    }

    /// Lists the archive's tasks, newest first, as `task` reads one: read only, from an archive of this
    /// build's shape. `source` keeps the tasks of one producer kind (`app`, `mcp`, `cli`, …); `limit` caps
    /// the rows. The goal printed is the current revision's, as the agent stated it.
    public static func tasks(in url: URL, limit: Int = 20, source: String? = nil) -> TasksReading {
        rows(in: url, filter: "? IS NULL OR t.source = ?",
             [source.map(SQLiteValue.text) ?? .null, source.map(SQLiteValue.text) ?? .null], limit: limit)
    }

    /// The tasks with these ids, newest first, as `tasks(in:)` reads them: what a chat script says of the tasks a
    /// request opened.
    public static func tasks(in url: URL, ids: [String]) -> TasksReading {
        guard !ids.isEmpty else { return .found([]) }
        return rows(in: url, filter: "t.task_id IN (" + ids.map { _ in "?" }.joined(separator: ", ") + ")",
                    ids.map(SQLiteValue.text), limit: ids.count)
    }

    /// The task's result checks, for a subquery over task `t`.
    private static let taskChecks = "FROM memory_task_attempts a JOIN memory_task_events e ON e.task_occurrence_id = "
        + "a.task_occurrence_id JOIN memory_verifications v ON v.event_id = e.event_id WHERE a.task_id = t.task_id "
        + "AND v.scope = 'task'"

    private static func rows(in url: URL, filter: String, _ values: [SQLiteValue], limit: Int) -> TasksReading {
        switch opened(url, { connection in
            try connection.query(
                """
                SELECT t.task_id, t.source, t.source_stream_id, t.status, t.opened_at_ms, t.closed_at_ms, t.current_revision,
                       (SELECT r.goal FROM memory_task_revisions r WHERE r.task_id = t.task_id AND r.revision = t.current_revision),
                       (SELECT count(*) FROM memory_task_attempts a WHERE a.task_id = t.task_id),
                       (SELECT count(*) FROM memory_procedure_versions v JOIN memory_task_attempts a
                           ON a.task_occurrence_id = v.task_occurrence_id WHERE a.task_id = t.task_id),
                       (SELECT count(*) FROM memory_recall_proposals p WHERE p.task_id = t.task_id),
                       (SELECT count(*) FROM memory_recall_choices c JOIN memory_recall_proposals p ON p.proposal_id = c.proposal_id
                           WHERE p.task_id = t.task_id),
                       (SELECT count(*) FROM memory_recall_queries q WHERE q.task_id = t.task_id),
                       (SELECT count(*) FROM memory_procedure_candidates c WHERE c.task_id = t.task_id),
                       (SELECT count(*) FROM memory_procedure_candidates c WHERE c.task_id = t.task_id AND NOT EXISTS
                           (SELECT 1 FROM memory_procedure_interpretations i WHERE i.candidate_id = c.candidate_id)),
                       (SELECT CASE WHEN sum(v.verdict = 'failed') > 0 THEN 'failed' WHEN sum(v.verdict = 'passed') > 0
                           THEN 'passed' ELSE 'unknown' END \(Self.taskChecks) AND v.method NOT IN ('none', 'guard')
                           HAVING count(*) > 0),
                       (SELECT count(*) \(Self.taskChecks) AND v.method = 'none'),
                       (SELECT count(*) \(Self.taskChecks) AND v.method = 'guard' AND v.verdict = 'failed' AND NOT EXISTS (
                           SELECT 1 FROM memory_task_attempts a2 JOIN memory_task_events e2 ON e2.task_occurrence_id =
                           a2.task_occurrence_id JOIN memory_verifications w ON w.event_id = e2.event_id
                           WHERE a2.task_id = t.task_id AND w.scope = 'task' AND w.method NOT IN ('none', 'guard')
                             AND w.verdict = 'passed'
                             AND json_extract(w.expected_text, '$.path') = json_extract(v.expected_text, '$.path')))
                FROM memory_tasks t
                WHERE \(filter)
                ORDER BY t.opened_at_ms DESC, t.task_id
                LIMIT ?
                """,
                values + [.integer(Int64(max(0, limit)))]
            ) { row in
                TaskRow(taskID: try row.text(0) ?? "", source: try row.text(1) ?? "", streamID: try row.text(2) ?? "",
                        status: try row.text(3) ?? "", openedAtMS: row.integer(4) ?? 0, closedAtMS: row.integer(5),
                        currentRevision: Int(row.integer(6) ?? 1), goal: try row.text(7) ?? "", attempts: Int(row.integer(8) ?? 0),
                        versions: Int(row.integer(9) ?? 0), proposals: Int(row.integer(10) ?? 0), choices: Int(row.integer(11) ?? 0),
                        queries: Int(row.integer(12) ?? 0), candidates: Int(row.integer(13) ?? 0),
                        uninterpreted: Int(row.integer(14) ?? 0),
                        result: try row.text(15) ?? ((row.integer(16) ?? 0) > 0 ? "none" : "missing"),
                        guardsFailed: Int(row.integer(17) ?? 0))
            }
        }) {
            case .read(let rows):       return .found(rows)
            case .unavailable(let why): return .unavailable(why)
        }
    }

    /// RecallIndexReport is the Recall's index as a reader finds it: the live generations (ready or
    /// building) with their format, space and revision, the entries of the one that answers and the
    /// vectors it still lacks, and the index work pending. The same facts `braus memory --recall-status`
    /// prints from a running memory, read here without opening one.
    public struct RecallIndexReport: Sendable, Equatable {
        public struct Generation: Sendable, Equatable {
            public let id: Int64
            public let status: String
            public let format: String
            public let spaceID: String?
            public let revision: Int64
            public let isEnumerated: Bool

            public init(id: Int64, status: String, format: String, spaceID: String?, revision: Int64, isEnumerated: Bool) {
                self.id           = id
                self.status       = status
                self.format       = format
                self.spaceID      = spaceID
                self.revision     = revision
                self.isEnumerated = isEnumerated
            }
        }

        public let generations: [Generation]
        public let entries: Int
        public let vectorBacklog: Int
        public let pendingWork: Int

        public init(generations: [Generation], entries: Int, vectorBacklog: Int, pendingWork: Int) {
            self.generations   = generations
            self.entries       = entries
            self.vectorBacklog = vectorBacklog
            self.pendingWork   = pendingWork
        }
    }

    /// RecallIndexReading is what a read of the Recall's index found.
    public enum RecallIndexReading: Sendable, Equatable {
        case found(RecallIndexReport)
        case unavailable(String)
    }

    /// Reads the Recall's index as `task` reads a task: read only, from an archive of this build's shape.
    public static func recallIndex(in url: URL) -> RecallIndexReading {
        switch opened(url, { connection in
            let live = try SQLiteRecallRows.generations(connection, where: "status IN ('ready', 'building')")
            let pending = Int(try connection.query("SELECT count(*) FROM memory_recall_work WHERE done_at_ms IS NULL") {
                $0.integer(0) ?? 0
            }.first ?? 0)
            let answering = live.first { $0.status == .ready } ?? live.first
            let entries = try answering.map { generation in
                Int(try connection.query("SELECT count(*) FROM memory_recall_entries WHERE generation_id = ?",
                                         [.integer(generation.generationID)]) { $0.integer(0) ?? 0 }.first ?? 0)
            } ?? 0
            let backlog = try answering.map { try SQLiteRecallRows.vectorBacklog(connection, $0) } ?? 0
            return RecallIndexReport(
                generations: live.map {
                    RecallIndexReport.Generation(id: $0.generationID, status: $0.status.rawValue, format: $0.format.rawValue,
                                                 spaceID: $0.spaceID, revision: $0.revision, isEnumerated: $0.isEnumerated)
                },
                entries: entries, vectorBacklog: backlog, pendingWork: pending
            )
        }) {
            case .read(let report):     return .found(report)
            case .unavailable(let why): return .unavailable(why)
        }
    }

    /// What one read-only opening of the archive gave: the body's answer, or why nothing was read.
    private enum Opened<T> {
        case read(T)
        case unavailable(String)
    }

    /// Opens the archive as `inspect` reads it, for one body: read only, under the shared presence lock, in
    /// one read transaction, only from an archive of exactly this build's shape, with the library's busy
    /// answers retried. It creates, migrates and recovers nothing.
    private static func opened<T>(_ url: URL, _ body: (SQLiteConnection) throws -> T) -> Opened<T> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return .unavailable("no archive at \(url.path)") }
        let presence: SQLiteMemoryPresence
        do {
            guard let taken = try SQLiteMemoryPresence.take(.shared, of: url) else {
                return .unavailable("a recovery holds the archive; nothing was read")
            }
            presence = taken
        } catch {
            return .unavailable("the archive's presence lock could not be taken: \(error)")
        }
        defer { presence.release() }
        if let pending = SQLiteMemoryRecovery.pending(of: url) { return .unavailable(pending) }
        if lacksLogFiles(url) { return .unavailable(missingLogFiles) }
        for attempt in 1...busyAttempts {
            do {
                let connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
                defer { connection.close() }
                let expected = try SQLiteMemoryStore.Expected()
                try connection.execute("BEGIN")
                defer { _ = try? connection.execute("COMMIT") }
                guard case .current = try SQLiteMemoryStore.inspect(connection, expected: expected) else {
                    return .unavailable("the archive is not of schema \(supportedVersion); `braus memory --status` says what it is")
                }
                return .read(try body(connection))
            } catch let failure as SQLiteConnection.Failure where failure.isBusy && attempt < busyAttempts {
                usleep(busyPauseMicroseconds)
            } catch MemoryStoreError.schema(let mismatch) {
                return .unavailable("this build refuses the archive: \(mismatch)")
            } catch {
                return .unavailable("\(error)")
            }
        }
        return .unavailable("the library answered busy \(busyAttempts) times; nothing was read")
    }

    /// Why a WAL archive without its log files is not read.
    private static let missingLogFiles = "a WAL archive whose log files are not beside it: a reader cannot make "
        + "them without changing the directory; open it with Braus, or inspect it with its -wal and -shm"

    /// Whether the file is a WAL archive without its `-wal` or its `-shm`. A read-only connection of stock
    /// SQLite makes them when the directory is writable, where Apple's refuses, so the diagnosis looks
    /// before it opens. Every connection of this module keeps them after its close (`SQLiteConnection`),
    /// so a closed archive has them; one another tool closed last, or a person moved, may not.
    private static func lacksLogFiles(_ url: URL) -> Bool {
        let manager = FileManager.default
        return isWriteAheadLogged(url)
            && !(manager.fileExists(atPath: url.path + "-wal") && manager.fileExists(atPath: url.path + "-shm"))
    }

    /// Whether the file's header says it is in WAL mode: read and write versions 2, bytes 18 and 19.
    private static func isWriteAheadLogged(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2 && header[19] == 2
    }
}
