import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 file construction")
struct SchemaMigration22FileTests {
    private struct Interrupted: Error, Equatable {}

    @Test
    func tablesPrecedeRowsAndHistoryGuards() throws {
        let target = try destination()
        try SQLiteMigration22File.create(at: target) { db throws in
            #expect(try count(db, "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") == 163)
            #expect(try count(db, "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'") == 0)
            #expect(try count(db, "SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL") == 0)
            try db.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic')")
            try db.execute("""
                INSERT INTO brain_anchors(anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
                VALUES (1,1,0,'button','Save',0,0)
                """)
        } verify: { db throws in
            #expect(try count(db, "SELECT count(*) FROM brain_apps") == 1)
            #expect(try count(db, "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'") == 330)
        }
        try SQLiteMigration22.withSource(at: target) { db throws in
            #expect(try db.query("PRAGMA journal_mode") { try $0.text(0) } == ["delete"])
            #expect(try count(db, "PRAGMA user_version") == 22)
        }
        let writer = try SQLiteConnection(path: target.path, mayCreate: false)
        defer { writer.close() }
        #expect(throws: (any Error).self) {
            try writer.execute("""
                INSERT INTO brain_anchors(anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
                VALUES (2,1,1,'button','Open',0,0)
                """)
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: target.path + suffix))
        }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
    }

    @Test
    func occupiedNameIsNeverOpenedOrOverwritten() throws {
        let target = try destination()
        let bytes = Data("preserved".utf8)
        try bytes.write(to: target)
        #expect(throws: SQLiteMigration22.Refusal.nameTaken(target.lastPathComponent)) {
            try SQLiteMigration22File.create(at: target) { _ in
                Issue.record("Occupied destination admitted")
            } verify: { _ in }
        }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test
    func foreignKeyFailurePreservesRefusedFile() throws {
        let target = try destination()
        #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["references of brain_app_contexts"])) {
            try SQLiteMigration22File.create(at: target) { db in
                try db.execute("INSERT INTO brain_app_contexts(context_id,app_id) VALUES (1,999)")
            } verify: { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: target.path + ".refused"))
    }

    @Test
    func exactShapeIsCheckedAfterPopulation() throws {
        let target = try destination()
        #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["table extra"])) {
            try SQLiteMigration22File.create(at: target) { db in
                try db.execute("CREATE TABLE extra(value TEXT) STRICT")
            } verify: { _ in }
        }
        #expect(FileManager.default.fileExists(atPath: target.path + ".refused"))
    }

    @Test
    func verificationErrorIsPreserved() throws {
        let target = try destination()
        #expect(throws: Interrupted()) {
            try SQLiteMigration22File.create(at: target) { _ in } verify: { _ in throw Interrupted() }
        }
        #expect(FileManager.default.fileExists(atPath: target.path + ".refused"))
    }

    @Test(arguments: [SQLiteMigration22.Phase.copying, .verifying])
    func crashLeavesAnUnpublishedFile(phase: SQLiteMigration22.Phase) throws {
        let target = try destination()
        #expect(throws: Interrupted()) {
            try SQLiteMigration22File.create(
                at: target,
                faults: MigrationFaults { if $0 == .phase(phase) { throw Interrupted() } }
            ) { _ in } verify: { _ in }
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: target.path + ".refused"))
    }

    private func count(_ db: SQLiteConnection, _ sql: String) throws -> Int64 {
        try #require(db.query(sql) { $0.integer(0) }.first ?? nil)
    }

    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22File-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.appendingPathComponent("memory.sqlite.migrating-22-test")
    }
}
