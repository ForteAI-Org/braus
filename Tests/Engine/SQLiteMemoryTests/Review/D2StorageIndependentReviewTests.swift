import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

@Suite("D2 independent review: recovery and variant provenance")
struct D2StorageIndependentReviewTests {
    @Test("an excluded call can be reconsidered when its saved samples acquire their states")
    func lateStateAssociationDoesNotLoseEvidenceForever() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let opening = try OperationOpening(call: try OperationFactRepositoryTests.click("late"),
                                           startedAtMS: TaskFixtures.t0 + 1,
                                           attribution: try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1))
        _ = try await memory.facts.open(opening)
        let before = SceneFixtures.perceive(SceneFixtures.window("Document", [SceneFixtures.button("Export", y: 120)]))
        let after = SceneFixtures.perceive(SceneFixtures.dialog("Export", [SceneFixtures.button("Save", y: 120)]))
        let samples = [SceneFixtures.sample("late", phase: .before, of: before),
                       SceneFixtures.sample("late", phase: .after, of: after)]
        let template = try OperationFactRepositoryTests.conclusion("late")
        _ = try await memory.facts.conclude(try OperationConclusion(end: template.end, samples: samples,
                                                                  effect: template.effect, verifications: template.verifications))
        let relations = SQLiteBrainRelationRepository(store: memory.store)
        let first = try await relations.apply(callEventID: "late", at: TaskFixtures.t0 + 40)
        // Adapted after the review: a complete sample not yet placed in a state is now told apart from one
        // that can never be (`no_before_state`): its exclusion is `awaiting_state`, recoverable. The
        // invariant is the review's: excluded first, for want of the state, and reconsidered once placed.
        #expect(first.exclusion == .awaitingState && first.isRecoverable)
        let scenes = SQLiteSceneRepository(store: memory.store)
        for sample in samples {
            let associated = try await scenes.associate(sample.key, at: TaskFixtures.t0 + 50)
            #expect(associated.associations.contains { $0.status == .confirmed })
        }
        let reconsidered = try await relations.apply(callEventID: "late", at: TaskFixtures.t0 + 60)
        #expect(reconsidered.outcome == .supported,
                "facts are complete now, but the earlier transient exclusion is permanent: \(reconsidered)")
        await memory.store.close()
    }

    @Test("a declared common prefix must not link a click and a double click as the same operation")
    func variantRejectsContradictedCommonPrefix() async throws {
        let memory = try await ProcedureRepositoryTests.populated()
        let (procedures, original) = try await ProcedureRepositoryTests.interpreted(memory)
        _ = try await TaskFixtures.begin(memory, "task-2", attempt: "attempt-2")
        let different = try AgentCallRecord(event: OperationFactRepositoryTests.event("different"),
                                            request: .act(target: "Export", verb: .doubleClick, value: nil, section: nil))
        _ = try await memory.facts.open(try OperationOpening(call: different, startedAtMS: TaskFixtures.t0 + 1,
            attribution: try TaskCallAttribution(taskID: "task-2", attemptID: "attempt-2", revision: 1)))
        _ = try await memory.facts.conclude(try OperationFactRepositoryTests.conclusion("different"))
        _ = try await memory.tasks.checkpoint(try TaskCheckpointDraft(kind: .end, declared: .completed), attempt: "attempt-2",
                                              at: TaskFixtures.t0 + 90, by: TaskFixtures.producer)
        let (_, candidate) = try #require(try await procedures.buildCandidate(attemptID: "attempt-2", for: TaskFixtures.producer,
                                                                              at: TaskFixtures.t0 + 100))
        let falsePrefix = try ProcedureInterpretation(candidateID: candidate.candidateID, parts: [
            try PartStatement(reference: .procedure, label: "Open the export menu", outcome: .completed),
            try PartStatement(reference: .step(0), label: "Double click Export", outcome: .completed)
        ], variantOf: original, divergencePosition: 1)
        await #expect(throws: (any Error).self) {
            _ = try await procedures.interpret(falsePrefix, by: TaskFixtures.producer, at: TaskFixtures.t0 + 110)
        }
        await memory.store.close()
    }
}
