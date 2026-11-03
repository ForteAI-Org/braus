import Foundation
import Memory
import Testing
@testable import SQLiteMemory

struct TodoArchiveTests {
    private func database(path: String = ":memory:", declaresParameters: Bool = true) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try db.execute(String(contentsOf: root.appendingPathComponent(
            "Sources/Engine/SQLiteMemory/Resources/memory-schema-22.sql"), encoding: .utf8))
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("""
            INSERT INTO memory_tasks (task_id,task_uuid,contract_version,source,source_stream_id,
                trace_id,opened_at_ms,status,current_revision) VALUES (1,'task',1,'app','test','conversation',0,'open',1);
            INSERT INTO memory_task_revisions (task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
                VALUES (1,1,1,0,'opened','Save');
            INSERT INTO memory_task_occurrences (task_occurrence_id,task_occurrence_uuid,started_at_ms,status)
                VALUES (1,'attempt',0,'in_progress');
            INSERT INTO memory_task_attempts (task_occurrence_id,task_id,ordinal,source,source_stream_id,
                opened_at_ms,opened_at_revision,task_revision_id) VALUES (1,1,1,'app','test',0,1,1);
            INSERT INTO memory_procedure_candidates (candidate_id,task_id,task_occurrence_id,policy_version,
                structure_digest,built_at_ms,step_count,block_count) VALUES (1,1,1,'test',zeroblob(16),0,1,1);
            INSERT INTO memory_procedure_interpretations (interpretation_id,candidate_id,revision,contract_version,
                payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
                VALUES (1,1,1,1,zeroblob(16),'app','test',1,'running',0);
            INSERT INTO memory_routes (route_id,route_uuid,name,status,created_at_ms) VALUES (1,'version','Save','draft',0);
            INSERT INTO memory_procedure_versions (route_id,interpretation_id,candidate_id,task_id,
                task_occurrence_id,contract_version,built_at_ms) VALUES (1,1,1,1,1,1,0);
            INSERT INTO memory_procedure_parts (part_id,part_uuid,route_id,part_kind,first_position,last_position,
                label,declared_outcome) VALUES (1,'part',1,'procedure',0,0,'Save','completed');
            """)
        for (position, name) in (declaresParameters ? ["output", "destination", "original"] : []).enumerated() {
            try db.run("""
                INSERT INTO memory_task_values(task_id,revision,position,name,value_kind,content,text_value,
                    sensitivity,source,task_revision_id) VALUES(1,1,?,?,'text','text',?,'ordinary','request',1)
                """, [.integer(Int64(position)), .text(name), .text("/" + name)])
        }
        return db
    }

    private func revision(_ number: Int, _ rows: [TodoRow], change: TodoRevision.Change = .drafted,
                          calls: [CallAttribution] = []) -> TodoRevision {
        TodoRevision(taskID: "task", number: number, change: change, rows: rows,
                     attributedCalls: calls, recordedAtMS: Int64(number))
    }

    private func append(_ revision: TodoRevision, expecting: Int, db: SQLiteConnection) throws -> Todo {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let todo = try SQLiteTodoRepository.append(revision, expecting: expecting,
                                                       in: SQLiteTransaction(connection: db))
            try db.execute("COMMIT")
            return todo
        } catch {
            try db.execute("ROLLBACK")
            throw error
        }
    }

    @Test func staleRevisionAndRollbackLeaveNoPartialRows() throws {
        let db = try database()
        let row = TodoRow(id: TodoRowID(rawValue: "r1"), title: "Save document")
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        #expect(throws: TodoStoreError.self) {
            _ = try append(revision(2, [row], change: .revised(reason: "Adjust")), expecting: 0, db: db)
        }
        var changed = row
        changed.title = "Changed"
        let bad = CallAttribution(eventID: "missing-event", row: row.id)
        #expect(throws: TodoStoreError.self) {
            _ = try append(revision(2, [changed], change: .revised(reason: "Adjust"), calls: [bad]),
                           expecting: 1, db: db)
        }
        let read = try SQLiteTodoRepository.revisions(of: "task", in: SQLiteSnapshot(connection: db))
        #expect(read.count == 1)
        #expect(read.first?.rows == [row])
    }

    @Test func lateRowPartKeepsOneIdentityAndSparseStates() throws {
        let db = try database()
        var row = TodoRow(id: TodoRowID(rawValue: "r1"), title: "Save document", app: "Editor",
                          expected: .fileWritten(path: "{destination}"))
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        row.part = "part"
        row.expected = .fileAbsent(path: "{original}")
        _ = try append(revision(2, [row], change: .revised(reason: "Use another destination")), expecting: 1, db: db)
        row.status = .inProgress
        _ = try append(revision(3, [row], change: .rowStarted(row.id)), expecting: 2, db: db)
        let read = try SQLiteTodoRepository.revisions(of: "task", in: SQLiteSnapshot(connection: db))
        #expect(read.map(\.number) == [1, 2, 3])
        #expect(read[1].change == .revised(reason: "Use another destination"))
        #expect(read[2].rows == [row])
        #expect(try db.query("SELECT count(*) FROM memory_todo_items") { $0.integer(0) }.first == 1)
        #expect(try db.query("SELECT count(*) FROM memory_todo_item_states") { $0.integer(0) }.first == 3)
        #expect(try db.query("SELECT count(*) FROM memory_todo_item_expectations") { $0.integer(0) }.first == 2)
    }

    @Test func literalExpectationsAreWithheldAndNoneUsesCatalogueReason() throws {
        let db = try database()
        let rows = [
            TodoRow(id: TodoRowID(rawValue: "r1"), title: "Write", expected: .fileWritten(path: "{output}")),
            TodoRow(id: TodoRowID(rawValue: "r2"), title: "Read", expected: .fileContains(path: "/private/value", text: "secret")),
            TodoRow(id: TodoRowID(rawValue: "r3"), title: "Finish", expected: .nothing(reason: "private explanation"))
        ]
        _ = try append(revision(1, rows), expecting: 0, db: db)
        let read = try #require(try SQLiteTodoRepository.current(of: "task", in: SQLiteSnapshot(connection: db)))
        #expect(read.rows[0].expected == rows[0].expected)
        #expect(read.rows[1].expected == .withheld(kind: "file_contains"))
        #expect(read.rows[2].expected == .nothing(reason: "No readable result was declared."))
        let stored = try db.query("SELECT subject_key FROM memory_todo_item_expectations") { try $0.text(0) }
        #expect(stored.allSatisfy { $0 == nil })
    }

    @Test func attributionByItemIsExactAndRevisionsDoNotInventCallLinks() throws {
        let db = try database()
        try db.execute("""
            INSERT INTO memory_events (event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
                VALUES (1,'a','app','test','action',1,'complete'),(2,'b','app','test','action',2,'complete'),
                       (3,'c','app','test','action',3,'complete'),(4,'d','app','test','action',4,'complete');
            INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status)
                VALUES (1,'click','completed'),(2,'click','completed'),(3,'click','completed'),(4,'click','completed');
            """)
        let r1 = TodoRow(id: .init(rawValue: "r1"), title: "Prepare")
        let r2 = TodoRow(id: .init(rawValue: "r2"), title: "Save")
        _ = try append(revision(1, [r1, r2]), expecting: 0, db: db)
        let calls = ["a", "b", "c"].map { CallAttribution(eventID: $0, row: r1.id) }
        var started = r2
        started.status = .inProgress
        _ = try append(revision(2, [r1, started], change: .rowStarted(r2.id), calls: calls), expecting: 1, db: db)
        var finished = started
        finished.status = .done
        _ = try append(revision(3, [r1, finished], change: .rowFinished(r2.id, verdict: .passed),
                                calls: [.init(eventID: "d", row: r2.id)]), expecting: 2, db: db)
        let handle = SQLiteSnapshot(connection: db)
        #expect(try SQLiteTodoRepository.attributedCalls(ofTask: "task", item: r1.id, in: handle) == calls)
        #expect(try SQLiteTodoRepository.attributedCalls(ofTask: "task", item: r2.id, in: handle)
            == [.init(eventID: "d", row: r2.id)])
        #expect(try SQLiteTodoRepository.revisions(of: "task", in: handle).allSatisfy { $0.attributedCalls.isEmpty })
        try SQLiteTodoRepository.record(.init(verdict: .passed, scope: .declaredPredicatesOnly),
                                        attempt: "attempt", in: SQLiteTransaction(connection: db))
        let stored = try db.query("SELECT verdict,scope,goal_match FROM memory_task_end_checks") {
            (try $0.text(0), try $0.text(1), $0.integer(2))
        }.first
        #expect(stored?.0 == "passed")
        #expect(stored?.1 == "declared_predicates_only")
        #expect(stored?.2 == 0)
    }

    @Test func literalEqualToAnInputBecomesAParameterReference() throws {
        let db = try database(declaresParameters: false)
        try db.execute("""
            INSERT INTO memory_task_values (task_id,revision,position,name,value_kind,content,text_value,
                sensitivity,source,task_revision_id)
                VALUES (1,1,0,'output','file','text','/tmp/synthetic-output','ordinary','request',1);
            """)
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Write", expected: .fileWritten(path: "/tmp/synthetic-output"))
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        let read = try SQLiteTodoRepository.current(of: "task", in: SQLiteSnapshot(connection: db))
        #expect(read?.rows.first?.expected == .fileWritten(path: "{output}"))
        #expect(try db.query("SELECT operand,parameter_name FROM memory_todo_item_expectations") {
            try $0.text(0) == "parameter" && $0.text(1) == "output"
        }.first == true)
    }

    @Test func stoppedReferenceSurvivesReopeningAndRequiresLatestStoppedRevision() throws {
        let url = try temporaryDatabase("todo-stopped")
        let db = try database(path: url.path)
        let owner = try TaskProducer(source: .app, streamID: "test")
        var r1 = TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .inProgress)
        var r2 = TodoRow(id: .init(rawValue: "r2"), title: "Save")
        _ = try append(revision(1, [r1, r2]), expecting: 0, db: db)
        r1.status = .done
        _ = try append(revision(2, [r1, r2], change: .rowFinished(r1.id, verdict: .passed)), expecting: 1, db: db)
        r2.status = .abandoned
        _ = try append(revision(3, [r1, r2], change: .stopped), expecting: 2, db: db)
        try db.execute("UPDATE memory_tasks SET status = 'abandoned',closed_at_ms = 4 WHERE task_id = 1")
        db.close()
        let reopened = try SQLiteConnection(path: url.path)
        #expect(try SQLiteTodoRepository.stoppedReference("task", for: owner, in: reopened) == [r1])
        let restored = try SQLiteTodoRepository.stoppedTask(for: owner, traceID: "conversation", in: reopened)
        #expect(restored?.taskID == "task")
        #expect(restored?.verifiedRows == [r1])
        #expect(try SQLiteTodoRepository.stoppedTask(for: owner, traceID: "other", in: reopened) == nil)
        let foreign = try TaskProducer(source: .app, streamID: "other")
        #expect(try SQLiteTodoRepository.stoppedReference("task", for: foreign, in: reopened) == nil)
        try reopened.execute("""
            INSERT INTO memory_tasks (task_id,task_uuid,contract_version,source,source_stream_id,
                opened_at_ms,status,current_revision) VALUES (2,'later',1,'app','test',5,'open',1)
            """)
        #expect(try SQLiteTodoRepository.stoppedReference("task", for: owner, in: reopened) == nil)
        reopened.close()
    }

    @Test func anAbsentRowVerdictStaysAbsentOnReadback() throws {
        let db = try database()
        var row = TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .inProgress)
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        row.status = .done
        _ = try append(revision(2, [row], change: .rowFinished(row.id, verdict: nil)), expecting: 1, db: db)
        let read = try SQLiteTodoRepository.revisions(of: "task", in: SQLiteSnapshot(connection: db))
        #expect(read.last?.change == .rowFinished(row.id, verdict: nil))
    }

    @Test func changingAnExpectationDoesNotReuseAnEarlierPassedCheck() throws {
        let db = try database()
        var row = TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .inProgress,
                          expected: .fileWritten(path: "{output}"))
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        row.status = .done
        _ = try append(revision(2, [row], change: .rowFinished(row.id, verdict: .passed)), expecting: 1, db: db)
        #expect(try SQLiteTodoRepository.verifiedRows(ofTask: "task", in: db) == [row])
        row.expected = .fileAbsent(path: "{output}")
        _ = try append(revision(3, [row], change: .revised(reason: nil)), expecting: 2, db: db)
        #expect(try SQLiteTodoRepository.verifiedRows(ofTask: "task", in: db).isEmpty)
        _ = try append(revision(4, [row], change: .stopped), expecting: 3, db: db)
        try db.execute("UPDATE memory_tasks SET status = 'abandoned',closed_at_ms = 5 WHERE task_id = 1")
        let owner = try TaskProducer(source: .app, streamID: "test")
        #expect(try SQLiteTodoRepository.stoppedReference("task", for: owner, in: db) == [])
    }

    @Test func schema19IsUnavailableEvenIfTodoTablesArePresent() throws {
        let db = try database()
        try db.execute("PRAGMA user_version = 19")
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Prepare")
        #expect(throws: TodoStoreError.unavailable(schemaVersion: 19)) {
            _ = try append(revision(1, [row]), expecting: 0, db: db)
        }
        #expect(try db.query("SELECT count(*) FROM memory_todo_revisions") { $0.integer(0) }.first == 0)
    }

    @Test func limitsAreOwnedByTodo() {
        #expect(Todo.rowLimit == 10)
        #expect(Todo.titleLimit == 120)
        #expect(Todo.expectedLimit == 160)
    }
    @Test func revisedWithheldPredicateGetsItsOwnExpectationRevision() throws {
        let db = try database()
        var row = TodoRow(id: .init(rawValue: "r1"), title: "Save", expected: .fileWritten(path: "/first"))
        _ = try append(revision(1, [row]), expecting: 0, db: db)
        row.expected = .fileWritten(path: "/second")
        let revised = TodoRevision(taskID: "task", number: 2, change: .revised(reason: "Change result"),
            rows: [row], recordedAtMS: 2, revisedExpectations: [row.id])
        #expect(revised.forTask("task").revisedExpectations == [row.id])
        _ = try append(revised, expecting: 1, db: db)
        let states = try db.query("SELECT expectation_revision_id FROM memory_todo_item_states ORDER BY todo_revision_id") {
            $0.integer(0)
        }
        #expect(states == [1, 2])
        #expect(try db.query("SELECT count(*) FROM memory_todo_item_expectations") { $0.integer(0) }.first == 2)
    }

}

extension TodoArchiveTests {
    @Test func braceLiteralsRequireDeclaredNames() throws {
        let db = try database()
        defer { db.close() }
        let snapshot = SQLiteSnapshot(connection: db)
        let declared = try TodoExpectationColumns.encode(.fileWritten(path: "{output}"), taskID: 1, in: snapshot)
        let literal = try TodoExpectationColumns.encode(.fileWritten(path: "{private_literal}"), taskID: 1, in: snapshot)
        #expect(declared?.operand == "parameter")
        #expect(literal?.operand == "withheld")
        #expect(literal?.parameter == nil)
    }
}
