import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 content rules")
struct SchemaMigration22ContentTests {
    @Test
    func partStatesKeepStateAndUseClosedHistoricalCodes() throws {
        try fixture { content, _, _ throws in
            let fields = try content.fields(for: "memory_part_states")
            #expect(try value(fields["reason_code"], row: [:]) == .text("migrated"))
            #expect(try value(fields["recorded_by"], row: ["recorded_by": .text("braus-cli")]) == .text("person"))
            #expect(try value(fields["recorded_by"], row: ["recorded_by": .text("other")]) == .text("braus"))
            #expect(fields["state"] == nil)
        }
    }

    @Test
    func valueDigestsExistOnlyForAvailableText() throws {
        try fixture { content, _, _ throws in
            for table in ["memory_task_values", "memory_parameter_bindings"] {
                let field = try content.fields(for: table)["value_digest"]
                #expect(try value(field, row: ["content": .text("text"), "text_value": .text("café")])
                        == .blob(Array(Digest16.of("café"))))
                for code in ["missing", "withheld"] {
                    #expect(try value(field, row: ["content": .text(code), "text_value": .null]) == .null)
                }
            }
        }
    }

    @Test
    func savedQueriesAndNeedsUseTheSG1Mask() throws {
        try fixture(rows: Self.taskRows) { content, source, _ throws in
            try source.execute("ROLLBACK")
            try source.execute("""
                INSERT INTO memory_recall_queries(query_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,reason,
                    remaining_work,channel,search_status,search_note,candidate_limit,candidates_considered,coverage,delivery,selector_version,recorded_at_ms)
                VALUES ('query','task','attempt',1,'cli','test','initial','Find secret-file.txt','none','unavailable','offline',10,0,'unknown','nothing','test',0);
                BEGIN;
                """)
            let masked = RecallQueryMasking.masked("Find secret-file.txt", values: [
                try TaskValue(name: "input", kind: .text, content: .text("secret-file.txt"), source: .request)
            ])
            let queryField = try content.fields(for: "memory_recall_queries")["remaining_work"]
            let needField = try content.fields(for: "memory_recall_needs")["text"]
            #expect(try value(queryField, row: ["task_id": .text("task"), "task_revision": .integer(1),
                                               "remaining_work": .text("Find secret-file.txt")]) == .text(masked))
            #expect(try value(needField, row: ["query_id": .text("query"), "text": .text("Find secret-file.txt")]) == .text(masked))
            #expect(try source.query("SELECT text_value FROM memory_task_values") { try $0.text(0) } == ["secret-file.txt"])
        }
    }

    @Test
    func documentsShareTextAndVectorsKeepCompleteSpaceIdentity() throws {
        try fixture(rows: """
            INSERT INTO memory_recall_spaces(space_id,model_id,model_revision,weights_digest,tokenizer_digest,dimensions,
                pooling,normalization,precision,query_prefix,document_prefix,maximum_tokens,recorded_at_ms)
            VALUES ('space-one','same-model','revision-a',printf('%064d',0),printf('%064d',1),1,'mean','l2','float32','','',128,0),
                   ('space-two','same-model','revision-b',printf('%064d',0),printf('%064d',2),1,'mean','l2','float32','query:','',128,0);
            INSERT INTO memory_recall_documents(document_digest,document_format,text,recorded_at_ms)
            VALUES (printf('%064d',3),'recall-document-1','Stored method',0);
            INSERT INTO memory_recall_vectors(space_id,document_digest,token_count,truncated,vector,recorded_at_ms)
            VALUES ('space-one',printf('%064d',3),2,0,x'0000803f',0),('space-two',printf('%064d',3),2,0,x'000080bf',0);
            """) { content, source, target throws in
            let plan = content.plan
            for table in ["memory_recall_spaces", "memory_recall_documents", "memory_recall_vectors"] {
                try SQLiteMigration22RowCopy.copy(table, from: source, into: target, keys: plan.keys,
                                                  fields: plan.fields(for: table, overriding: content.fields(for: table)))
            }
            let spaces: [String?] = try target.query("""
                SELECT s.space_id FROM memory_recall_vectors v JOIN memory_recall_spaces s USING(space_int_id) ORDER BY s.space_id
                """) { try $0.text(0) }
            #expect(spaces == ["space-one", "space-two"])
            let vectors: [[UInt8]?] = try target.query("SELECT vector FROM memory_recall_vectors ORDER BY space_int_id") { $0.bytes(0) }
            #expect(vectors == [[0,0,128,63],[0,0,128,191]])
            let digests: [[UInt8]?] = try target.query("SELECT digest FROM memory_recall_texts") { $0.bytes(0) }
            #expect(digests == [Array(Digest16.of("Stored method"))])
        }
    }

    private static let taskRows = """
        INSERT INTO memory_tasks(task_id,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
        VALUES ('task',1,'cli','test',0,'open',1);
        INSERT INTO memory_task_occurrences(task_occurrence_id,started_at_ms,status) VALUES ('attempt',0,'in_progress');
        INSERT INTO memory_task_revisions(task_id,revision,recorded_at_ms,change_kind,goal)
        VALUES ('task',1,0,'opened','Find input');
        INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision)
        VALUES ('attempt','task',1,'cli','test',0,1);
        INSERT INTO memory_task_values(value_id,task_id,revision,position,name,value_kind,content,text_value,sensitivity,source)
        VALUES (1,'task',1,0,'input','text','text','secret-file.txt','ordinary','request');
        """

    private func value(_ field: SQLiteMigration22RowCopy.Field?, row: [String: SQLiteValue]) throws -> SQLiteValue {
        guard let field else { throw SQLiteMigration22.Refusal.verificationFailed(["missing content rule"]) }
        switch field {
        case .constant(let value): return value
        case .derived(let convert): return try convert(row)
        default: throw SQLiteMigration22.Refusal.verificationFailed(["unexpected content rule"])
        }
    }

    private func fixture(
        rows: String = "",
        _ body: (SQLiteMigration22Content, SQLiteConnection, SQLiteConnection) throws -> Void
    ) throws {
        let source = try SQLiteConnection(path: ":memory:")
        let target = try SQLiteConnection(path: ":memory:")
        defer { source.close(); target.close() }
        for object in try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text()) where object.type == "table" {
            try source.execute(try #require(object.sql))
        }
        try source.execute(rows)
        try source.execute("BEGIN")
        try target.execute(SQLiteMigration22File.text().components(separatedBy: "-- section: indexes")[0])
        try target.execute("BEGIN")
        let plan = try SQLiteMigration22Plan(source: source, target: target)
        let content = try SQLiteMigration22Content(source: source, target: target, plan: plan)
        try body(content, source, target)
    }
}
