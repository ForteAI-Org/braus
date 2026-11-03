import Darwin
import Foundation
import Memory

/// SQLiteMigration22File constructs an unpublished archive in three DDL sections.
/// The caller supplies row conversion and its count/coherence verification. Ordinary store openings never use this API.
enum SQLiteMigration22File {
    private struct Injected: Error {
        let underlying: any Error
    }

    /// Creates a private, exclusive destination, installs history guards after rows, and closes a self-contained file.
    /// Verification failures retain the family under `.refused`; injected interruptions leave it for crash recovery.
    static func create(
        at target: URL,
        faults: MigrationFaults = .none,
        populate: (SQLiteConnection) throws -> Void,
        verify: (SQLiteConnection) throws -> Void
    ) throws {
        let refused = URL(fileURLWithPath: target.path + ".refused")
        for base in [target, refused] {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                var info = stat()
                if lstat(base.path + suffix, &info) == 0 {
                    throw SQLiteMigration22.Refusal.nameTaken(base.lastPathComponent + suffix)
                }
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        let descriptor = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw SQLiteMigration22.Refusal.nameTaken(target.lastPathComponent) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let db = try SQLiteConnection(path: target.path, mayCreate: false)
        defer { db.close() }
        func hit(_ phase: SQLiteMigration22.Phase) throws {
            do { try faults.hit(.phase(phase)) }
            catch { throw Injected(underlying: error) }
        }
        do {
            try db.disableAutomaticCloseCheckpoint()
            try db.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=OFF")
            let ddl = try text()
            try db.execute("BEGIN IMMEDIATE")
            try db.execute(section("tables", in: ddl))
            try hit(.copying)
            try populate(db)
            try db.execute(section("indexes", in: ddl))
            try db.execute(section("triggers", in: ddl))
            try hit(.verifying)
            try validate(db, ddl: ddl)
            try verify(db)
            try db.execute("PRAGMA user_version=22; COMMIT")
            guard try db.query("PRAGMA journal_mode", [], { try $0.text(0) }) == ["delete"] else {
                throw SQLiteMigration22.Refusal.verificationFailed(["journal mode is not DELETE"])
            }
            db.close()
            for suffix in ["-wal", "-shm", "-journal"] {
                var info = stat()
                if lstat(target.path + suffix, &info) == 0 {
                    throw SQLiteMigration22.Refusal.verificationFailed(["unexpected sidecar \(suffix)"])
                }
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            try sync(target, full: true)
            try sync(target.deletingLastPathComponent(), full: false)
        } catch let interruption as Injected {
            throw interruption.underlying
        } catch {
            db.close()
            try retain(target, as: refused)
            throw error
        }
    }

    static func text() throws -> String {
        guard let url = Bundle.module.url(forResource: "memory-schema-22", withExtension: "sql") else {
            throw MemoryStoreError.unavailable(.resourceMissing("memory-schema-22.sql"))
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func section(_ name: String, in text: String) throws -> String {
        let matches = text.components(separatedBy: "-- section: ").filter { $0.hasPrefix(name + "\n") }
        guard matches.count == 1, let section = matches.first else {
            throw MemoryStoreError.unavailable(.resourceMissing("schema 22 section \(name)"))
        }
        return String(section.dropFirst(name.count + 1))
    }

    private static func validate(_ db: SQLiteConnection, ddl: String) throws {
        var reasons: [String] = []
        let integrity = try db.query("PRAGMA integrity_check") { try $0.text(0) ?? "NULL" }
        if integrity != ["ok"] { reasons += integrity }
        let references = try db.query("PRAGMA foreign_key_check") { "references of \(try $0.text(0) ?? "unknown")" }
        reasons += Set(references).sorted()
        reasons += try SQLiteMemorySchema.differences(
            found: SQLiteMemorySchema.objects(in: db), expected: SQLiteMemorySchema.objects(of: ddl))
        guard reasons.isEmpty else { throw SQLiteMigration22.Refusal.verificationFailed(reasons) }
    }

    static func retain(_ source: URL, as target: URL) throws {
        for suffix in ["-wal", "-shm", "-journal", ""] {
            var info = stat()
            if lstat(source.path + suffix, &info) != 0 {
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                continue
            }
            guard renamex_np(source.path + suffix, target.path + suffix, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try sync(source.deletingLastPathComponent(), full: false)
        }
    }

    private static func sync(_ url: URL, full: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let status = full ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
