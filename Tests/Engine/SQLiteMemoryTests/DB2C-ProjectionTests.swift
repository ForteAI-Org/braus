import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Frozen projection writers on schema 22", .serialized)
struct DB2CProjectionTests {
    @Test func applicationsAreFrozenWhileRelationRecoveryRemainsAvailable() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let command = try BrainApplicationCommand.setName("Send", anchorKey: "old-anchor", in: "com.example.Editor",
                                                         eventID: "event", requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let applications = SQLiteBrainApplicationRepository(store: store)
        let applied = try await applications.apply(command)
        if case .frozen = applied.projectionWrite {} else { Issue.record("expected frozen application") }
        let relations = SQLiteBrainRelationRepository(store: store)
        await #expect(throws: AgentCallError.self) {
            _ = try await relations.apply(callEventID: "event", at: 1_700_000_000_000)
        }
        let caught = try await relations.catchUp(at: 1_700_000_000_000) { _ in Issue.record("frozen recovery associated a sample") }
        #expect(caught.total == 0)
        #expect(caught.remaining == false)
        #expect(try await relations.applyPending(at: 1_700_000_000_000) == 0)
        let rows = try await store.read { snapshot in
            try snapshot.query("SELECT (SELECT count(*) FROM brain_applications), (SELECT count(*) FROM brain_relation_applications), (SELECT count(*) FROM brain_anchors)") {
                [$0.integer(0), $0.integer(1), $0.integer(2)]
            }.first
        }
        #expect(rows == [0, 0, 0])
        await store.close()
    }
    @Test func historicalApplicationKeepsItsEventIdentityAndInput() async throws {
        let memory = try await BrainApplicationFixtures.open()
        try await memory.event("event", kind: .observation)
        let sample = try await memory.sample("event")
        let command = try BrainApplicationFixtures.observe(sample, BrainApplicationFixtures.controls(["Save"]))
        let result = try await memory.applications.apply(command)
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".migrating-22-c")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let saved = try #require(try await SQLiteBrainApplicationRepository(store: store).application(command.key))
        #expect(saved.command.hasSameInput(as: command))
        #expect(saved.outcome == result.outcome)
        await store.close()
    }

    @Test func historicalRelationsKeepTheirPublicKeysAndProofs() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        _ = try await RelationRecoveryTests.click(memory, "call", associate: true)
        let old = SQLiteBrainRelationRepository(store: memory.store)
        _ = try await old.apply(callEventID: "call", at: TaskFixtures.t0 + 60)
        let previous = try await old.relations(of: AgentCallFixtures.app.bundleID)
        #expect(previous.count == 1)
        let history = try await old.evaluations(of: "call")
        _ = try await RelationRecoveryTests.click(memory, "live", associate: true, at: TaskFixtures.t0 + 100)
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".migrating-22-c")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let relations = SQLiteBrainRelationRepository(store: store)
        #expect(try await relations.relations(of: AgentCallFixtures.app.bundleID) == previous)
        #expect(try await relations.evaluations(of: "call") == history)
        let relation = try #require(previous.first)
        #expect(try await relations.proofs(of: relation.relationID).first?.callEventID == "call")
        let applied = try await relations.apply(callEventID: "live", at: TaskFixtures.t0 + 160)
        #expect(applied.outcome == .supported)
        #expect(applied.relationIDs == previous.map(\.relationID))
        #expect(try await relations.relations(of: AgentCallFixtures.app.bundleID).first?.supports == 2)
        #expect(try await relations.proofs(of: relation.relationID).count == 2)
        _ = try await store.write { try relations.apply(callEventID: "live", at: TaskFixtures.t0 + 170, in: $0) }
        #expect(try await relations.relations(of: AgentCallFixtures.app.bundleID).first?.supports == 2)

        await store.close()
    }

    @Test func partialOutcomesCannotTeachLiveRelations() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        try await store.write { transaction in
            try transaction.execute("INSERT INTO memory_events(event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status) VALUES ('partial','app','stream','action',1,'not_applicable')")
            try transaction.execute("""
                INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status,started_at_ms,completed_at_ms,gesture,effect,effect_reason,
                    recovery,outcome_origin,learnable) VALUES (1,'act','completed',1,2,'sent','unknown','not_classified','observe','converted_partial',0)
                """)
            try transaction.execute("INSERT INTO memory_operation_arguments(event_id,argument_name,position,value_kind,text_value) VALUES (1,'target',0,'text','Save')")
            try transaction.execute("INSERT INTO memory_operation_arguments(event_id,argument_name,position,value_kind,text_value) VALUES (1,'verb',0,'text','click')")
        }
        let result = try await SQLiteBrainRelationRepository(store: store).apply(callEventID: "partial", at: TaskFixtures.t0)
        #expect(result.exclusion == .notLearnable)
        #expect(try await store.read { try $0.query("SELECT count(*) FROM brain_relations") { $0.integer(0) }.first ?? nil } == 0)
        await store.close()
    }

}
