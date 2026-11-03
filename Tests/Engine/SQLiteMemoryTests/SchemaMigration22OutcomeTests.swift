import EngineCore
import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 outcome rows")
struct SchemaMigration22OutcomeTests {
    @Test(arguments: ActOutcomeKind.allCases, [0, 1, 2, 3])
    func outcomeConversionTable(kind: ActOutcomeKind, evidence: Int) throws {
        let hasEffect = evidence & 1 != 0
        let check: OperationCheck? = evidence & 2 != 0 ? failedCheck : nil
        let converted = SQLiteMigration22Outcomes.columns(
            kind: kind, tool: .act, verb: "click", hasEffect: hasEffect, check: check,
            notSent: nil, sceneAttached: false
        )
        let complete = hasEffect && check != nil
        let expected = Outcome.converting(kind, check: complete ? check : nil, notSent: nil, noop: nil, sceneAttached: false)
        #expect(converted.outcome == expected)
        #expect(converted.origin == (complete ? "converted" : "converted_partial"))
        #expect(converted.learnable == (complete && expected.effect == .confirmed))
        #expect(converted.bindings.count == 7)
        try assertAdmitted(converted)
    }

    @Test(arguments: [AgentTool.act, .menu, .press, .batch, .scroll, .contextMenu, .drag])
    func noopsRequireSavedRequest(tool: AgentTool) throws {
        for verb in ["click", "set_toggle"] {
            let converted = SQLiteMigration22Outcomes.columns(
                kind: .actedNoop, tool: tool, verb: verb, hasEffect: true, check: failedCheck,
                notSent: nil, sceneAttached: false
            )
            #expect(converted.outcome.effect == (tool == .act && verb == "set_toggle" ? .confirmed : .notApplicable))
            #expect(converted.learnable == (tool == .act && verb == "set_toggle"))
            try assertAdmitted(converted)
        }
    }

