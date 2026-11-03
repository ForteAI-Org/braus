import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence snapshot families")
struct SchemaCoherenceSnapshotFamilyTests {
    @Test
    func everyRetiredTriggerHasSnapshotOrMutationCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("Documentation/Engine/Schema22.md"), encoding: .utf8)
        let names = Set(doc.components(separatedBy: "\n").filter { $0.contains("| code |") }.compactMap {
            $0.components(separatedBy: "`").dropFirst().first
        })
        #expect(names.count == 98)
        #expect(SchemaCoherence.snapshotRuleNames.union(SchemaCoherence.mutationRuleNames) == names)
    }

    @Test
    func vectorsUseTheirCompleteSpaceDimensions() throws {
        let db = try SchemaCoherenceSnapshotTests().makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_recall_texts(text_id,digest,format,text) VALUES (1,zeroblob(16),'v1','Save');
            INSERT INTO memory_recall_spaces(space_int_id,space_id,model_id,model_revision,weights_digest,tokenizer_digest,
                dimensions,pooling,normalization,precision,query_prefix,document_prefix,maximum_tokens,recorded_at_ms)
            VALUES (1,'space','fake','v1',printf('%064d',0),printf('%064d',0),2,'mean','l2','float32','','',100,0);
            INSERT INTO memory_recall_vectors(text_id,space_int_id,token_count,truncated,vector)
            VALUES (1,1,1,0,zeroblob(4));
            """)
        #expect(try SchemaCoherence.check(db).contains("memory_recall_vectors_shape"))
        try db.execute("UPDATE memory_recall_vectors SET vector=zeroblob(8)")
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func sealedEntriesMayBelongToRetiredGenerationsAtRest() throws {
        let db = try SchemaCoherenceSnapshotTests().makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_recall_generations(generation_id,document_format,status,enumerated,started_at_ms,ended_at_ms)
            VALUES (1,'v1','retired',0,0,1);
            """)
        #expect(try SchemaCoherence.check(db).isEmpty)
    }

    @Test
    func bothArgumentFormsAreDetectedAtRest() throws {
        let db = try SchemaCoherenceSnapshotTests().makeDatabase()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_routes(route_id,route_uuid,name,status,created_at_ms) VALUES (1,'route','Save','active',0);
            INSERT INTO memory_route_steps(step_id,route_id,position,step_kind,goal_text) VALUES (1,1,0,'goal','Save');
            INSERT INTO memory_step_operations(operation_id,route_id,step_id,position,tool_kind) VALUES (1,1,1,0,'act');
            INSERT INTO memory_operation_arguments(operation_id,route_id,argument_name,position,value_kind,text_value)
            VALUES (1,1,'target',0,'text','Save');
            INSERT INTO memory_operation_argument_segments(route_id,operation_id,argument_name,argument_position,argument_index,
                segment_position,segment_kind,literal_text) VALUES (1,1,'target',0,0,0,'literal','Save');
            """)
        #expect(try SchemaCoherence.check(db).contains("memory_operation_argument_segments_alone"))
        #expect(try SchemaCoherence.check(db).contains("memory_operation_arguments_not_templated"))
    }
}
