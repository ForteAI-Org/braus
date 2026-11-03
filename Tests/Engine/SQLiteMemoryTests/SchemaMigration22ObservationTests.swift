import EngineCore
import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 observations")
struct SchemaMigration22ObservationTests {
    @Test
    func identicalSamplesShareOneSetWithoutLosingObservationRows() throws {
        try fixture { db throws in
            #expect(try SQLiteMigration22Observations.convert(in: db) == 2)
            #expect(try db.query("SELECT count(*) FROM memory_event_observations") { $0.integer(0) } == [6])
            #expect(try db.query("SELECT count(*) FROM memory_element_sets") { $0.integer(0) } == [1])
            #expect(try db.query("SELECT count(*) FROM memory_elements") { $0.integer(0) } == [1])
            #expect(try db.query("SELECT set_id FROM memory_event_observations WHERE observation_kind='capture' ORDER BY observation_id") {
                $0.integer(0)
            } == [1,1])
            let members: [[UInt8]?] = try db.query("SELECT members FROM memory_element_sets") { $0.bytes(0) }
            #expect(members == [[1]])
            let expected = Digest16.of("8:AXButton7:control4:Save5:title0:-:")
            let elementDigests: [[UInt8]?] = try db.query("SELECT digest FROM memory_elements") { $0.bytes(0) }
            #expect(elementDigests == [Array(expected)])
            let setDigest = Digest16.of(expected.map { String(format: "%02x", $0) }.joined())
            let setDigests: [[UInt8]?] = try db.query("SELECT digest FROM memory_element_sets") { $0.bytes(0) }
            #expect(setDigests == [Array(setDigest)])
            #expect(try db.query("SELECT window_subrole FROM memory_event_observations WHERE observation_kind='capture'") {
                try $0.text(0)
            } == ["AXStandardWindow", "AXStandardWindow"])
        }
    }

    @Test
    func digestUsesReconstructedDestinationSkeletonAndKeepsHistoricalTwins() throws {
        try fixture { db throws in
            try db.execute("""
                INSERT INTO brain_scenes(scene_id,scene_uuid,app_id,scene_kind,first_seen_ms,last_seen_ms,observation_count)
                VALUES (1,'scene-1',1,'window',0,0,1),(2,'scene-2',1,'window',0,0,1),(3,'scope',1,'app',0,0,0);
                INSERT INTO brain_scene_elements(scene_element_id,app_id,scene_id,element_key,role,kind,label,label_origin,first_seen_ms,last_seen_ms)
                VALUES (1,1,1,'save','AXButton','control','Save','title',0,0),
                       (2,1,2,'save','AXButton','control','Save','title',0,0);
                """)
            try SQLiteMigration22Observations.convert(in: db)
            let skeleton = SceneSkeleton(surface: .window, rolesByPath: ["": ["AXButton"]],
                                         captionsByPath: ["": [.init(role: "AXButton", label: "Save")]], collections: [])
            let stored: [[UInt8]?] = try db.query("SELECT skeleton_digest FROM brain_scenes WHERE scene_kind='window' ORDER BY scene_id") {
                $0.bytes(0)
            }
            let digest = Array(SkeletonDigest(skeleton).bytes)
            #expect(stored == [digest, digest])
            #expect(try db.query("SELECT set_id FROM brain_scenes ORDER BY scene_id") { $0.integer(0) } == [1,1,nil])
            #expect(try db.query("SELECT count(*) FROM brain_scenes") { $0.integer(0) } == [3])
        }
    }

    @Test
    func nullableFieldsAndExactUTF8DetermineContentIdentity() throws {
        let db = try SQLiteConnection(path: ":memory:")
        defer { db.close() }
        try db.execute(SQLiteMigration22File.text().components(separatedBy: "-- section: indexes")[0])
        try db.execute("BEGIN")
        let a = try SQLiteElementSetRows.element(in: db, fields: [nil,nil,"café",nil,nil,nil])
        let b = try SQLiteElementSetRows.element(in: db, fields: [nil,nil,"cafe\u{301}",nil,nil,nil])
        let c = try SQLiteElementSetRows.element(in: db, fields: ["",nil,"café",nil,nil,nil])
        #expect(a != b && a != c && b != c)
        let first = try SQLiteElementSetRows.set(in: db, members: [b,a,a])
        let second = try SQLiteElementSetRows.set(in: db, members: [a,b])
        let empty = try SQLiteElementSetRows.set(in: db, members: [])
        let single = try SQLiteElementSetRows.set(in: db, members: [a])
        #expect(first == second)
        #expect(empty != single)
    }

    @Test(arguments: [("partial", "window", "incomplete"), ("complete", "unknown", "uncertain_surface")])
    func captureRefusalsUseOnlySavedQuality(status: String, surface: String, expected: String) throws {
        try fixture { db throws in
            try db.run("UPDATE memory_event_observations SET status=?,surface_kind=? WHERE observation_kind='capture'",
                       [.text(status),.text(surface)])
            try SQLiteMigration22Observations.convert(in: db)
            #expect(try db.query("SELECT reject_reason FROM memory_event_observations WHERE observation_kind='capture'") {
                try $0.text(0)
            } == [expected,expected])
        }
    }

    private func fixture(_ body: (SQLiteConnection) throws -> Void) throws {
        let db = try SQLiteConnection(path: ":memory:")
        defer { db.close() }
        try db.execute(SQLiteMigration22File.text().components(separatedBy: "-- section: indexes")[0])
        try db.execute("""
            BEGIN;
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic');
            INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (1,'first','cli','test','observation',0,'complete'),(2,'second','cli','test','observation',0,'complete');
            INSERT INTO memory_event_observations(observation_id,event_id,phase,observation_kind,status,surface_kind)
            VALUES (1,1,'current','capture','complete','window'),(4,2,'current','capture','complete','window');
            INSERT INTO memory_event_observations(observation_id,event_id,phase,observation_kind,status,parent_observation_id,role,element_kind,label,label_origin,container_path)
            VALUES (2,1,'current','element','observed',1,'AXButton','control','Save','title',''),
                   (5,2,'current','element','observed',4,'AXButton','control','Save','title','');
            INSERT INTO memory_event_observations(observation_id,event_id,phase,observation_kind,status,parent_observation_id,field_name,text_value)
            VALUES (3,1,'current','capture_field','observed',1,'window_subrole','AXStandardWindow'),
                   (6,2,'current','capture_field','observed',4,'window_subrole','AXStandardWindow');
            """)
        try body(db)
    }
}
