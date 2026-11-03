import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 identity plan")
struct SchemaMigration22PlanTests {
    @Test
    func resolvesEveryStructuralTableWithoutInventingContentRules() throws {
        try fixture { source, target throws in
            let plan = try SQLiteMigration22Plan(source: source, target: target)
            for table in plan.tables where !Self.contentTables.contains(table) {
                let fields = try plan.fields(for: table)
                #expect(try SQLiteMigration22RowCopy.copy(table, from: source, into: target,
                                                         keys: plan.keys, fields: fields) == 0)
            }
            #expect(plan.tables.count == 121)
        }
    }

    @Test
    func childrenShareParentIdentityAndCompositeOwnersResolve() throws {
        try fixture(rows: """
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (47,'call','cli','test','action',0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status) VALUES ('call','status','completed');
            INSERT INTO memory_agent_action_listings(event_id,listing_kind) VALUES ('call','windows');
            INSERT INTO memory_agent_action_applications(event_id,position,bundle_id,pid,name)
            VALUES ('call',0,'test.synthetic',123,'Synthetic');
            INSERT INTO memory_agent_action_windows(event_id,application_position,position,window_number)
            VALUES ('call',0,0,33);
            """) { source, target throws in
            let plan = try SQLiteMigration22Plan(source: source, target: target)
            for table in ["memory_events", "memory_agent_actions", "memory_agent_action_listings",
                          "memory_agent_action_applications", "memory_agent_action_windows"] {
                try SQLiteMigration22RowCopy.copy(table, from: source, into: target,
                                                  keys: plan.keys, fields: plan.fields(for: table))
            }
            #expect(try target.query("SELECT event_id FROM memory_agent_action_listings") { $0.integer(0) } == [47])
            #expect(try target.query("""
                SELECT w.event_id,w.window_number,a.event_id FROM memory_agent_action_windows w
                JOIN memory_agent_action_applications a USING(listing_application_id)
                """) { [$0.integer(0), $0.integer(1), $0.integer(2)] } == [[47,33,47]])
            #expect(try target.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
        }
    }

    private static let contentTables: Set<String> = [
        "memory_procedure_candidates", "memory_procedure_interpretations", "memory_part_states",
        "memory_recall_documents", "memory_recall_vectors", "brain_relations"
    ]

    private func fixture(
        rows: String = "",
        _ body: (SQLiteConnection, SQLiteConnection) throws -> Void
    ) throws {
        let source = try SQLiteConnection(path: ":memory:")
        let target = try SQLiteConnection(path: ":memory:")
        defer { source.close(); target.close() }
        for object in try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text())
        where object.type == "table" {
            try source.execute(try #require(object.sql))
        }
        try source.execute(rows)
        try source.execute("BEGIN")
        try target.execute(SQLiteMigration22File.text())
        try target.execute("BEGIN IMMEDIATE")
        try body(source, target)
    }
}
