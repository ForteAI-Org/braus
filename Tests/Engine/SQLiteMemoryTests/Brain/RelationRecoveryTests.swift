//
//  RelationRecoveryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// What a call teaches is evaluated again when the evidence it lacked arrives or the policy changes, and
/// recovered when it was never evaluated, without counting a call twice or deleting anything (review
/// F03): a history of evaluations, the evidence of each call's latest one counted, the first policy's
/// register kept as it was, and a contract built while a state was pending told what is known since.
@Suite("Relations evaluated again, recovered, and counted once")
struct RelationRecoveryTests {

    static let editing = SceneFixtures.perceive(SceneFixtures.window("Document", [SceneFixtures.button("Export", y: 120)]))
    static let dialog  = SceneFixtures.perceive(SceneFixtures.dialog("Export", [SceneFixtures.button("Save", y: 120)]))

    /// A click on Export opened and concluded with its samples and its check, attributed to the task's
    /// attempt; its samples placed in their states when `associate`.
    @discardableResult
    static func click(_ memory: TaskFixtures.Memory, _ id: String, verdict: OperationCheck.Verdict = .passed, associate: Bool,
                      at ms: Int64 = TaskFixtures.t0 + 10) async throws -> [CaptureSample] {
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        _ = try await memory.facts.open(try OperationOpening(call: try OperationFactRepositoryTests.click(id), startedAtMS: ms,
                                                             attribution: attribution))
        let samples = [SceneFixtures.sample(id, phase: .before, of: editing), SceneFixtures.sample(id, phase: .after, of: dialog)]
        let template = try OperationFactRepositoryTests.conclusion(id, verdict: verdict)
        _ = try await memory.facts.conclude(try OperationConclusion(end: template.end, samples: samples, effect: template.effect,
                                                                  verifications: template.verifications))
        if associate { try await place(memory, samples) }
        return samples
    }

    static func place(_ memory: TaskFixtures.Memory, _ samples: [CaptureSample]) async throws {
        let scenes = SQLiteSceneRepository(store: memory.store)
        for sample in samples { _ = try await scenes.associate(sample.key, at: TaskFixtures.t0 + 50) }
    }

    static func associateNothing(_ key: CaptureSampleKey) async throws {}

