import EngineCore
import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema22 call field rows")
struct Schema22CallFieldTests {
    @Test
    func fieldsUseIntegerKeysAndReturnOriginalUUIDs() async throws {
        let store = try await makeStore()
        let result = try StructuredField(path: "/id", kind: .text, text: "synthetic-id")
        #expect(try await store.write { try SQLiteCallFieldRows.record($0, results: [result], of: "earlier") } == .committed)
        #expect(try await store.write { try SQLiteCallFieldRows.record($0, results: [result], of: "earlier") } == .alreadyApplied)
        let argument = CallArgumentField(field: try StructuredField(path: "/item_id", kind: .text, text: "synthetic-id"))
        #expect(try await store.write { try SQLiteCallFieldRows.record($0, arguments: [argument], of: "later") } == .committed)
        let expected = CallArgumentField(field: argument.field, kind: .resultReference, sourceEventID: "earlier", sourcePath: "/id")
        #expect(try await store.read { try SQLiteCallFieldRows.arguments($0, "later") } == [expected])
        #expect(try await store.read { try SQLiteCallFieldRows.results($0, "earlier") } == [result])
        #expect(try await store.read { try SQLiteCallFieldRows.historicalValues($0, ["synthetic-id"], attemptID: "attempt") }.isEmpty)
        #expect(try await store.read { try SQLiteCallFieldRows.historicalValues($0, ["synthetic-id"], attemptID: "unknown") } == ["synthetic-id"])
        #expect(try await store.read { try $0.query("SELECT event_id,source_event_id FROM memory_call_argument_fields") {
            [$0.integer(0), $0.integer(1)]
        } } == [[2,1]])
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }

    @Test
    func ambiguousFieldsAndSaltedContextRemainIdempotent() async throws {
        let store = try await makeStore()
        let result = try StructuredField(path: "/id", kind: .text, text: "synthetic-id")
        _ = try await store.write { try SQLiteCallFieldRows.record($0, results: [result], of: "earlier") }
        _ = try await store.write { try SQLiteCallFieldRows.record($0, results: [result], of: "later") }
        let argument = CallArgumentField(field: try StructuredField(path: "/item_id", kind: .text, text: "synthetic-id"))
        _ = try await store.write { try SQLiteCallFieldRows.record($0, arguments: [argument], of: "last") }
        #expect(try await store.read { try SQLiteCallFieldRows.arguments($0, "last") } == [CallArgumentField(field: argument.field, kind: .ambiguousReference)])
        let context = try CallDataContext(service: "fake.service", route: .adapter, account: "fake@example.test", accountSource: .argument)
        #expect(try await store.write { try SQLiteCallFieldRows.record($0, context: context, of: "last") } == .committed)
        #expect(try await store.write { try SQLiteCallFieldRows.record($0, context: context, of: "last") } == .alreadyApplied)
        let stored = try #require(try await store.read { try SQLiteCallFieldRows.context($0, "last") })
        #expect(stored.accountRef?.count == 16)
        #expect(stored.accountRef != context.account)
        #expect(try await store.read { try $0.query("SELECT count(*) FROM memory_identity_salts") { $0.integer(0) } } == [1])
        await store.close()
    }

    @Test
    func pendingCallRefusesFieldWritesThroughCoherence() async throws {
        let store = try await makeStore()
        _ = try await store.write { try $0.execute("UPDATE memory_agent_actions SET execution_status='started',started_at_ms=0 WHERE event_id=3") }
        let field = try StructuredField(path: "/id", kind: .text, text: "synthetic-id")
        await #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["memory_call_result_fields_concluded_call"])) {
            _ = try await store.write { try SQLiteCallFieldRows.record($0, results: [field], of: "last") }
        }
        #expect(try await store.read { try SQLiteCallFieldRows.results($0, "last") }.isEmpty)
        await store.close()
    }

    private func makeStore() async throws -> SQLiteMemoryStore {
        let store = SQLiteMemoryStore(url: try temporaryDatabase("fields22"), schema: .version22)
        try await store.open()
        _ = try await store.write { db in
            let rows = """
                INSERT INTO memory_tasks(task_id,task_uuid,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
                VALUES (1,'task',1,'cli','test',0,'open',1);
                INSERT INTO memory_task_revisions(task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
                VALUES (1,1,1,0,'opened','Save');
                INSERT INTO memory_task_occurrences(task_occurrence_id,task_occurrence_uuid,started_at_ms,status)
                VALUES (1,'attempt',0,'in_progress');
                INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision,task_revision_id)
                VALUES (1,1,1,'cli','test',0,1,1);
                INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
                VALUES (1,'earlier','cli','test','action',0,'not_applicable'),(2,'later','cli','test','action',1,'not_applicable'),
                       (3,'last','cli','test','action',2,'not_applicable');
                INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status) VALUES (1,'app_call','completed'),(2,'app_call','completed'),(3,'app_call','completed');
                INSERT INTO memory_task_events(task_occurrence_id,event_id,position,role) VALUES (1,1,0,'action'),(1,2,1,'action'),(1,3,2,'action');
                """
            for statement in rows.split(separator: ";") { try db.execute(String(statement)) }
        }
        return store
    }
}
