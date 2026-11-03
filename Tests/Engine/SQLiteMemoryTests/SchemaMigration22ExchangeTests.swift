import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 durable exchange")
struct SchemaMigration22ExchangeTests {
    private struct Interrupted: Error {}

    private struct Fixture {
        let live: URL
        let built: URL
        let copyName: String
        let original: Data
        let converted: Data
        var directory: URL { live.deletingLastPathComponent() }
        var copy: URL { directory.appendingPathComponent(copyName) }
    }

    private func fixture(wal: Bool = false) throws -> Fixture {
        let live = try temporaryDatabase("exchange")
        let built = URL(fileURLWithPath: live.path + ".migrating-22-test")
        let old = try SQLiteConnection(path: live.path)
        try old.disableAutomaticCloseCheckpoint()
        try old.execute(schema("brain-living-memory-schema"))
        try old.execute("PRAGMA user_version=19")
        if wal { try old.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0") }
        try old.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.source')")
        old.close()
        let fresh = try SQLiteConnection(path: built.path)
        try fresh.execute(schema("memory-schema-22"))
        try fresh.execute(
            "PRAGMA user_version=22; INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.converted')"
        )
        fresh.close()
        return Fixture(
            live: live,
            built: built,
            copyName: live.lastPathComponent + ".schema-19-test",
            original: try Data(contentsOf: live),
            converted: try Data(contentsOf: built)
        )
    }

    private func pending(_ fixture: Fixture) -> Bool { SQLiteMemoryRecovery.pending(of: fixture.live) != nil }

    private func faults(at boundary: MigrationFaults.Boundary) -> MigrationFaults {
        MigrationFaults { if $0 == boundary { throw Interrupted() } }
    }

    private static let boundaries: [MigrationFaults.Boundary] = [
        .beforeRecord, .afterRecord, .afterRename(.sidecars), .afterRename(.source), .afterRename(.built),
    ]

    @Test
    func pendingExchangeNeverEntersCorruptionRecovery() throws {
        let fixture = try fixture(wal: true)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(live: fixture.live, built: fixture.built,
                keepingSourceAs: fixture.copyName, faults: faults(at: .afterRecord))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let before = try files.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) }
        do {
            _ = try SQLiteMemoryRecovery.recover(fixture.live, copies: {
                Issue.record("A pending exchange must not inspect corruption backups")
                return []
            }, stamp: "pending-exchange")
            Issue.record("A pending exchange must remain a distinct refusal")
        } catch MemoryStoreError.unavailable(.interruptedRecovery) {
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == files)
        #expect(try files.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) } == before)
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .completed)
    }

    @Test
    func escapedAdmissionCannotBypassThePresenceLock() throws {
        let fixture = try fixture()
        let admission = try SQLiteMigration22.withReservation(
            from: fixture.live, shape: .unified19, canMigrate: { true }, availableSpace: { _ in .max }
        ) { $0 }
        #expect(throws: SQLiteMigration22.Refusal.sourceInUse) {
            try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName,
                                       admission: admission)
        }
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(try Data(contentsOf: fixture.built) == fixture.converted)
    }

    @Test(arguments: boundaries)
    func crashAtEveryExchangeBoundary(_ boundary: MigrationFaults.Boundary) async throws {
        let fixture = try fixture(wal: true)
        let wal = try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-wal"))
        let shm = try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-shm"))
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: faults(at: boundary)
            )
        }
        if boundary == .beforeRecord {
            #expect(!pending(fixture))
            #expect(try Data(contentsOf: fixture.live) == fixture.original)
            #expect(try Data(contentsOf: fixture.built) == fixture.converted)
            return
        }
        #expect(pending(fixture))
        let store = SQLiteMemoryStore(url: fixture.live, migrationPolicy: .never)
        #expect(
            await storeError { try await store.open() }.map {
                if case .unavailable(.interruptedRecovery) = $0 { return true }
                return false
            } == true
        )
        await store.close()
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .completed)
        #expect(!pending(fixture))
        #expect(try Data(contentsOf: fixture.live) == fixture.converted)
        #expect(try Data(contentsOf: fixture.copy) == fixture.original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.copy.path + "-wal")) == wal)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.copy.path + "-shm")) == shm)
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path + "-shm"))
        #expect(FileManager.default.fileExists(atPath: fixture.live.path + ".migration-22.done"))
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .nothingPending)
    }

    @Test(arguments: 0..<5)
    func recoveryCanItselfBeInterrupted(_ step: Int) throws {
        let fixture = try fixture(wal: true)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: faults(at: .afterRecord)
            )
        }
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.recover(live: fixture.live, faults: faults(at: .recovery(step: step)))
        }
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .completed)
        #expect(try Data(contentsOf: fixture.live) == fixture.converted)
        #expect(try Data(contentsOf: fixture.copy) == fixture.original)
    }

    @Test(arguments: [.afterRecord, .afterRename(.sidecars), .afterRename(.source)] as [MigrationFaults.Boundary])
    func damagedBuiltRestoresOriginal(_ boundary: MigrationFaults.Boundary) throws {
        let fixture = try fixture(wal: true)
        let wal = try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-wal"))
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: faults(at: boundary)
            )
        }
        let damaged = Data("damaged built, kept".utf8)
        try damaged.write(to: fixture.built)
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .restoredSource)
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-wal")) == wal)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.built.path + ".abandoned")) == damaged)
    }

    @Test
    func rollBackKeepsBothIncludingNewWrites() throws {
        let fixture = try fixture(wal: true)
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        let db = try SQLiteConnection(path: fixture.live.path)
        try db.disableAutomaticCloseCheckpoint()
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try db.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES (2,'test.new-write')")
        db.close()
        let newWAL = try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-wal"))
        try SQLiteMigration22.rollBack(live: fixture.live, to: fixture.copyName, stamp: "test")
        let kept22 = URL(fileURLWithPath: fixture.live.path + ".schema-22-test")
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept22.path + "-wal")) == newWAL)
        try SQLiteMigration22.withSource(at: kept22) { db throws in
            #expect(
                try db.query("SELECT bundle_id FROM brain_apps ORDER BY app_id") { try $0.text(0) }
                    == ["test.converted", "test.new-write"]
            )
        }
        try SQLiteMigration22.withSource(at: fixture.live) { db throws in
            #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [19])
            #expect(try db.query("PRAGMA integrity_check") { try $0.text(0) } == ["ok"])
            #expect(
                try SQLiteMemorySchema.objects(in: db)
                    == SQLiteMemorySchema.objects(of: schema("brain-living-memory-schema"))
            )
            #expect(try db.query("SELECT bundle_id FROM brain_apps") { try $0.text(0) } == ["test.source"])
        }
    }

    @Test(arguments: boundaries)
    func rollBackRecoversAtEveryBoundary(_ boundary: MigrationFaults.Boundary) throws {
        let fixture = try fixture(wal: true)
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.rollBack(
                live: fixture.live,
                to: fixture.copyName,
                stamp: "test",
                faults: faults(at: boundary)
            )
        }
        if boundary == .beforeRecord {
            #expect(try Data(contentsOf: fixture.live) == fixture.converted)
        } else {
            #expect(pending(fixture))
            #expect(try SQLiteMigration22.recover(live: fixture.live) == .completed)
            #expect(try Data(contentsOf: fixture.live) == fixture.original)
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + ".schema-22-test")) == fixture.converted
            )
        }
    }

    @Test
    func nameCollisionsAndOccupiedSourceMoveNothing() throws {
        let fixture = try fixture()
        let collision = Data("keep this".utf8)
        try collision.write(to: fixture.copy)
        #expect(throws: SQLiteMigration22.Refusal.nameTaken(fixture.copy.path)) {
            try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        }
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(try Data(contentsOf: fixture.copy) == collision)
        #expect(try Data(contentsOf: fixture.built) == fixture.converted)
        #expect(!pending(fixture))
        let held = try #require(try SQLiteMemoryPresence.take(.shared, of: fixture.live))
        defer { held.release() }
        #expect(throws: SQLiteMigration22.Refusal.sourceInUse) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName + "-free"
            )
        }
    }

    @Test
    func rollbackNameTakenChangesNothing() throws {
        let fixture = try fixture()
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        let kept22 = URL(fileURLWithPath: fixture.live.path + ".schema-22-test")
        try Data("occupied".utf8).write(to: kept22)
        let before = try inventory(fixture.directory)
        #expect(throws: SQLiteMigration22.Refusal.nameTaken(kept22.path)) {
            try SQLiteMigration22.rollBack(live: fixture.live, to: fixture.copyName, stamp: "test")
        }
        #expect(try inventory(fixture.directory) == before)
    }

    @Test
    func lateSidecarRefusesAndRecoveryRestoresSource() throws {
        let fixture = try fixture()
        #expect(throws: (any Error).self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: MigrationFaults { boundary in
                    if boundary == .afterRename(.source) {
                        try Data("late WAL".utf8).write(to: URL(fileURLWithPath: fixture.live.path + "-wal"))
                    }
                }
            )
        }
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: fixture.live.path + "-wal.abandoned")) == Data("late WAL".utf8)
        )
        #expect(try Data(contentsOf: fixture.built) == fixture.converted)
    }

    @Test
    func builtMustBeExactSelfContained22() throws {
        let fixture = try fixture()
        let db = try SQLiteConnection(path: fixture.built.path)
        try db.execute("CREATE TABLE foreign_object(value TEXT)")
        db.close()
        #expect(throws: (any Error).self) {
            try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        }
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(!pending(fixture))
    }

    @Test
    func sidecarsMoveBeforeSource() throws {
        let fixture = try fixture(wal: true)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: MigrationFaults { boundary in
                    if boundary == .afterRename(.sidecars) {
                        #expect(FileManager.default.fileExists(atPath: fixture.live.path))
                        #expect(!FileManager.default.fileExists(atPath: fixture.copy.path))
                        #expect(FileManager.default.fileExists(atPath: fixture.copy.path + "-wal"))
                        #expect(!FileManager.default.fileExists(atPath: fixture.live.path + "-wal"))
                        throw Interrupted()
                    }
                }
            )
        }
    }

    @Test
    func rollbackRejectsUnknownCopy() throws {
        let fixture = try fixture()
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        let foreign = URL(fileURLWithPath: fixture.live.path + ".schema-1-unrecognized")
        let db = try SQLiteConnection(path: foreign.path)
        try db.execute("CREATE TABLE unrelated(value TEXT); PRAGMA user_version=1")
        db.close()
        let before = try inventory(fixture.directory)
        #expect(throws: (any Error).self) {
            try SQLiteMigration22.rollBack(live: fixture.live, to: foreign.lastPathComponent, stamp: "test")
        }
        #expect(try inventory(fixture.directory) == before)
    }

    @Test(arguments: 0..<5)
    func sourceRestorationCanItselfBeInterrupted(_ step: Int) throws {
        let fixture = try fixture(wal: true)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: faults(at: .afterRename(.source))
            )
        }
        let damaged = Data("damaged incoming".utf8)
        try damaged.write(to: fixture.built)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.recover(live: fixture.live, faults: faults(at: .recovery(step: step)))
        }
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .restoredSource)
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.built.path + ".abandoned")) == damaged)
    }

    @Test(arguments: 0..<7)
    func rollbackRecoveryCanItselfBeInterrupted(_ step: Int) throws {
        let fixture = try fixture(wal: true)
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        let db = try SQLiteConnection(path: fixture.live.path)
        try db.disableAutomaticCloseCheckpoint()
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try db.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES (2,'test.new-write')")
        db.close()
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.rollBack(
                live: fixture.live,
                to: fixture.copyName,
                stamp: "test",
                faults: faults(at: .afterRecord)
            )
        }
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.recover(live: fixture.live, faults: faults(at: .recovery(step: step)))
        }
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .completed)
        #expect(try Data(contentsOf: fixture.live) == fixture.original)
        let kept = URL(fileURLWithPath: fixture.live.path + ".schema-22-test")
        try SQLiteMigration22.withSource(at: kept) { db throws in
            #expect(try db.query("SELECT count(*) FROM brain_apps") { $0.integer(0) } == [2])
        }
    }

    @Test
    func nothingDeletedAndPrivateFiles() throws {
        let fixture = try fixture(wal: true)
        let before = try inventory(fixture.directory)
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        let after = try inventory(fixture.directory)
        for bytes in Set(before.values) {
            #expect(after.values.filter { $0 == bytes }.count >= before.values.filter { $0 == bytes }.count)
        }
        for path in [fixture.live.path, fixture.live.path + ".migration-22.done"] {
            let mode = try #require(
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            )
            #expect(mode.intValue & 0o777 == 0o600)
        }
    }

    @Test
    func malformedRecordPreservesEverything() throws {
        let fixture = try fixture()
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.swap(
                live: fixture.live,
                built: fixture.built,
                keepingSourceAs: fixture.copyName,
                faults: faults(at: .afterRecord)
            )
        }
        try Data("invalid record".utf8).write(to: URL(fileURLWithPath: fixture.live.path + ".migration-22"))
        let before = try inventory(fixture.directory)
        #expect(pending(fixture))
        #expect(throws: (any Error).self) { try SQLiteMigration22.recover(live: fixture.live) }
        #expect(try inventory(fixture.directory) == before)
    }

    @Test(arguments: [false, true])
    func abandonedIncomingRemainsOneRetirableFamily(published: Bool) throws {
        let fixture = try fixture(wal: true)
        try SQLiteMigration22.swap(live: fixture.live, built: fixture.built, keepingSourceAs: fixture.copyName)
        #expect(throws: Interrupted.self) {
            try SQLiteMigration22.rollBack(
                live: fixture.live,
                to: fixture.copyName,
                stamp: "test",
                faults: faults(at: published ? .afterRename(.built) : .afterRecord)
            )
        }
        try Data("damaged incoming".utf8).write(to: published ? fixture.live : fixture.copy)
        #expect(try SQLiteMigration22.recover(live: fixture.live) == .restoredSource)
        #expect(try Data(contentsOf: fixture.live) == fixture.converted)
        let abandoned = URL(fileURLWithPath: fixture.copy.path + ".abandoned")
        #expect(FileManager.default.fileExists(atPath: abandoned.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: abandoned.path + "-shm"))
        let report = try SQLiteArchiveRetirement.retire(
            abandoned,
            into: fixture.directory.appendingPathComponent(".retired")
        )
        #expect(report.state == .retired)
        #expect(report.memberCount == 3)
    }

    private func schema(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Engine/SQLiteMemory/Resources/\(name).sql"),
            encoding: .utf8
        )
    }

    private func inventory(_ directory: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try Dictionary(
            uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }
        )
    }
}
