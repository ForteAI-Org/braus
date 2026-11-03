import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 row transfer")
struct SchemaMigration22RowCopyTests {
    @Test
    func copiesCallsWithExplicitIntegerReferencesBeforeConvertingOutcomes() throws {
        let source = try source()
        defer { source.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Rows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let target = directory.appendingPathComponent("memory.sqlite.migrating-22-test")
        try SQLiteMigration22File.create(at: target) { db throws in
            let keys = try SQLiteMigration22Keys(in: db)
            try keys.assign(from: source, table: "memory_events", columns: ["event_id"], idColumn: "local_order")
            #expect(try SQLiteMigration22RowCopy.copy("brain_apps", from: source, into: db, keys: keys) == 1)
            #expect(try SQLiteMigration22RowCopy.copy("memory_events", from: source, into: db, keys: keys, fields: [
                "event_id": .identity("memory_events", ["event_id"]), "event_uuid": .source("event_id"),
                "parent_event_id": .identity("memory_events", ["parent_event_id"]),
                "origin_event_id": .identity("memory_events", ["origin_event_id"])
            ]) == 2)
            #expect(try SQLiteMigration22RowCopy.copy("memory_agent_actions", from: source, into: db, keys: keys, fields: [
                "event_id": .identity("memory_events", ["event_id"])
            ]) == 2)
            #expect(try SQLiteMigration22RowCopy.copy("memory_operation_arguments", from: source, into: db, keys: keys, fields: [
                "event_id": .identity("memory_events", ["event_id"]),
                "operation_id": .identity("memory_step_operations", ["operation_id"]),
                "route_id": .identity("memory_routes", ["route_id"]),
                "parameter_id": .identity("memory_route_parameters", ["parameter_id"]),
                "anchor_id": .identity("brain_anchors", ["anchor_id"]),
                "menu_command_id": .identity("brain_menu_commands", ["menu_command_id"])
            ]) == 2)
            let outcomes = try SQLiteMigration22Outcomes.convert(from: source, into: db)
            #expect(outcomes.converted == 0 && outcomes.partiallyConverted == 1)
        } verify: { db throws in
            #expect(try db.query("SELECT event_id,parent_event_id FROM memory_events ORDER BY event_id") {
                [$0.integer(0), $0.integer(1)]
            } == [[7,nil],[81,7]])
            #expect(try db.query("SELECT event_uuid FROM memory_events ORDER BY event_id") { try $0.text(0) }
                    == ["first", "second"])
            #expect(try db.query("SELECT text_value FROM memory_operation_arguments ORDER BY argument_id") {
                Array((try $0.text(0) ?? "").utf8)
            } == [Array("set_toggle".utf8), Array("caf\u{e9}\u{0}|cafe\u{301}".utf8)])
            #expect(try db.query("SELECT effect,outcome_origin,learnable,result_kind FROM memory_agent_actions WHERE event_id=7") {
                [try $0.text(0),try $0.text(1),try $0.text(2),try $0.text(3)]
            } == [["confirmed","converted_partial","0",nil]])
        }
    }

    @Test
    func changedStorageClassRequiresAnExplicitRule() throws {
        try fixture { source, target, keys throws in
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["row column memory_events.event_id"])) {
                _ = try SQLiteMigration22RowCopy.copy("memory_events", from: source, into: target, keys: keys)
            }
        }
    }

    @Test
    func everyTransferredTableChecksItsRowCount() throws {
        try fixture { source, target, keys throws in
            try target.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES (2,'test.preexisting')")
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["row count brain_apps: expected 1, found 2"])) {
                _ = try SQLiteMigration22RowCopy.copy("brain_apps", from: source, into: target, keys: keys)
            }
        }
    }

    @Test
    func emptyIdentityRuleCannotBecomeAnAutomaticID() throws {
        try fixture { source, target, keys throws in
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["row fields of brain_apps"])) {
                _ = try SQLiteMigration22RowCopy.copy("brain_apps", from: source, into: target, keys: keys,
                                                     fields: ["app_id": .identity("brain_apps", [])])
            }
            #expect(try target.query("SELECT count(*) FROM brain_apps") { $0.integer(0) } == [0])
        }
    }

    @Test
    func optionalCompositeReferenceUsesSQLNullSemantics() throws {
        try fixture { source, target, keys throws in
            try source.execute("ROLLBACK")
            try source.execute("""
                INSERT INTO memory_tasks(task_id,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
                VALUES ('task',1,'cli','test',0,'open',1);
                INSERT INTO memory_task_occurrences(task_occurrence_id,started_at_ms,status)
                VALUES ('attempt',0,'in_progress');
                INSERT INTO memory_task_values(value_id,task_id,task_occurrence_id,checkpoint_sequence,position,name,value_kind,content,text_value,sensitivity,source)
                VALUES (1,'task','attempt',1,0,'input','text','text','saved','ordinary','request');
                BEGIN;
                """)
            try keys.assign(from: source, table: "memory_tasks", columns: ["task_id"])
            try keys.assign(from: source, table: "memory_task_occurrences", columns: ["task_occurrence_id"])
            #expect(try SQLiteMigration22RowCopy.copy("memory_task_values", from: source, into: target, keys: keys, fields: [
                "task_id": .identity("memory_tasks", ["task_id"]),
                "task_occurrence_id": .identity("memory_task_occurrences", ["task_occurrence_id"]),
                "task_revision_id": .identity("memory_task_revisions", ["task_id", "revision"])
            ]) == 1)
            #expect(try target.query("SELECT task_revision_id FROM memory_task_values") { $0.integer(0) } == [nil])
        }
    }

    @Test
    func unknownFieldsAndTablesRefuseBeforeCopying() throws {
        try fixture { source, target, keys throws in
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["row table"])) {
                _ = try SQLiteMigration22RowCopy.copy("unknown", from: source, into: target, keys: keys)
            }
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["row fields of brain_apps"])) {
                _ = try SQLiteMigration22RowCopy.copy("brain_apps", from: source, into: target, keys: keys,
                                                     fields: ["unknown": .constant(.null)])
            }
            #expect(try target.query("SELECT count(*) FROM brain_apps") { $0.integer(0) } == [0])
        }
    }

    private func fixture(_ body: (SQLiteConnection, SQLiteConnection, SQLiteMigration22Keys) throws -> Void) throws {
        let source = try source()
        defer { source.close() }
        let target = try SQLiteConnection(path: ":memory:")
        defer { target.close() }
        try target.execute(SQLiteMigration22File.text())
        try target.execute("BEGIN IMMEDIATE")
        try body(source, target, SQLiteMigration22Keys(in: target))
    }

    private func source() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        for table in try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text()) where table.type == "table" {
            try db.execute(try #require(table.sql))
        }
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic');
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status,parent_event_id,parent_position)
            VALUES (7,'first','cli','synthetic','action',0,'not_applicable',NULL,NULL),
                   (81,'second','cli','synthetic','action',0,'not_applicable','first',0);
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,result_kind)
            VALUES ('first','act','completed','acted_noop'),('second','status','planned',NULL);
            INSERT INTO memory_operation_arguments(argument_id,event_id,argument_name,position,value_kind,text_value)
            VALUES (1,'first','verb',0,'text','set_toggle');
            """)
        try db.run("""
            INSERT INTO memory_operation_arguments(argument_id,event_id,argument_name,position,value_kind,text_value)
            VALUES (2,'first','target',0,'text',?)
            """, [.text("caf\u{e9}\u{0}|cafe\u{301}")])
        try db.execute("BEGIN")
        return db
    }
}