    @Test("a call waiting for its state is evaluated again once placed; ten more evaluations and recoveries add no proof and no evaluation")
    func evaluatedAgainCountedOnce() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let samples = try await Self.click(memory, "late", associate: false)
        let relations = SQLiteBrainRelationRepository(store: memory.store)
        let first = try await relations.apply(callEventID: "late", at: TaskFixtures.t0 + 40)
        #expect(first.exclusion == .awaitingState && first.isRecoverable)
        try await Self.place(memory, samples)
        for attempt in 0..<10 {
            _ = try await relations.apply(callEventID: "late", at: TaskFixtures.t0 + 60 + Int64(attempt))
            _ = try await relations.catchUp(at: TaskFixtures.t0 + 80 + Int64(attempt), associate: Self.associateNothing)
        }
        let history = try await relations.evaluations(of: "late")
        #expect(history.map(\.cause) == [.acquisition, .evidence] && history.last?.outcome == .supported, "\(history)")
        let learned = try await relations.relations(of: AgentCallFixtures.app.bundleID)
        #expect(learned.count == 1 && learned.first?.supports == 1, "one call, one proof, however often it is evaluated")
        #expect(try await memory.count("SELECT count(*) FROM brain_relation_evidence") == 1)
        await memory.store.close()
    }

    @Test("a failure that came before the relation it contradicts contradicts it once the relation appears")
    func lateContradiction() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        try await Self.click(memory, "failed", verdict: .failed, associate: true)
        let relations = SQLiteBrainRelationRepository(store: memory.store)
        let waiting = try await relations.apply(callEventID: "failed", at: TaskFixtures.t0 + 40)
        #expect(waiting.exclusion == .nothingToContradict && waiting.isRecoverable)
        try await Self.click(memory, "passed", associate: true, at: TaskFixtures.t0 + 20)
        #expect(try await relations.apply(callEventID: "passed", at: TaskFixtures.t0 + 60).outcome == .supported)
        let relation = try #require(try await relations.relations(of: AgentCallFixtures.app.bundleID).first)
        #expect(relation.supports == 1 && relation.contradictions == 1 && relation.standing == .limited)
        #expect(try await relations.evaluations(of: "failed").map(\.outcome) == [.excluded, .contradicted])
        await memory.store.close()
    }

    @Test("the recovery evaluates a call never evaluated, and again under this policy one the first policy applied or an older evaluation decided; the first policy's register stays as written")
    func recoveryAndPolicy() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        for id in ["lost", "first-policy", "older"] { try await Self.click(memory, id, associate: true) }
        _ = try await memory.store.write { transaction in
            try transaction.execute(
                """
                INSERT INTO brain_relation_applications (call_event_id, app_id, policy_version, outcome, reason, applied_at_ms)
                VALUES ('first-policy', NULL, 'brain-relations-1', 'excluded', 'no_before_state', 1)
                """
            )
            try transaction.execute(
                """
                INSERT INTO brain_relation_evaluations (call_event_id, sequence, app_id, policy_version, cause, outcome, reason,
                    recoverable, group_key, expected_effect_kind, evaluated_at_ms)
                VALUES ('older', 1, NULL, 'brain-relations-1', 'acquisition', 'excluded', 'no_before_state', 0, NULL, NULL, 1)
                """
            )
        }
        let relations = SQLiteBrainRelationRepository(store: memory.store)
        let pass = try await relations.catchUp(at: TaskFixtures.t0 + 90, associate: Self.associateNothing)
        #expect(pass.recovered == 1 && pass.reevaluated == 2 && !pass.remaining, "\(pass)")
        #expect(try await relations.evaluations(of: "lost").map(\.cause) == [.recovery])
        #expect(try await relations.evaluations(of: "first-policy").map(\.cause) == [.policy])
        #expect(try await relations.evaluations(of: "older").map(\.cause) == [.acquisition, .policy])
        #expect(try await relations.evaluations(of: "older").last?.policyVersion == BrainRelationPolicy.version)
        #expect(try await relations.relations(of: AgentCallFixtures.app.bundleID).first?.supports == 3)
        #expect(try await memory.count("SELECT count(*) FROM brain_relation_applications") == 1, "the first policy's register is kept")
        let again = try await relations.catchUp(at: TaskFixtures.t0 + 91, associate: Self.associateNothing)
        #expect(again.total == 0 && !again.remaining)
        await memory.store.close()
    }

    @Test("a version built while its step's sample waited for its state keeps its contract as built and says the state known since")
    func lateEntryState() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let samples = try await Self.click(memory, "c1", associate: false)
        _ = try await memory.tasks.checkpoint(try TaskCheckpointDraft(kind: .end, declared: .completed), attempt: "attempt-1",
                                              at: TaskFixtures.t0 + 90, by: TaskFixtures.producer)
        let procedures = SQLiteProcedureRepository(store: memory.store)
        let (_, candidate) = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer,
                                                                              at: TaskFixtures.t0 + 100))
        let outcome = try await procedures.interpret(try ProcedureInterpretation(candidateID: candidate.candidateID, parts: [
            try PartStatement(reference: .procedure, label: "Open the export dialog", outcome: .completed),
            try PartStatement(reference: .step(0), label: "Click Export", outcome: nil),
        ]), by: TaskFixtures.producer, at: TaskFixtures.t0 + 110)
        let before = try #require(try await procedures.version(outcome.routeID))
        #expect(before.contract.filter { $0.kind == .entryState }.allSatisfy { $0.sceneID == nil } && before.lateEntryStates.isEmpty)
        try await Self.place(memory, samples)
        let after = try #require(try await procedures.version(outcome.routeID))
        let state = try #require(try await SQLiteBrainRelationRepository(store: memory.store).state(of: samples[0].key))
        #expect(after.contract == before.contract, "the contract stays as it was built")
        #expect(Set(after.lateEntryStates.values) == [state] && after.lateEntryStates.count == 2,
                "the procedure and its step say the state their first step started from: \(after.lateEntryStates)")
        await memory.store.close()
        guard case .found(let inspection) = SQLiteMemoryInspection.task("task-1", in: memory.url) else {
            Issue.record("the task was not read")
            return
        }
        let entries = inspection.text.filter { $0.contains("contract entry_state") }
        #expect(entries.count == 2 && entries.allSatisfy { $0.hasSuffix("state unknown when built; known since: state \(state.prefix(8))") },
                "the diagnosis says the state known since beside the contract as built: \(entries)")
    }
}
