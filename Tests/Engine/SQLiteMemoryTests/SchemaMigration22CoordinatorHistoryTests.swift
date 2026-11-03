import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 coordinator history and WAL")
struct SchemaMigration22CoordinatorHistoryTests {
    @Test(arguments: SQLiteMemorySchema.historicalShapes.map(\.name) + ["version-1"])
    func everyHistoricalShapeBuildsExact22AndRetainsUsedWork(_ name: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Integration/AutomationRuntimeTests/Fixtures")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22HistoricalBuild-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("source.sqlite.migrating-22-test")
        let ddl = name == "version-1" ? try SQLiteMemorySchema.text(of: 1)
            : try String(contentsOf: root.appendingPathComponent("schema-\(name).sql"), encoding: .utf8)
        let version = name == "version-1" ? 1 : Int(try #require(SQLiteMemorySchema.historicalShapes.first { $0.name == name }?.version))
        let writer = try SQLiteConnection(path: source.path)
        try writer.execute(ddl)
        try writer.execute("PRAGMA user_version=\(version); INSERT INTO brain_apps(bundle_id) VALUES ('test.synthetic')")
        writer.close()
        let before = try fileState(source)
        let report = try await SQLiteMigration22.build(from: source, shape: .historical(name), into: target,
            availableSpace: { _ in Int64.max }, progress: { _ in })
        #expect(report.from == .historical(name))
        #expect(report.rowsByTable["brain_apps"] == 1)
        #expect(try fileState(source) == before)
        let used = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".migration-work-22-") && $0.path.hasSuffix(".used") }
        #expect(used.count == 1)
        try SQLiteMigration22.withSource(at: try #require(used.first)) { db throws in
            #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [19])
        }
        try SQLiteMigration22.withSource(at: target) { db throws in
            #expect(try SQLiteMemorySchema.objects(in: db) == SQLiteMemorySchema.objects(of: SQLiteMigration22File.text()))
            #expect(try SchemaCoherence.check(db).isEmpty)
            #expect(try db.query("SELECT from_version FROM memory_schema_migrations WHERE to_version=22") { $0.integer(0) } == [Int64(version)])
        }
    }

    @Test
    func walOnlyCommittedRowsReach22WithoutChangingSourceFamily() async throws {
        let (source, target) = try SchemaMigration22CoordinatorTests().makeSource(wal: true)
        let family = [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-shm")]
        let before = try family.map(fileState)
        #expect(before[1].bytes.count > 0)
        _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
            availableSpace: { _ in Int64.max }, progress: { _ in })
        #expect(try family.map(fileState) == before)
        try SQLiteMigration22.withSource(at: target) { db throws in
            #expect(try db.query("SELECT event_uuid FROM memory_events") { try $0.text(0) } == ["call"])
        }
    }

    @Test(arguments: [MigrationFaults.Boundary.beforeRecord, .afterRecord, .afterRename(.sidecars),
                      .afterRename(.source), .afterRename(.built)])
    func conversionExchangeFaultsKeepTheWholeWalFamily(_ boundary: MigrationFaults.Boundary) async throws {
        let (source, target) = try SchemaMigration22CoordinatorTests().makeSource(wal: true)
        let suffixes = ["", "-wal", "-shm"]
        let before = try suffixes.map { try fileState(URL(fileURLWithPath: source.path + $0)) }
        let copy = source.lastPathComponent + ".schema-19-test"
        await #expect(throws: Stop.self) {
            _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                keepingSourceAs: copy, availableSpace: { _ in Int64.max }, faults: MigrationFaults {
                    if $0 == boundary { throw Stop() }
                }, progress: { _ in })
        }
        if boundary == .beforeRecord {
            #expect(try suffixes.map { try fileState(URL(fileURLWithPath: source.path + $0)) } == before)
            #expect(try SQLiteMigration22.recover(live: source) == .nothingPending)
        } else {
            #expect(try SQLiteMigration22.recover(live: source) == .completed)
            let kept = source.deletingLastPathComponent().appendingPathComponent(copy)
            #expect(try suffixes.map { try fileState(URL(fileURLWithPath: kept.path + $0)) } == before)
            try SQLiteMigration22.withSource(at: source) { db throws in
                #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [22])
                #expect(try db.query("SELECT event_uuid FROM memory_events") { try $0.text(0) } == ["call"])
            }
            #expect(!FileManager.default.fileExists(atPath: source.path + "-wal"))
            #expect(!FileManager.default.fileExists(atPath: source.path + "-shm"))
        }
    }

    @Test
    func frozenProjectionLoadsBeforeItsInsertGuards() async throws {
        let (source, target) = try SchemaMigration22CoordinatorTests().makeSource()
        let writer = try SQLiteConnection(path: source.path, mayCreate: false)
        try writer.execute("""
            INSERT INTO brain_scenes(scene_id,app_id,title_bucket,scene_kind,first_seen_ms,last_seen_ms)
            VALUES ('scene',1,'','window',0,0);
            INSERT INTO brain_anchors(anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
            VALUES ('anchor',1,0,'control','Save',0,0);
            INSERT INTO brain_groups(group_id,app_id,insertion_order,axis,shared_kind,last_seen_ms)
            VALUES ('group',1,0,'horizontal','control',0);
            INSERT INTO brain_group_members(app_id,group_id,anchor_id,position) VALUES (1,'group','anchor',0);
            INSERT INTO brain_transitions(transition_id,app_id,insertion_order,from_scene_id,anchor_id,trigger_kind,
                to_scene_id,effect_kind,status,first_seen_ms,last_seen_ms)
            VALUES ('transition',1,0,'scene','anchor','press','scene','menuOpened','trusted',0,0);
            """)
        writer.close()
        let report = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
            availableSpace: { _ in Int64.max }, progress: { _ in })
        for table in ["brain_anchors", "brain_groups", "brain_group_members", "brain_transitions"] {
            #expect(report.rowsByTable[table] == 1)
        }
        let built = try SQLiteConnection(path: target.path, mayCreate: false)
        defer { built.close() }
        #expect(try built.query("SELECT label FROM brain_anchors") { try $0.text(0) } == ["Save"])
        for (table, key) in [("brain_anchors", "anchor_id"), ("brain_groups", "group_id"), ("brain_transitions", "transition_id")] {
            #expect(throws: (any Error).self) { try built.execute("INSERT INTO \(table)(\(key)) VALUES (999)") }
        }
    }

    private struct Stop: Error {}
    private struct FileState: Equatable {
        let bytes: Data
        let modified: Date
    }

    private func fileState(_ url: URL) throws -> FileState {
        let modified = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        return try FileState(bytes: Data(contentsOf: url), modified: modified)
    }
}
