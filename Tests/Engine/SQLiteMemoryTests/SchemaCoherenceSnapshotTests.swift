import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence snapshot")
struct SchemaCoherenceSnapshotTests {
    @Test
    func emptyExactSchemaPasses() throws {
        let db = try makeDatabase()
        defer { db.close() }
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func scopeAndOwnershipAreCheckedWithoutPhysicalCompositeKeys() throws {
        let db = try makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.one'),(2,'test.two');
            INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
            VALUES (1,'event','cli','test','action',1,0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status) VALUES (1,2,'status','planned');
            INSERT INTO brain_scenes(scene_id,scene_uuid,app_id,scene_kind,first_seen_ms,last_seen_ms,observation_count,skeleton_digest)
            VALUES (1,'scene',1,'app',0,0,0,zeroblob(16));
            INSERT INTO brain_scene_roles(scene_id,role,count_bucket) VALUES (1,'AXButton',1);
            """)
        let failures = try SchemaCoherence.check(db)
        #expect(failures.contains("memory_agent_actions_app_from_event_insert"))
        #expect(failures.contains("brain_scene_roles_not_app_scope_insert"))
        try db.execute("UPDATE memory_agent_actions SET app_id=1; UPDATE brain_scenes SET scene_kind='window'")
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func insertionHistoryIsCheckedAgainstItsPredecessor() throws {
        let db = try makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_tasks(task_id,task_uuid,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
            VALUES (1,'task',1,'cli','test',0,'open',3);
            INSERT INTO memory_task_revisions(task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
            VALUES (1,1,1,0,'opened','Save'),(2,1,3,0,'revised','Save');
            """)
        #expect(try SchemaCoherence.check(db).contains("memory_task_revisions_in_order"))
        try db.execute("UPDATE memory_task_revisions SET revision=2 WHERE task_revision_id=2")
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func typedGestureChildrenAndConcludedCallsKeepTheirEvidence() throws {
        let db = try makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (1,'event','cli','test','action',0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,gesture,effect,recovery,outcome_origin,learnable)
            VALUES (1,'act','completed','sent','confirmed','continue','recorded',1);
            INSERT INTO memory_call_effects(event_id,performed,checked) VALUES (1,'requested',1);
            """)
        #expect(try SchemaCoherence.check(db).isEmpty)
        try db.execute("UPDATE memory_agent_actions SET execution_status='planned'")
        #expect(try SchemaCoherence.check(db).contains("memory_call_effects_concluded_call"))
    }

    func makeDatabase() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute(SQLiteMigration22File.text().components(separatedBy: "-- section: indexes")[0])
        return db
    }
}
