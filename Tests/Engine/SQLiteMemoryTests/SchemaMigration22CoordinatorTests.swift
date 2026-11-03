import Foundation
import Synchronization
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 coordinator")
struct SchemaMigration22CoordinatorTests {
    @Test
    func migrationAndRollbackCanRepeatWithoutDiscardingRecords() async throws {
        let (source, _) = try makeSource()
        let original = try Data(contentsOf: source)
        for turn in 1...2 {
            let target = URL(fileURLWithPath: source.path + ".migrating-22-round-\(turn)")
            let copy = source.lastPathComponent + ".schema-19-round-\(turn)"
            _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                keepingSourceAs: copy, availableSpace: { _ in .max }, progress: { _ in })
            try SQLiteMigration22.rollBack(live: source, to: copy, stamp: "round-\(turn)")
            #expect(try Data(contentsOf: source) == original)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        #expect(files.filter { $0.hasPrefix(source.lastPathComponent + ".migration-22.done") }.count == 2)
        #expect(files.filter { $0.hasPrefix(source.lastPathComponent + ".rollback-22.done") }.count == 2)
    }

    @Test
    func episodeStartingDuringBuildPreventsPublication() async throws {
        let (source, target) = try makeSource()
        let before = try Data(contentsOf: source)
        let episodeOpen = Mutex(false)
        await #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) {
            _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                keepingSourceAs: source.lastPathComponent + ".schema-19-late-episode",
                canMigrate: { !episodeOpen.withLock { $0 } }, availableSpace: { _ in .max },
                progress: { update in
                    if update.phase == .swapping { episodeOpen.withLock { $0 = true } }
                })
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: source.path + ".migration-22"))
    }

    @Test
    func episodeStartingAtExchangeRecordPreventsPublication() async throws {
        let (source, target) = try makeSource()
        let before = try Data(contentsOf: source)
        let episodeOpen = Mutex(false)
        await #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) {
            _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                keepingSourceAs: source.lastPathComponent + ".schema-19-before-record",
                canMigrate: { !episodeOpen.withLock { $0 } }, availableSpace: { _ in .max },
                faults: MigrationFaults { boundary in
                    if boundary == .beforeRecord { episodeOpen.withLock { $0 = true } }
                }, progress: { _ in })
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: source.path + ".migration-22"))
    }

    @Test
    func buildVerifiesCountsCoherenceLedgerAndProgressWithoutPublishing() async throws {
        let (source, target) = try makeSource()
        let before = try Data(contentsOf: source)
        let updates = Mutex<[SQLiteMigration22.Progress]>([])
        let report = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
            keepingSourceAs: source.lastPathComponent + ".schema-19-test", availableSpace: { _ in Int64.max },
            at: 42, progress: { update in updates.withLock { $0.append(update) } })
        #expect(report.from == .unified19)
        #expect(report.rowsByTable.count == 121)
        #expect(report.rowsByTable["memory_events"] == 1)
        #expect(report.outcomesRecorded == 0)
        #expect(report.outcomesConverted == 0)
        #expect(report.outcomesConvertedPartially == 1)
        #expect(report.commandStepsConverted == 0 && report.personFactsLeftInSource == 0)
        #expect(try Data(contentsOf: source) == before)
        try SQLiteMigration22.withSource(at: target) { db throws in
            #expect(try SchemaCoherence.check(db).isEmpty)
            #expect(try db.query("SELECT to_version,from_version,migrated_at_ms FROM memory_schema_migrations") {
                [$0.integer(0), $0.integer(1), $0.integer(2)]
            } == [[22,19,42]])
            #expect(try db.query("SELECT copy_name FROM memory_schema_migrations") { try $0.text(0) }
                    == [source.lastPathComponent + ".schema-19-test"])
            #expect(try db.query("SELECT job_kind FROM memory_consolidation_queue") { try $0.text(0) } == ["index_rebuild"])
        }
        let progress = updates.withLock { $0 }
        #expect(progress.first?.phase == .preparing)
        #expect(progress.last?.phase == .recording)
        #expect(progress.last?.rowsDone == progress.last?.rowsTotal)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.rowsDone <= $1.rowsDone })
        #expect(progress.allSatisfy { $0.rowsDone <= $0.rowsTotal })
        #expect(progress.contains { $0.phase == .convertingObservations })
        #expect(progress.contains { $0.phase == .convertingOutcomes })
    }

    @Test
    func migrateKeepsAdmissionThroughClosedFileExchangeAndRollsBackWithLaterWritesKept() async throws {
        let (source, target) = try makeSource()
        let before = try Data(contentsOf: source)
        let copy = source.lastPathComponent + ".schema-19-test"
        _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
            keepingSourceAs: copy, availableSpace: { _ in Int64.max }, progress: { _ in })
        #expect(try Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent(copy)) == before)
        let writer = try SQLiteConnection(path: source.path, mayCreate: false)
        try writer.run("INSERT INTO memory_events(event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status) VALUES ('later','cli','test','diagnostic',1,'not_applicable')")
        writer.close()
        try SQLiteMigration22.rollBack(live: source, to: copy, stamp: "later")
        #expect(try Data(contentsOf: source) == before)
        let retained = URL(fileURLWithPath: source.path + ".schema-22-later")
        try SQLiteMigration22.withSource(at: retained) { db throws in
            #expect(try db.query("SELECT event_uuid FROM memory_events ORDER BY event_id") { try $0.text(0) } == ["call", "later"])
        }
    }

    @Test(arguments: [SQLiteMigration22.Phase.copying, .convertingObservations, .convertingOutcomes, .verifying, .recording])
    func interruptedBuildLeavesSourceIntact(_ phase: SQLiteMigration22.Phase) async throws {
        let (source, target) = try makeSource()
        let before = try Data(contentsOf: source)
        await #expect(throws: Stop.self) {
            _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
                availableSpace: { _ in Int64.max }, faults: MigrationFaults { boundary in
                    if boundary == .phase(phase) { throw Stop() }
                }, progress: { _ in })
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: source.path + ".migration-22"))
    }

    @Test
    func closedEpisodeGateDoesNotStartBuilding() async throws {
        let (source, target) = try makeSource()
        await #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) {
            _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
                canMigrate: { false }, availableSpace: { _ in Int64.max }, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func incoherentSourceIsRefusedWithoutPublishing() async throws {
        let (source, target) = try makeSource(incoherent: true)
        let before = try Data(contentsOf: source)
        do {
            _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
                availableSpace: { _ in Int64.max }, progress: { _ in })
            Issue.record("Incoherent source admitted")
        } catch SQLiteMigration22.Refusal.verificationFailed(let reasons) {
            #expect(reasons.contains("memory_agent_actions_app_from_event_insert"))
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(FileManager.default.fileExists(atPath: target.path + ".refused"))
    }

    @Test(arguments: [false, true])
    func preparingFaultLeavesEveryArchiveFileUntouched(publishing: Bool) async throws {
        let (source, target) = try makeSource(wal: true)
        let family = ["", "-wal", "-shm"].map { URL(fileURLWithPath: source.path + $0) }
        let before = try family.map { try Data(contentsOf: $0) }
        let faults = MigrationFaults { if $0 == .phase(.preparing) { throw Stop() } }
        await #expect(throws: Stop.self) {
            if publishing {
                _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                    keepingSourceAs: source.lastPathComponent + ".schema-19-test",
                    availableSpace: { _ in Int64.max }, faults: faults, progress: { _ in })
            } else {
                _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
                    availableSpace: { _ in Int64.max }, faults: faults, progress: { _ in })
            }
        }
        #expect(try family.map { try Data(contentsOf: $0) } == before)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: source.path + ".migration-22"))
    }

    private struct Stop: Error {}

    func makeSource(incoherent: Bool = false, wal: Bool = false) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("source.sqlite.migrating-22-test")
        let db = try SQLiteConnection(path: source.path)
        defer { db.close() }
        if wal {
            try db.disableAutomaticCloseCheckpoint()
            try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        }
        let objects = try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text())
        for object in objects where object.type == "table" { try db.execute(try #require(object.sql)) }
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.one'),(2,'test.two');
            INSERT INTO memory_events(event_id,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
            VALUES ('call','cli','test','action',1,0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status,result_kind)
            VALUES ('call',\(incoherent ? 2 : 1),'act','completed','acted_noop');
            PRAGMA user_version=19;
            """)
        for object in objects where object.type != "table" { try db.execute(try #require(object.sql)) }
        return (source, target)
    }
}
