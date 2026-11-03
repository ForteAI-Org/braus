import Foundation
import Memory
@testable import SQLiteMemory
import Testing

@Suite("RecallPlan storage")
struct RecallPlanStorageTests {
    func database() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try db.execute(String(contentsOf: root.appendingPathComponent(
            "Sources/Engine/SQLiteMemory/Resources/memory-schema-22.sql"), encoding: .utf8))
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("PRAGMA user_version=22")
        try db.execute("""
            INSERT INTO brain_apps(app_id,bundle_id) VALUES(1,'com.example.Editor');
            INSERT INTO memory_tasks(task_id,task_uuid,contract_version,source,source_stream_id,
                opened_at_ms,status,current_revision) VALUES(1,'task',1,'app','test',0,'open',1);
            INSERT INTO memory_task_revisions(task_revision_id,task_id,revision,recorded_at_ms,change_kind,goal)
                VALUES(1,1,1,0,'opened','Save');
            INSERT INTO memory_task_occurrences(task_occurrence_id,task_occurrence_uuid,started_at_ms,status)
                VALUES(1,'attempt',0,'in_progress');
            INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,
                opened_at_ms,opened_at_revision,task_revision_id) VALUES(1,1,1,'app','test',0,1,1);
            INSERT INTO memory_procedure_candidates(candidate_id,task_id,task_occurrence_id,policy_version,
                structure_digest,built_at_ms,step_count,block_count) VALUES(1,1,1,'test',zeroblob(16),0,1,1);
            INSERT INTO memory_procedure_interpretations(interpretation_id,candidate_id,revision,contract_version,
                payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
                VALUES(1,1,1,1,zeroblob(16),'app','test',1,'running',0);
            INSERT INTO memory_qualification_policies(policy_id,policy_version,status,changed_at_ms)
                VALUES(1,'test','active',0);
            """)
        return db
    }

    func version(_ id: Int, previous: Int? = nil, appID: Int = 1, db: SQLiteConnection) throws {
        if id > 1 {
            try db.run("""
                INSERT INTO memory_procedure_interpretations(interpretation_id,candidate_id,revision,contract_version,
                    payload_digest,source,source_stream_id,task_revision,attempt_state,recorded_at_ms)
                    VALUES(?,1,?,1,zeroblob(16),'app','test',1,'running',0)
                """, [.integer(Int64(id)), .integer(Int64(id))])
        }
        try db.run("INSERT INTO memory_routes(route_id,route_uuid,name,status,supersedes_route_id,created_at_ms) VALUES(?,?,'Save','draft',?,0)",
            [.integer(Int64(id)), .text("route-\(id)"), previous.map { .integer(Int64($0)) } ?? .null])
        try db.run("""
            INSERT INTO memory_procedure_versions(route_id,interpretation_id,candidate_id,task_id,
                task_occurrence_id,contract_version,built_at_ms) VALUES(?,?,1,1,1,1,0)
            """, [.integer(Int64(id)), .integer(Int64(id))])
        try db.run("""
            INSERT INTO memory_procedure_parts(part_id,part_uuid,route_id,part_kind,first_position,last_position,
                app_id,label,declared_outcome) VALUES(?,?,?,'procedure',0,20000,?,'Save','completed')
            """, [.integer(Int64(id)), .text("part-\(id)"), .integer(Int64(id)), .integer(Int64(appID))])
        try db.run("INSERT INTO memory_part_qualifications(part_id,sequence,policy_id,verdict,evaluated_at_ms) VALUES(?,1,1,'admitted',0)",
            [.integer(Int64(id))])
    }

    @Test func trustFromProvenance() throws {
        let db = try database()
        defer { db.close() }
        for id in 1...3 { try version(id, db: db) }
        try db.execute("""
            INSERT INTO memory_procedure_provenance(route_id,third_party_content,exit_point,person_episode,learned_via,confirmed)
                VALUES(1,0,0,1,'person_demonstration',0),(2,0,0,0,'agent',1);
            """)
        let facts = try SQLiteProcedureRows.admissibility(of: ["route-1", "route-2", "route-3"], in: SQLiteSnapshot(connection: db))
        #expect(facts["route-1"]?.trust == .shownByPerson)
        #expect(facts["route-2"]?.trust == nil)
        #expect(facts["route-3"]?.trust == nil)
    }

    @Test func failedAttemptsOut() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try db.execute("""
            INSERT INTO memory_route_evidence(route_id,task_occurrence_id,relation,assessed_by,assessed_at_ms)
                VALUES(1,1,'supports','test',0);
            """)
        let before = try SQLiteProcedureRows.admissibility(of: ["route-1"], in: SQLiteSnapshot(connection: db))
        #expect(before["route-1"]?.fromFailedAttempt == false)
        try db.execute("""
            INSERT INTO memory_task_checkpoints(checkpoint_id,task_occurrence_id,sequence,checkpoint_kind,task_id,
                revision,recorded_at_ms,declared_status,task_revision_id) VALUES(1,1,1,'end',1,1,0,'failed',1);
            """)
        let after = try SQLiteProcedureRows.admissibility(of: ["route-1"], in: SQLiteSnapshot(connection: db))
        #expect(after["route-1"]?.fromFailedAttempt == true)
    }

    @Test func doNotUseSurvivesNewVersion() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try version(2, previous: 1, db: db)
        try version(3, previous: 2, db: db)
        let facts = try SQLiteProcedureRows.admissibility(of: ["route-1", "route-2", "route-3"], in: SQLiteSnapshot(connection: db))
        #expect(Set(facts.values.map(\.family)) == [.init(bundleID: "com.example.Editor", rootRouteUUID: "route-1")])
        let count = try SQLiteProcedureRows.admittedProcedureCount(bundleID: "com.example.Editor",
            doNotUse: [.init(bundleID: "com.example.Editor", rootRouteUUID: "route-1")], in: SQLiteSnapshot(connection: db))
        #expect(count == 0)
    }

    @Test func admittedCountByFamily() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try version(2, previous: 1, db: db)
        try version(3, previous: 2, db: db)
        try version(4, db: db)
        let snapshot = SQLiteSnapshot(connection: db)
        let blocked = Set([ProcedureFamilyID(bundleID: "com.example.Editor", rootRouteUUID: "route-4")])
        #expect(try SQLiteProcedureRows.admittedProcedureCount(bundleID: "com.example.Editor", doNotUse: blocked, in: snapshot) == 1)
        #expect(try SQLiteProcedureRows.admittedProcedureCount(bundleID: "com.other.App", in: snapshot) == 0)
        let query = SQLiteProcedureRows.admittedProcedureRoutesSQL(policyIDs: true)
        let plan = try snapshot.query("EXPLAIN QUERY PLAN " + query, [.text("com.example.Editor")]) { try $0.text(3) ?? "" }
        #expect(plan.contains { $0.contains("memory_procedure_parts_app_kind") }, "\(plan)")
    }
    @Test func admittedCountUsesAppIndexInLargeArchive() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try db.execute("INSERT INTO brain_apps(app_id,bundle_id) VALUES(2,'com.other.Editor')")
        try version(2, appID: 2, db: db)
        try db.execute("""
            WITH RECURSIVE numbers(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM numbers WHERE x<20000)
            INSERT INTO memory_procedure_parts(part_id,part_uuid,route_id,part_kind,parent_part_id,first_position,
                last_position,app_id,label,declared_outcome)
                SELECT x+100,'extra-'||x,2,'subprocedure',2,x,x,2,'Work','completed' FROM numbers;
            """)
        let snapshot = SQLiteSnapshot(connection: db)
        var durations: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            #expect(try SQLiteProcedureRows.admittedProcedureCount(bundleID: "com.example.Editor", in: snapshot) == 1)
            let elapsed = start.duration(to: .now)
            durations.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let p95 = durations.sorted()[28]
        print("RecallPlan admitted count: 20002 parts, 30 reads, p95=\(p95) ms")
        #expect(p95 <= 5)
    }

    @Test func calibrationKeepsMissingSignalsAndAllColumns() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try db.execute("""
            INSERT INTO memory_recall_queries(query_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,
                reason,remaining_work,channel,search_status,candidate_limit,candidates_considered,coverage,delivery,
                delivery_bytes,selector_version,recorded_at_ms)
                VALUES(1,1,1,1,'app','test','initial','Save','none','completed',48,0,'absent','nothing',0,'test',0);
            """)
        let row = SQLiteRecallRepository.CalibrationRow(needPosition: 0, partID: "part-1", rank: 2,
            cosine: nil, lexical: 0.7, score: 0.7, threshold: 0.6, delivered: true)
        try SQLiteRecallRepository.recordCalibration([row], queryID: "1", in: SQLiteTransaction(connection: db))
        let stored = try db.query("SELECT query_id,need_position,part_id,rank,cosine,lexical,score,threshold,delivered,used FROM memory_recall_calibration") {
            (try $0.text(0), $0.integer(1), try $0.text(2), $0.integer(3), $0.real(4), $0.real(5),
             $0.real(6), $0.real(7), $0.integer(8), $0.integer(9))
        }.first
        let value = try #require(stored)
        #expect(value.0 == "1" && value.1 == 0 && value.2 == "1" && value.3 == 2)
        #expect(value.4 == nil && value.5 == 0.7 && value.6 == 0.7 && value.7 == 0.6)
        #expect(value.8 == 1 && value.9 == nil)
    }

    @Test func deliveredButUnusedRecordedAndAdaptedCountsAsUse() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try version(2, db: db)
        try db.execute("""
            INSERT INTO memory_recall_queries(query_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,
                reason,remaining_work,channel,search_status,candidate_limit,candidates_considered,coverage,delivery,
                delivery_bytes,selector_version,recorded_at_ms)
                VALUES(1,1,1,1,'app','test','initial','Save','none','completed',48,0,'complete','delivered',0,'test',0),
                      (7,1,1,1,'app','test','initial','Save','none','completed',48,0,'complete','delivered',0,'test',0);
            INSERT INTO memory_recall_proposals(proposal_id,task_id,task_occurrence_id,task_revision,source,source_stream_id,
                reason,remaining_work,channel,search_status,candidates_considered,proposal_bytes,format_version,recorded_at_ms)
                VALUES(1,1,1,1,'app','test','initial','Save','none','completed',0,0,'test',0);
            INSERT INTO memory_recall_needs(need_id,query_id,position,text,coverage) VALUES(1,7,0,'Save','complete');
            INSERT INTO memory_recall_choices(query_id,proposal_id,recorded_at_ms) VALUES(7,1,0);
            INSERT INTO memory_recall_selections(selection_id,query_id,need_position,position,role,route_id,
                first_position,last_position,relevance,preparations,need_id)
                VALUES(1,7,0,0,'selected',1,0,20000,0.7,0,1);
            INSERT INTO memory_recall_reports(query_id,need_position,sequence,declared,recorded_at_ms,need_id)
                VALUES(7,0,1,'adapted',0,1);
            """)
        let rows = ["part-1", "part-2"].enumerated().map { index, part in
            SQLiteRecallRepository.CalibrationRow(needPosition: 0, partID: part, rank: index,
                cosine: nil, lexical: 0.7, score: 0.7, threshold: 0.6, delivered: true)
        }
        let transaction = SQLiteTransaction(connection: db)
        try SQLiteRecallRepository.recordCalibration(rows, queryID: "1", in: transaction)
        let uses = try SQLiteRecallRepository.calibrationUses(attemptID: "attempt", in: SQLiteSnapshot(connection: db))
        #expect(uses.first?.1 == ["part-1": true, "part-2": false])
        for (query, used) in uses { try SQLiteRecallRepository.markUsed(queryID: query, used: used, in: transaction) }
        try SQLiteRecallRepository.markUsed(queryID: "1", used: ["part-1": false, "part-2": true], in: transaction)
        let kept = try db.query("SELECT used FROM memory_recall_calibration ORDER BY part_id") { $0.integer(0) }
        #expect(kept == [1, 0])
    }

    @Test func proposalCalibrationUsesPersistedIdentityWithoutAChoice() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        let proposal = RecallChoice.Proposal(proposalID: "unpersisted-proposal", taskID: "task", attemptID: "attempt",
            revision: 1, producer: try TaskProducer(source: .app, streamID: "test"), reason: .initial,
            remainingWork: "Save", needs: [try RecallNeed(text: "Save")], shortlisted: [
                .init(needPosition: 0, key: "s1", routeID: "route-1", relevance: 0.8, suggested: nil)
            ], recordedAtMS: 0)
        let recorded = SQLiteRecallRepository.RecordedProposal(proposal: proposal, generationID: nil,
            channel: .none, searchStatus: .completed, searchNote: nil, candidatesConsidered: 1, bytes: 100,
            durationUS: nil, calibration: [.init(needPosition: 0, partID: "part-1", rank: 0,
                cosine: nil, lexical: 0.8, score: 0.8, threshold: 0.6, delivered: true)])
        let storedID = try SQLiteRecallRepository.recordProposal(recorded, in: SQLiteTransaction(connection: db))
        #expect(storedID != proposal.proposalID)
        let parent = try db.query("SELECT p.proposal_id FROM memory_recall_proposals p JOIN memory_recall_queries q ON q.query_id = p.proposal_id JOIN memory_recall_calibration c ON c.query_id = q.query_id") { try $0.text(0) }
        #expect(parent == [storedID])
        #expect(try db.query("SELECT count(*) FROM memory_recall_choices") { $0.integer(0) }.first == 0)
        let uses = try SQLiteRecallRepository.calibrationUses(attemptID: "attempt", in: SQLiteSnapshot(connection: db))
        #expect(uses.first?.1 == ["part-1": false])
        let empty = SQLiteRecallRepository.RecordedProposal(proposal: proposal, generationID: nil,
            channel: .none, searchStatus: .completed, searchNote: nil, candidatesConsidered: 1,
            bytes: 0, durationUS: nil)
        let emptyID = try SQLiteRecallRepository.recordProposal(empty, in: SQLiteTransaction(connection: db))
        #expect(emptyID != storedID && emptyID != proposal.proposalID)
        #expect(try db.query("PRAGMA foreign_key_check") { try $0.text(0) }.isEmpty)
    }

    @Test func channelsUseTheRecordedAdapterVerb() throws {
        let db = try database()
        defer { db.close() }
        try version(1, db: db)
        try db.execute("""
            INSERT INTO memory_route_steps(step_id,route_id,position,step_kind,goal_text) VALUES(1,1,0,'goal','Export');
            INSERT INTO memory_step_operations(operation_id,route_id,step_id,position,tool_kind) VALUES(1,1,1,0,'app_call');
            INSERT INTO memory_operation_arguments(operation_id,route_id,argument_name,value_kind,text_value)
                VALUES(1,1,'verb','text','export');
            """)
        let facts = try SQLiteProcedureRows.admissibility(of: ["route-1"], in: SQLiteSnapshot(connection: db))
        #expect(facts["route-1"]?.channels == ["app_call:export"])
    }

}
