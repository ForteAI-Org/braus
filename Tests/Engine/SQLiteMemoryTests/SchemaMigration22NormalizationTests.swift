import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 historical normalization")
struct SchemaMigration22NormalizationTests {
    private struct Interrupted: Error, Equatable {}

    @Test(arguments: SQLiteMemorySchema.historicalShapes.map(\.name) + ["version-1"])
    func everyHistoricalShapeUsesAWorkingCopy(name: String) throws {
        let (source, work) = try archive(name)
        let original = try Data(contentsOf: source)
        let modified = try modificationDate(source)
        try SQLiteMigration22.withSource(at: source) { old throws in
            let tables = try old.query("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'") {
                try #require(try $0.text(0))
            }
            let counts = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try count(old, $0)) })
            try SQLiteMigration22Normalization.withSource(old, shape: .historical(name), workingAt: work) { normalized throws in
                #expect(normalized.path.contains("mode=ro"))
                #expect(normalized.isInTransaction)
                #expect(try normalized.query("PRAGMA user_version") { $0.integer(0) } == [19])
                #expect(try SQLiteMemorySchema.objects(in: normalized) == SQLiteMemorySchema.objects(of: SQLiteMemorySchema.historical19Text()))
                #expect(try normalized.query("SELECT bundle_id FROM brain_apps") { try $0.text(0) } == ["test.synthetic"])
                for (table, expected) in counts where table != "memory_recall_work" {
                    #expect(try count(normalized, table) == expected, "Rows of \(table) survive normalization")
                }
                #expect(throws: (any Error).self) { try normalized.execute("INSERT INTO brain_apps(bundle_id) VALUES ('refused')") }
                #expect(try Data(contentsOf: source) == original)
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try modificationDate(source) == modified)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        let used = URL(fileURLWithPath: work.path + ".used")
        #expect(FileManager.default.fileExists(atPath: used.path))
        let mode = try #require(FileManager.default.attributesOfItem(atPath: used.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: work.path + suffix))
            #expect(!FileManager.default.fileExists(atPath: used.path + suffix))
        }
    }

    @Test
    func unpinnedSourceIsRefused() throws {
        let (source, work) = try archive("main-1")
        let db = try SQLiteConnection(path: source.path, readOnly: true)
        defer { db.close() }
        #expect(throws: SQLiteMigration22.Refusal.sourceNotReadable) {
            try SQLiteMigration22Normalization.withSource(db, shape: .historical("main-1"), workingAt: work) { _ in
                Issue.record("Unpinned source admitted")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test
    func unified19DoesNotCreateAWorkingCopy() throws {
        let (source, work) = try archive("unified-19")
        try SQLiteMigration22.withSource(at: source) { old throws in
            try SQLiteMigration22Normalization.withSource(old, shape: .unified19, workingAt: work) { normalized in
                #expect(normalized === old)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: work.path + ".used"))
        #expect(SQLiteMemorySchema.historical19Version == 19)
        #expect(try SQLiteMemorySchema.text(of: 19) == SQLiteMemorySchema.historical19Text())
    }

    @Test
    func wrongDigestRefusesBeforeCreatingWork() throws {
        let (source, work) = try archive("main-1")
        let writer = try SQLiteConnection(path: source.path, mayCreate: false)
        try writer.execute("CREATE TABLE extra(value TEXT) STRICT")
        writer.close()
        let original = try Data(contentsOf: source)
        #expect(throws: SQLiteMigration22.Refusal.unknownShape("main-1")) {
            try SQLiteMigration22.withSource(at: source) { old in
                try SQLiteMigration22Normalization.withSource(old, shape: .historical("main-1"), workingAt: work) { _ in
                    Issue.record("Modified historical shape admitted")
                }
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test(arguments: ["", ".used", "-wal", ".used-shm"])
    func takenWorkingFamilyIsPreserved(suffix: String) throws {
        let (source, work) = try archive("main-1")
        let occupied = URL(fileURLWithPath: work.path + suffix)
        let bytes = Data("preserved".utf8)
        try bytes.write(to: occupied)
        #expect(throws: SQLiteMigration22.Refusal.nameTaken(occupied.lastPathComponent)) {
            try SQLiteMigration22.withSource(at: source) { old in
                try SQLiteMigration22Normalization.withSource(old, shape: .historical("main-1"), workingAt: work) { _ in
                    Issue.record("Occupied work family admitted")
                }
            }
        }
        #expect(try Data(contentsOf: occupied) == bytes)
    }

    @Test
    func interruptionKeepsSourceAndUnpublishedWork() throws {
        let (source, work) = try archive("main-1")
        let original = try Data(contentsOf: source)
        #expect(throws: Interrupted()) {
            try SQLiteMigration22.withSource(at: source) { old in
                try SQLiteMigration22Normalization.withSource(
                    old,
                    shape: .historical("main-1"),
                    workingAt: work,
                    faults: MigrationFaults { if $0 == .phase(.normalizing) { throw Interrupted() } }
                ) { _ in Issue.record("Interrupted work read") }
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: work.path + ".used"))
    }

    @Test
    func historicalWALIsCopiedWithoutSourceWrites() throws {
        let (source, work) = try archive("main-1")
        let writer = try SQLiteConnection(path: source.path, mayCreate: false)
        try writer.disableAutomaticCloseCheckpoint()
        try writer.execute("PRAGMA journal_mode=WAL; INSERT INTO brain_apps(bundle_id) VALUES ('test.in-wal')")
        writer.close()
        let family = ["", "-wal", "-shm"].map { URL(fileURLWithPath: source.path + $0) }
        let bytes = try family.map { try Data(contentsOf: $0) }
        let dates = try family.map(modificationDate)
        #expect(bytes[1].count > 0)
        try SQLiteMigration22.withSource(at: source) { old throws in
            try SQLiteMigration22Normalization.withSource(old, shape: .historical("main-1"), workingAt: work) { normalized throws in
                #expect(try normalized.query("SELECT bundle_id FROM brain_apps ORDER BY app_id") { try $0.text(0) }
                        == ["test.synthetic", "test.in-wal"])
            }
        }
        #expect(try family.map { try Data(contentsOf: $0) } == bytes)
        #expect(try family.map(modificationDate) == dates)
        let used = URL(fileURLWithPath: work.path + ".used")
        try SQLiteMigration22.withSource(at: used) { retained throws in
            #expect(try retained.query("SELECT count(*) FROM brain_apps") { $0.integer(0) } == [2])
        }
        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: work.path + suffix))
        }
    }

    @Test
    func consumerErrorKeepsWorkForRecovery() throws {
        let (source, work) = try archive("main-1")
        #expect(throws: Interrupted()) {
            try SQLiteMigration22.withSource(at: source) { old in
                try SQLiteMigration22Normalization.withSource(old, shape: .historical("main-1"), workingAt: work) { _ in
                    throw Interrupted()
                }
            }
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: work.path))
        #expect(!FileManager.default.fileExists(atPath: work.path + ".used"))
    }

    private func count(_ db: SQLiteConnection, _ table: String) throws -> Int64 {
        try #require(db.query("SELECT count(*) FROM \(table)") { $0.integer(0) }.first ?? nil)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func archive(_ name: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Normalization-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("memory.sqlite")
        let work = directory.appendingPathComponent("memory.sqlite.migration-work-22-test")
        let ddl: String
        let version: Int32
        if name == "unified-19" {
            ddl = try SQLiteMemorySchema.historical19Text()
            version = 19
        } else if name == "version-1" {
            ddl = try SQLiteMemorySchema.text(of: 1)
            version = 1
        } else {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Integration/AutomationRuntimeTests/Fixtures")
            ddl = try String(contentsOf: root.appendingPathComponent("schema-\(name).sql"), encoding: .utf8)
            version = try #require(SQLiteMemorySchema.historicalShapes.first { $0.name == name }?.version)
        }
        let db = try SQLiteConnection(path: source.path)
        defer { db.close() }
        try db.execute(ddl)
        try db.execute("PRAGMA user_version=\(version); INSERT INTO brain_apps(bundle_id) VALUES ('test.synthetic')")
        return (source, work)
    }
}
