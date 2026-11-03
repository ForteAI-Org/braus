import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 populated schema 8 recovery")
struct SchemaMigration22AHistoryTests {
    private struct Stop: Error {}

    @Test(arguments: [MigrationFaults.Boundary.phase(.normalizing), .phase(.copying),
                      .phase(.convertingObservations), .phase(.convertingOutcomes), .phase(.verifying),
                      .phase(.recording), .phase(.swapping), .beforeRecord, .afterRecord,
                      .afterRename(.sidecars), .afterRename(.source), .afterRename(.built)])
    func historicalWALSurvivesEveryConversionAndExchangeBoundary(_ boundary: MigrationFaults.Boundary) async throws {
        let (source, target) = try fixture()
        let before = try family(source)
        let copyName = source.lastPathComponent + ".schema-main-8-test"
        await #expect(throws: Stop.self) {
            _ = try await SQLiteMigration22.migrate(
                from: source, shape: .historical("main-8"), into: target, keepingSourceAs: copyName,
                availableSpace: { _ in Int64.max }, faults: MigrationFaults {
                    if $0 == boundary { throw Stop() }
                }, progress: { _ in }
            )
        }
        let recovery = try SQLiteMigration22.recover(live: source)
        if [.afterRecord, .afterRename(.sidecars), .afterRename(.source), .afterRename(.built)].contains(boundary) {
            #expect(recovery == .completed)
            #expect(try family(source.deletingLastPathComponent().appendingPathComponent(copyName)) == before)
            try verifyConverted(source)
        } else {
            #expect(recovery == .nothingPending)
            #expect(try family(source) == before)
        }
    }

    @Test(arguments: 0..<5)
    func recoveryOfConvertedHistoricalWALCanStopAtEveryRename(_ step: Int) async throws {
        let (source, target) = try fixture()
        let before = try family(source)
        let copyName = source.lastPathComponent + ".schema-main-8-test"
        await #expect(throws: Stop.self) {
            _ = try await SQLiteMigration22.migrate(
                from: source, shape: .historical("main-8"), into: target, keepingSourceAs: copyName,
                availableSpace: { _ in Int64.max }, faults: MigrationFaults {
                    if $0 == .afterRecord { throw Stop() }
                }, progress: { _ in }
            )
        }
        #expect(throws: Stop.self) {
            try SQLiteMigration22.recover(live: source, faults: MigrationFaults {
                if $0 == .recovery(step: step) { throw Stop() }
            })
        }
        #expect(try SQLiteMigration22.recover(live: source) == .completed)
        #expect(try family(source.deletingLastPathComponent().appendingPathComponent(copyName)) == before)
        try verifyConverted(source)
        try SQLiteMigration22.rollBack(live: source, to: copyName, stamp: "historical")
        #expect(try family(source) == before)
        try verifyConverted(URL(fileURLWithPath: source.path + ".schema-22-historical"))
    }

    @Test(arguments: 0..<5)
    func damagedConversionRestoresHistoricalWALAfterInterruptedRecovery(_ step: Int) async throws {
        let (source, target) = try fixture()
        let before = try family(source)
        let copyName = source.lastPathComponent + ".schema-main-8-test"
        await #expect(throws: Stop.self) {
            _ = try await SQLiteMigration22.migrate(
                from: source, shape: .historical("main-8"), into: target, keepingSourceAs: copyName,
                availableSpace: { _ in Int64.max }, faults: MigrationFaults {
                    if $0 == .afterRename(.source) { throw Stop() }
                }, progress: { _ in }
            )
        }
        let damaged = Data("damaged synthetic conversion".utf8)
        try damaged.write(to: target)
        #expect(throws: Stop.self) {
            try SQLiteMigration22.recover(live: source, faults: MigrationFaults {
                if $0 == .recovery(step: step) { throw Stop() }
            })
        }
        #expect(try SQLiteMigration22.recover(live: source) == .restoredSource)
        #expect(try family(source) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.path + ".abandoned")) == damaged)
        #expect(try SQLiteMigration22.recover(live: source) == .nothingPending)
    }

    private func verifyConverted(_ url: URL) throws {
        try SQLiteMigration22.withSource(at: url) { db throws in
            #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [22])
            #expect(try SchemaCoherence.check(db).isEmpty)
            #expect(try db.query("SELECT from_version FROM memory_schema_migrations WHERE to_version=22") {
                $0.integer(0)
            } == [8])
            #expect(try db.query("SELECT event_uuid FROM memory_events") { try $0.text(0) } == ["call"])
            #expect(try db.query("SELECT outcome_origin FROM memory_agent_actions") { try $0.text(0) }
                    == ["converted_partial"])
            #expect(try db.query("SELECT count(*) FROM memory_recall_documents") { $0.integer(0) } == [2])
            #expect(try db.query("SELECT count(*) FROM memory_recall_texts") { $0.integer(0) } == [1])
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
        }
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22AHistory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        let target = URL(fileURLWithPath: source.path + ".migrating-22-test")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Integration/AutomationRuntimeTests/Fixtures")
        let db = try SQLiteConnection(path: source.path)
        defer { db.close() }
        try db.disableAutomaticCloseCheckpoint()
        try db.execute(String(contentsOf: root.appendingPathComponent("schema-main-8.sql"), encoding: .utf8))
        try db.execute("PRAGMA user_version=8; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic');
            INSERT INTO memory_events(event_id,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
            VALUES ('call','cli','test','action',1,0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status,result_kind)
            VALUES ('call',1,'act','completed','acted_noop');
            INSERT INTO memory_recall_documents(document_digest,document_format,text,recorded_at_ms)
            VALUES (printf('%064d',1),'recall-document-1','Save',0),(printf('%064d',2),'recall-document-1c','Save',0);
            """)
        return (source, target)
    }

    private struct Member: Equatable {
        let bytes: Data
        let modified: Date
    }

    private func family(_ source: URL) throws -> [Member] {
        try ["", "-wal", "-shm"].map { suffix in
            let url = URL(fileURLWithPath: source.path + suffix)
            return try Member(bytes: Data(contentsOf: url), modified: #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            ))
        }
    }
}
