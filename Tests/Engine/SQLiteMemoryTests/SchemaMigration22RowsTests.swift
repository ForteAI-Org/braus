import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 complete row conversion")
struct SchemaMigration22RowsTests {
    @Test
    func migratesUnified19IntoAnExactSelfContained22File() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Complete-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("source.sqlite.migrating-22-test")
        try makeSource(at: source)
        let before = try Data(contentsOf: source)
        var report: SQLiteMigration22Rows.Report?
        try SQLiteMigration22.withAdmission(from: source, shape: .unified19, canMigrate: { true }, availableSpace: { _ in Int64.max }) { old in
            try SQLiteMigration22Normalization.withSource(old, shape: .unified19,
                workingAt: directory.appendingPathComponent("unused")) { normalized in
                try SQLiteMigration22File.create(at: target) { db in
                    report = try SQLiteMigration22Rows.copy(from: normalized, into: db, at: 0)
                } verify: { db throws in
                    let counts = try #require(report).rowsByTable
                    #expect(counts.count == 121)
                    for (table, count) in counts {
                        let found = try db.query("SELECT count(*) FROM \(table)") { $0.integer(0) }
                        #expect(found == [Int64(count)])
                    }
                }
            }
        }
        let completed = try #require(report)
        #expect(completed.outcomes.converted == 0 && completed.outcomes.partiallyConverted == 1)
        #expect(completed.observationsConverted == 2)
        #expect(try Data(contentsOf: source) == before)
        try SQLiteMigration22.withSource(at: target) { db throws in
            #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [22])
            #expect(try db.query("PRAGMA integrity_check") { try $0.text(0) } == ["ok"])
            #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
            #expect(try SQLiteMemorySchema.objects(in: db) == SQLiteMemorySchema.objects(of: SQLiteMigration22File.text()))
            #expect(try db.query("SELECT count(*) FROM memory_element_sets") { $0.integer(0) } == [1])
            #expect(try db.query("SELECT job_kind FROM memory_consolidation_queue") { try $0.text(0) } == ["index_rebuild"])
            #expect(try db.query("SELECT count(*) FROM memory_recall_vectors") { $0.integer(0) } == [0])
            #expect(try db.query("SELECT event_id FROM memory_agent_actions") { $0.integer(0) } == [91])
            #expect(try db.query("SELECT event_uuid FROM memory_events ORDER BY event_id") { try $0.text(0) }
                    == ["capture-a", "capture-b", "gesture"])
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: target.path + suffix))
        }
        let writer = try SQLiteConnection(path: target.path, mayCreate: false)
        defer { writer.close() }
        #expect(throws: (any Error).self) {
            try writer.execute("""
                INSERT INTO brain_anchors(anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
                VALUES (2,1,1,'control','Open',0,0)
                """)
        }
    }

    @Test
    func procedureDigestsUseSavedCallUUIDsAndReconstructedInterpretation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Procedure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("built.sqlite")
        try makeSource(at: source, moreRows: Self.procedureRows)
        try SQLiteMigration22.withSource(at: source) { old in
            try SQLiteMigration22File.create(at: target) { db in
                _ = try SQLiteMigration22Rows.copy(from: old, into: db, at: 0)
            } verify: { db throws in
                let candidate: [[UInt8]?] = try db.query("SELECT structure_digest FROM memory_procedure_candidates") { $0.bytes(0) }
                #expect(candidate == [Array(Digest16.of("app-blocks-2\n7:gesture"))])
                let interpretation = try ProcedureInterpretation(candidateID: "1", parts: [
                    PartStatement(reference: .procedure, label: "Save method", outcome: .completed),
                    PartStatement(reference: .step(0), label: "Save", outcome: nil)
                ], parameters: [
                    ParameterStatement(name: "input", role: "file name", kind: .text, content: .text("demo.txt"), source: .request)
                ], uses: [UseStatement(stepPosition: 0, argumentName: "target", pieces: [.literal("Save "), .parameter("input")])])
                let payload: [[UInt8]?] = try db.query("SELECT payload_digest FROM memory_procedure_interpretations") { $0.bytes(0) }
                #expect(payload == [Array(Digest16.of(interpretation.canonical))])
                let codes: [[String?]] = try db.query("SELECT state,reason_code,recorded_by FROM memory_part_states") {
                    [try $0.text(0),try $0.text(1),try $0.text(2)]
                }
                #expect(codes == [["usable", "migrated", "person"]])
            }
        }
    }

    @Test
    func distinctCandidatesInOneAttemptKeepDistinctTemporaryDigests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Candidates-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("built.sqlite")
        try makeSource(at: source, moreRows: Self.procedureRows + """
            INSERT INTO memory_procedure_candidates(candidate_id,task_id,task_occurrence_id,policy_version,structure_digest,built_at_ms,step_count,block_count)
            VALUES ('candidate-later','task','attempt','app-blocks-2','another-old-digest',1,1,1);
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
            VALUES (92,'gesture2','cli','test','action',1,1,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status,result_kind)
            VALUES ('gesture2',1,'act','completed','acted_noop');
            INSERT INTO memory_candidate_steps(candidate_id,position,step_occurrence_id,call_event_id,block_index,app_id)
            VALUES ('candidate-later',0,'occur','gesture2',0,1);
            """)
        try SQLiteMigration22.withSource(at: source) { old in
            try SQLiteMigration22File.create(at: target) { db in
                _ = try SQLiteMigration22Rows.copy(from: old, into: db, at: 0)
            } verify: { db throws in
                let digests = try db.query("SELECT structure_digest FROM memory_procedure_candidates ORDER BY candidate_id") { $0.bytes(0) }
                #expect(digests == [Array(Digest16.of("app-blocks-2\n7:gesture")), Array(Digest16.of("app-blocks-2\n8:gesture2"))])
            }
        }
    }

    @Test
    func sceneShapeUsesItsSceneIdentityRatherThanItsOwnRowID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Shape-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let target = directory.appendingPathComponent("built.sqlite")
        try makeSource(at: source, moreRows: "INSERT INTO brain_scene_shapes(scene_id,app_id,role_key) VALUES ('scene-b',1,'button')")
        try SQLiteMigration22.withSource(at: source) { old in
            try SQLiteMigration22File.create(at: target) { db in
                _ = try SQLiteMigration22Rows.copy(from: old, into: db, at: 0)
            } verify: { db throws in
                #expect(try db.query("SELECT s.scene_uuid FROM brain_scene_shapes x JOIN brain_scenes s USING(scene_id)") { try $0.text(0) } == ["scene-b"])
            }
        }
    }

    private static let procedureRows = """
        INSERT INTO memory_tasks(task_id,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
        VALUES ('task',1,'cli','test',0,'open',1);
        INSERT INTO memory_task_revisions(task_id,revision,recorded_at_ms,change_kind,goal) VALUES ('task',1,0,'opened','Save');
        INSERT INTO memory_task_occurrences(task_occurrence_id,started_at_ms,status) VALUES ('attempt',0,'in_progress');
        INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision)
        VALUES ('attempt','task',1,'cli','test',0,1);
        INSERT INTO memory_routes(route_id,name,status,created_at_ms) VALUES ('method','Save method','active',0);
        INSERT INTO memory_route_steps(step_id,route_id,position,step_kind,goal_text,app_id) VALUES ('step','method',0,'goal','Save',1);
        INSERT INTO memory_step_occurrences(step_occurrence_id,task_occurrence_id,step_id,started_at_ms,status)
        VALUES ('occur','attempt','step',0,'completed');
        INSERT INTO memory_task_events(task_occurrence_id,event_id,position,role) VALUES ('attempt','gesture',0,'action');
        INSERT INTO memory_step_events(step_occurrence_id,event_id,position,role) VALUES ('occur','gesture',0,'action');
        INSERT INTO memory_route_parameters(parameter_id,route_id,name,direction,value_type,is_required)
        VALUES ('parameter','method','input','input','text',1);
        INSERT INTO memory_parameter_details(parameter_id,route_id,role,value_kind,sensitivity)
        VALUES ('parameter','method','file name','text','ordinary');
        INSERT INTO memory_parameter_bindings(parameter_id,route_id,task_occurrence_id,content,text_value,source)
        VALUES ('parameter','method','attempt','text','demo.txt','request');
        INSERT INTO memory_step_operations(operation_id,route_id,step_id,position,tool_kind,app_id)
        VALUES ('operation','method','step',0,'act',1);
        INSERT INTO memory_operation_argument_segments(route_id,operation_id,argument_name,argument_position,argument_index,segment_position,segment_kind,literal_text,parameter_id)
        VALUES ('method','operation','target',0,0,0,'literal','Save ',NULL),
               ('method','operation','target',0,0,1,'parameter',NULL,'parameter');
        INSERT INTO memory_procedure_candidates(candidate_id,task_id,task_occurrence_id,policy_version,structure_digest,built_at_ms,step_count,block_count)
        VALUES ('candidate','task','attempt','app-blocks-2','old-fnv',0,1,1);
        INSERT INTO memory_candidate_steps(candidate_id,position,step_occurrence_id,call_event_id,block_index,app_id)
        VALUES ('candidate',0,'occur','gesture',0,1);
        INSERT INTO memory_procedure_interpretations(interpretation_id,candidate_id,revision,contract_version,payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
        VALUES ('interpretation','candidate',1,1,'old-fnv','cli','test',1,'running',0);
        INSERT INTO memory_procedure_versions(route_id,interpretation_id,candidate_id,task_id,task_occurrence_id,contract_version,built_at_ms)
        VALUES ('method','interpretation','candidate','task','attempt',1,0);
        INSERT INTO memory_procedure_parts(part_id,route_id,part_kind,parent_part_id,first_position,last_position,step_id,app_id,label,declared_outcome)
        VALUES ('method/procedure','method','procedure',NULL,0,0,NULL,1,'Save method','completed'),
               ('method/step-0','method','step','method/procedure',0,0,'step',1,'Save','not_declared');
        INSERT INTO memory_part_states(part_id,sequence,state,reason,recorded_by,recorded_at_ms)
        VALUES ('method/step-0',1,'usable','historical decision','braus-cli',0);
        """

    private func makeSource(at url: URL, moreRows: String = "") throws {
        let db = try SQLiteConnection(path: url.path)
        defer { db.close() }
        let objects = try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text())
        for object in objects where object.type == "table" { try db.execute(try #require(object.sql)) }
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES (1,'test.synthetic');
            INSERT INTO brain_anchors(anchor_id,app_id,insertion_order,kind,label,first_seen_ms,last_seen_ms)
            VALUES ('anchor',1,0,'control','Save',0,0);
            INSERT INTO brain_scenes(scene_id,app_id,title_bucket,scene_kind,first_seen_ms,last_seen_ms)
            VALUES ('scene-a',1,'','window',0,0),('scene-b',1,'','window',0,0);
            INSERT INTO brain_scene_elements(scene_element_id,app_id,scene_id,element_key,role,kind,label,label_origin,first_seen_ms,last_seen_ms)
            VALUES ('element-a',1,'scene-a','save','AXButton','control','Save','title',0,0),
                   ('element-b',1,'scene-b','save','AXButton','control','Save','title',0,0);
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,app_id,occurred_at_ms,capture_status)
            VALUES (7,'capture-a','cli','test','observation',1,0,'complete'),
                   (29,'capture-b','cli','test','observation',1,0,'complete'),
                   (91,'gesture','cli','test','action',1,0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,app_id,tool_kind,execution_status,result_kind)
            VALUES ('gesture',1,'act','completed','acted_noop');
            INSERT INTO memory_operation_arguments(event_id,argument_name,position,value_kind,text_value)
            VALUES ('gesture','verb',0,'text','set_toggle');
            INSERT INTO memory_event_observations(observation_id,event_id,phase,observation_kind,status,surface_kind)
            VALUES (1,'capture-a','current','capture','complete','window'),(3,'capture-b','current','capture','complete','window');
            INSERT INTO memory_event_observations(observation_id,event_id,phase,observation_kind,status,parent_observation_id,role,element_kind,label,label_origin,container_path)
            VALUES (2,'capture-a','current','element','observed',1,'AXButton','control','Save','title',''),
                   (4,'capture-b','current','element','observed',3,'AXButton','control','Save','title','');
            PRAGMA user_version=19;
            """)
        try db.execute(moreRows)
        for object in objects where object.type != "table" { try db.execute(try #require(object.sql)) }
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }
}
