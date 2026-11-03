import Foundation
import Memory
import Testing
@testable import SQLiteMemory

struct RowCheckFactsTests {
    @Test func reopenedFactsRespectTheExpectationIntervalAndItem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("es8-\(UUID().uuidString).sqlite")
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record(error) }
        }
        do {
            let db = try SQLiteConnection(path: url.path)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try db.execute(String(contentsOf: root.appendingPathComponent(
                "Sources/Engine/SQLiteMemory/Resources/memory-schema-22.sql"), encoding: .utf8))
            try db.execute("""
                INSERT INTO memory_tasks (task_id,task_uuid,contract_version,source,source_stream_id,
                    opened_at_ms,status,current_revision) VALUES (1,'task',1,'app','test',0,'open',1);
                INSERT INTO memory_task_revisions (task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
                    VALUES (1,1,1,0,'opened','Save');
                INSERT INTO memory_todo_revisions (todo_revision_id,task_id,revision,task_revision_id,reason_kind,recorded_at_ms)
                    VALUES (1,1,1,1,'drafted',100),(2,1,2,1,'revised',200),(3,1,3,1,'row_finished',400),(4,1,4,1,'revised',500);
                INSERT INTO memory_todo_items (item_id,item_uuid,task_id,first_revision,row_key,origin)
                    VALUES (1,'item-one',1,1,'r1','plan'),(2,'item-two',1,1,'r2','plan');
                INSERT INTO memory_todo_item_states (item_id,todo_revision_id,position,title,status,check_verdict,expectation_revision_id)
                    VALUES (1,3,0,'Save','done','passed',2),(1,4,0,'Saved','done','passed',2),
                           (2,1,1,'Inspect','pending',NULL,NULL);
                INSERT INTO memory_events (event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
                    VALUES (1,'before','app','test','action',150,'complete'),
                           (2,'during','app','test','action',300,'complete'),
                           (3,'other','app','test','action',300,'complete'),
                           (4,'after','app','test','action',450,'complete');
                INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status)
                    VALUES (1,'click','completed'),(2,'click','completed'),(3,'click','completed'),(4,'click','completed');
                INSERT INTO memory_call_steps (event_id,item_id) VALUES (1,1),(2,1),(3,2),(4,1);
                """)
        }
        let reopened = try SQLiteConnection(path: url.path)
        let handle = SQLiteSnapshot(connection: reopened)
        let fact = try #require(try SQLiteProcedureRows.rowCheck(handle, call: "during"))
        #expect(fact.itemID == "item-one")
        #expect(fact.verdict == .passed)
        #expect(fact.expectationRevision == 2)
        for call in ["before", "other", "after"] {
            #expect(try SQLiteProcedureRows.rowCheck(handle, call: call) == nil)
        }
    }
}
