import Darwin
import Foundation

/// SQLiteMigration22Normalization runs the frozen historical chain only on an exclusive working copy.
/// The caller holds admission and the source read transaction throughout this call. Failed work stays unpublished.
enum SQLiteMigration22Normalization {
    /// Borrows schemas 19, 20 and 21 read-only for conversion, retaining successful historical work under `.used`.
    /// The body must not retain either connection. Direct schema 19/20/21 sources never create a working file.
    static func withSource<T>(
        _ source: SQLiteConnection,
        shape: SQLiteMigration22.SourceShape,
        workingAt work: URL,
        faults: MigrationFaults = .none,
        _ body: (SQLiteConnection) throws -> T
    ) throws -> T {
        let historical = try recognizedHistoricalShape(in: source, shape: shape)
        switch shape {
        case .unified19, .command20, .facts21: return try body(source)
        case .historical: break
        }
        let used = URL(fileURLWithPath: work.path + ".used")
        try reserve(work, used: used)
        let copy = try SQLiteConnection(path: work.path, mayCreate: false)
        defer { copy.close() }
        try copy.disableAutomaticCloseCheckpoint()
        let backup = try SQLiteBackup(from: source, to: copy)
        while try backup.step(pages: 256).remaining > 0 { try Task.checkCancellation() }
        try backup.finish()
        // The backup copies WAL mode too. Only the working file is settled before rebuilding its tables.
        try copy.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=OFF")
        try faults.hit(.phase(.normalizing))
        try copy.execute("BEGIN IMMEDIATE")
        let created: [String]
        if let historical {
            created = try SQLiteMemorySchema.rebuild(copy, from: historical)
        } else {
            try copy.execute(SQLiteMemorySchema.migrationText(from: 1))
            created = ["brain_anchor_label_keys"]
        }
        if created.contains("brain_anchor_label_keys") { try SQLiteBrainRows.fillLabelKeys(copy) }
        try copy.run("INSERT INTO memory_recall_work(route_id,reason,enqueued_at_ms) VALUES (NULL,'migration',?)",
                     [.integer(Int64(Date().timeIntervalSince1970 * 1000))])
        try copy.execute("PRAGMA user_version=19")
        let differences = try SQLiteMemorySchema.differences(
            found: SQLiteMemorySchema.objects(in: copy),
            expected: SQLiteMemorySchema.objects(of: SQLiteMemorySchema.historical19Text())
        )
        let integrity = try copy.query("PRAGMA integrity_check") { try $0.text(0) ?? "NULL" }
        let references = try copy.query("PRAGMA foreign_key_check") { "references of \(try $0.text(0) ?? "unknown")" }
        let failures = differences + (integrity == ["ok"] ? [] : integrity) + references
        guard failures.isEmpty else { throw SQLiteMigration22.Refusal.verificationFailed(failures) }
        try copy.execute("COMMIT")
        guard try copy.query("PRAGMA journal_mode", [], { try $0.text(0) }) == ["delete"] else {
            throw SQLiteMigration22.Refusal.verificationFailed(["working journal mode is not DELETE"])
        }
        copy.close()
        let result = try SQLiteMigration22.withSource(at: work, body)
        try synchronize(work, full: true)
        for suffix in ["-wal", "-shm", "-journal", ""] {
            var info = stat()
            if lstat(work.path + suffix, &info) != 0 {
                guard errno == ENOENT else { throw posixError() }
                continue
            }
            guard renamex_np(work.path + suffix, used.path + suffix, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            try synchronize(work.deletingLastPathComponent(), full: false)
        }
        return result
    }

    /// Recognizes the exact source before any unpublished family is renamed or any working file is created.
    static func recognizedHistoricalShape(
        in source: SQLiteConnection,
        shape: SQLiteMigration22.SourceShape
    ) throws -> SQLiteMemorySchema.HistoricalShape? {
        guard source.isInTransaction else { throw SQLiteMigration22.Refusal.sourceNotReadable }
        let objects = try SQLiteMemorySchema.objects(in: source)
        let version = try source.query("PRAGMA user_version") { $0.integer(0) }.first ?? nil
        switch shape {
        case .unified19:
            guard version == 19, objects == (try SQLiteMemorySchema.objects(of: SQLiteMemorySchema.historical19Text())) else {
                throw SQLiteMigration22.Refusal.unknownShape("unified-19")
            }
            return nil
        case .historical(let name):
            if name == "version-1" {
                guard version == 1, objects == (try SQLiteMemorySchema.objects(of: SQLiteMemorySchema.text(of: 1))) else {
                    throw SQLiteMigration22.Refusal.unknownShape(name)
                }
                return nil
            } else {
                guard let known = SQLiteMemorySchema.historicalShapes.first(where: { $0.name == name }),
                      version == Int64(known.version), SQLiteMemorySchema.digest(of: objects) == known.digest else {
                    throw SQLiteMigration22.Refusal.unknownShape(name)
                }
                return known
            }
        case .command20, .facts21:
            let expected: Int64 = shape == .command20 ? 20 : 21
            guard version == expected,
                  SQLiteMemorySchema.digest(of: objects) == SQLiteMigration22SourceSchemas.digest(version: expected) else {
                throw SQLiteMigration22.Refusal.unknownShape(shape == .command20 ? "command-20" : "facts-21")
            }
            return nil
        }
    }

    private static func reserve(_ work: URL, used: URL) throws {
        for base in [work, used] {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try requireAbsent(URL(fileURLWithPath: base.path + suffix))
            }
        }
        let descriptor = open(work.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw SQLiteMigration22.Refusal.nameTaken(work.lastPathComponent) }
            throw posixError()
        }
        guard close(descriptor) == 0 else { throw posixError() }
    }

    private static func requireAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw SQLiteMigration22.Refusal.nameTaken(url.lastPathComponent) }
        guard errno == ENOENT else { throw posixError() }
    }

    private static func synchronize(_ url: URL, full: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard (full ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
