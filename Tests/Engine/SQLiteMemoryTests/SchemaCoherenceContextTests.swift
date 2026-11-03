import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence contextual foreign keys")
struct SchemaCoherenceContextTests {
    @Test
    func simpleSceneForeignKeyStillRequiresItsApplication() throws {
        let db = try SchemaCoherenceSnapshotTests().makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.one'),(2,'test.two');
            INSERT INTO brain_scenes(scene_id,scene_uuid,app_id,scene_kind,first_seen_ms,last_seen_ms,skeleton_digest)
            VALUES (1,'scene',1,'window',0,0,zeroblob(16));
            INSERT INTO brain_scene_elements(scene_element_id,app_id,scene_id,element_key,kind,first_seen_ms,last_seen_ms)
            VALUES (1,2,1,'save','control',0,0);
            """)
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
        #expect(try SchemaCoherence.check(db).contains("context brain_scene_elements.scene_id"))
        try db.execute("UPDATE brain_scene_elements SET app_id=1")
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func newRevisionIdentityMustAgreeWithRetainedTaskAndNumber() throws {
        let db = try SchemaCoherenceSnapshotTests().makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_tasks(task_id,task_uuid,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
            VALUES (1,'task',1,'cli','test',0,'open',1),(2,'other',1,'cli','test',0,'open',1);
            INSERT INTO memory_task_revisions(task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
            VALUES (1,1,1,0,'opened','Save'),(2,2,1,0,'opened','Save');
            INSERT INTO memory_task_constraints(task_id,revision,position,constraint_text,task_revision_id)
            VALUES (1,1,0,'Save',2);
            """)
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
        #expect(try SchemaCoherence.check(db).contains("context memory_task_constraints.task_revision_id"))
        try db.execute("UPDATE memory_task_constraints SET task_revision_id=1")
        #expect(try SchemaCoherence.check(db).isEmpty)
    }
}