    @Test(arguments: NotSentCause.allCases)
    func newRefusalCausesAreNeverInvented(cause: NotSentCause) throws {
        let converted = SQLiteMigration22Outcomes.columns(
            kind: .refused, tool: .act, verb: "click", hasEffect: true, check: failedCheck,
            notSent: cause, sceneAttached: false
        )
        let historical: NotSentCause? = [.needsConsent, .destructiveUnverifiable, .disabled].contains(cause) ? nil : cause
        #expect(converted.outcome == Outcome.converting(.refused, check: failedCheck, notSent: historical,
                                                       noop: nil, sceneAttached: false))
        try assertAdmitted(converted)
    }

    @Test
    func attachedSceneChangesObserveRecovery() throws {
        let check = OperationCheck.unchecked(performed: .uncertain)
        let converted = SQLiteMigration22Outcomes.columns(
            kind: .actedUnverified, tool: .act, verb: nil, hasEffect: true, check: check,
            notSent: nil, sceneAttached: true
        )
        #expect(converted.outcome == Outcome(gesture: .uncertain, effect: .unknown(.notReadable), recovery: .doNotRepeat))
        try assertAdmitted(converted)
    }

    @Test
    func convertsOnlyGestureRowsAndKeepsAllActionRows() throws {
        let source = try source()
        defer { source.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Outcomes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let target = directory.appendingPathComponent("memory.sqlite.migrating-22-test")
        try SQLiteMigration22File.create(at: target) { db throws in
            try db.execute("""
                INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
                VALUES (41,'gesture','cli','synthetic','action',0,'not_applicable'),
                       (81,'adapter','cli','synthetic','action',0,'not_applicable');
                INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,result_kind)
                VALUES (41,'act','completed','acted_unverified'),(81,'app_call','completed','found_acted');
                """)
            let report = try SQLiteMigration22Outcomes.convert(from: source, into: db)
            #expect(report.converted == 1)
            #expect(report.partiallyConverted == 0)
            #expect(try db.query("SELECT count(*) FROM memory_agent_actions") { $0.integer(0) } == [2])
        } verify: { db throws in
            #expect(try db.query("""
                SELECT gesture,effect,effect_reason,recovery,recovery_reason,outcome_origin,learnable,result_kind
                FROM memory_agent_actions WHERE event_id=41
                """) { row in
                    (0..<8).map { index in row.isNull(index) ? "NULL" : "present" }
                } == [["present","present","NULL","present","NULL","present","present","NULL"]])
            #expect(try db.query("SELECT effect,recovery,outcome_origin,learnable FROM memory_agent_actions WHERE event_id=41") {
                (try $0.text(0), try $0.text(1), try $0.text(2), $0.integer(3))
            }.first.map { $0 == ("absent","retry","converted",0) } == true)
            #expect(try db.query("SELECT result_kind,gesture,outcome_origin FROM memory_agent_actions WHERE event_id=81") {
                [try $0.text(0), try $0.text(1), try $0.text(2)]
            } == [["found_acted",nil,nil]])
        }
    }

    @Test
    func missingDestinationActionRefusesInsteadOfLosingARow() throws {
        let source = try source()
        defer { source.close() }
        let target = try tables22()
        defer { target.close() }
        #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["outcome destination for gesture"])) {
            _ = try SQLiteMigration22Outcomes.convert(from: source, into: target)
        }
    }

    @Test func migrationPreservesDryRunIdentity() throws {
        let source = try source()
        let target = try tables22()
        defer { source.close(); target.close() }
        try source.run("UPDATE memory_agent_actions SET result_kind='dry_run' WHERE event_id='gesture'")
        try target.execute("""
            INSERT INTO memory_events(event_id,event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (41,'gesture','cli','synthetic','action',0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,result_kind)
            VALUES (41,'act','completed','dry_run');
            """)
        _ = try SQLiteMigration22Outcomes.convert(from: source, into: target)
        #expect(try target.query("SELECT result_kind FROM memory_agent_actions WHERE event_id=41") { try $0.text(0) } == ["dry_run"])
    }

    @Test func migratedDryRunReadsAsTheOriginalProgress() async throws {
        let memory = try await TaskFixtures.open(schema: .historical19)
        _ = try await memory.calls.record(AgentCallFixtures.call("dry", .act(target: "Save", verb: .click, value: nil, section: nil)))
        _ = try await memory.calls.advance([AgentCallTransition("dry", .started(atMS: AgentCallFixtures.t0))])
        let progress = AgentCallProgress(.completed, result: .outcome(.dryRun, message: "preview"), endedAtMS: AgentCallFixtures.t0 + 1)
        _ = try await memory.calls.advance([AgentCallTransition("dry", progress)])
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".migrating-22-dry")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
            availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        #expect(try await SQLiteAgentCallRepository(store: store).call("dry")?.progress.isExactly(progress) == true)
        await store.close()
    }

    private var failedCheck: OperationCheck {
        OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .failed,
                       observed: "unchanged", performed: .requested)
    }

    private func assertAdmitted(_ columns: SQLiteMigration22Outcomes.Columns) throws {
        let db = try tables22()
        defer { db.close() }
        try db.execute("""
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status) VALUES (1,'act','completed')
            """)
        try db.run("""
            UPDATE memory_agent_actions SET gesture=?,effect=?,effect_reason=?,recovery=?,recovery_reason=?,
                outcome_origin=?,learnable=? WHERE event_id=1
            """, columns.bindings)
    }

    private func tables22() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        let ddl = try SQLiteMigration22File.text()
        let tables = try #require(ddl.components(separatedBy: "-- section: tables\n").last)
            .components(separatedBy: "-- section: indexes\n")[0]
        try db.execute(tables)
        return db
    }

    private func source() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        for table in try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text()) where table.type == "table" {
            try db.execute(try #require(table.sql))
        }
        try db.execute("""
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (41,'gesture','cli','synthetic','action',0,'not_applicable'),
                   (81,'adapter','cli','synthetic','action',0,'not_applicable'),
                   (82,'verification','cli','synthetic','verification',0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,result_kind)
            VALUES ('gesture','act','completed','acted_unverified'),('adapter','app_call','completed','found_acted');
            INSERT INTO memory_call_effects(event_id,performed,checked) VALUES ('gesture','requested',1);
            INSERT INTO memory_verifications(event_id,scope,method,verdict,observed_text)
            VALUES ('verification','call','scene_difference','failed','unchanged');
            INSERT INTO memory_operation_verifications(event_id,call_event_id,contract_version,condition_kind,method_version,performed)
            VALUES ('verification','gesture',1,'structural_effect','synthetic','requested');
            """)
        return db
    }
}
