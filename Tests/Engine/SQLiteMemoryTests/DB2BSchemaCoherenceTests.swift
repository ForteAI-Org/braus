import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema 22 task write coherence")
struct DB2BSchemaCoherenceTests {
    @Test(
        "the schema refuses what the contract refuses, even written by hand: a revision out of order, a second end, a reopened task"
    )
    func schemaGuards() async throws {
        let memory = try await TaskFixtures.open22()
        try await TaskFixtures.begin(memory)
        #expect(
            await coherenceRefusal(
                of: """
                    INSERT INTO memory_task_revisions (task_id, revision, recorded_at_ms, change_kind, goal)
                    VALUES ((SELECT task_id FROM memory_tasks WHERE task_uuid='task-1'), 3, 0, 'revised', 'g')
                    """,
                in: memory.store
            ) != nil
        )
        _ = try await memory.tasks.checkpoint(
            try TaskCheckpointDraft(kind: .end, declared: .completed),
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 1,
            by: TaskFixtures.producer
        )
        #expect(
            await coherenceRefusal(
                of: """
                    INSERT INTO memory_task_checkpoints (task_occurrence_id, sequence, checkpoint_kind, task_id, revision,
                                                         recorded_at_ms, declared_status, task_revision_id)
                    VALUES ((SELECT task_occurrence_id FROM memory_task_occurrences WHERE task_occurrence_uuid='attempt-1'), 2, 'end', (SELECT task_id FROM memory_tasks WHERE task_uuid='task-1'), 1, 0, 'failed', (SELECT task_revision_id FROM memory_task_revisions WHERE revision=1))
                    """,
                in: memory.store
            ) != nil
        )
        #expect(
            await coherenceRefusal(
                of: """
                    UPDATE memory_tasks SET status = 'open', closed_at_ms = NULL WHERE task_id = (SELECT task_id FROM memory_tasks WHERE task_uuid='task-1')
                    """,
                in: memory.store
            ) != nil
        )
        #expect(
            await coherenceRefusal(
                of: """
                    UPDATE memory_task_revisions SET goal = 'other' WHERE task_id = (SELECT task_id FROM memory_tasks WHERE task_uuid='task-1')
                    """,
                in: memory.store
            ) != nil
        )
        await memory.store.close()
    }
    private func coherenceRefusal(of sql: String, in store: SQLiteMemoryStore) async -> (any Error)? {
        do {
            try await store.write { transaction in
                try DB2BWriteChecks.perform(transaction) { try transaction.execute(sql) }
            }
            return nil
        } catch { return error }
    }
}

extension DB2BSchemaCoherenceTests {
    @Test
    func verificationMembershipMustAgreeWithAttribution() async throws {
        let memory = try await AttributionFixtures.open22()
        for id in ["v-passed", "v-unknown"] {
            _ = try await memory.verifications.record(
                VerificationRecord(
                    event: AttributionFixtures.verificationEvent(id),
                    scope: .call,
                    method: .sceneText,
                    verdict: id == "v-passed" ? .passed : .unknown
                )
            )
        }
        let steps = SQLiteStepOccurrenceRepository(store: memory.store)
        let step1 = try await steps.insert(
            StepOccurrenceRecord(stepOccurrenceID: "so-1", startedAtMS: 0, status: .observed)
        ).occurrence.stepOccurrenceID
        let step2 = try await steps.insert(
            StepOccurrenceRecord(stepOccurrenceID: "so-2", startedAtMS: 0, status: .observed)
        ).occurrence.stepOccurrenceID
        _ = try await memory.verifications.attribute(verification: "v-passed", toStepOccurrence: step1)
        try await memory.plant([
            (
                "INSERT INTO memory_step_events(step_occurrence_id,event_id,position,role) VALUES (?,(SELECT event_id FROM memory_events WHERE event_uuid='v-passed'),0,'verification')",
                [.text(step1)]
            )
        ])
        for (step, event) in [(step2, "v-passed"), (step1, "v-unknown")] {
            let incoherent = await storeError {
                try await memory.store.write { transaction in
                    try DB2BWriteChecks.perform(transaction) {
                        try transaction.execute(
                            "INSERT INTO memory_step_events (step_occurrence_id, event_id, position, role) VALUES (?, (SELECT event_id FROM memory_events WHERE event_uuid=?), 1, 'verification')",
                            [.text(step), .text(event)]
                        )
                    }
                }
            }
            guard case .contract? = incoherent else {
                Issue.record(
                    "the schema refuses a membership its verification's attribution contradicts, got \(String(describing: incoherent))"
                )
                continue
            }
        }
        #expect(try await memory.verifications.verification("v-unknown")?.stepOccurrenceID == nil)
        await memory.store.close()
    }
}

extension DB2BSchemaCoherenceTests {
    @Test
    func routeRequiresTheCallToHaveEnded() async throws {
        let memory = try await TaskFixtures.open22()
        _ = try await memory.facts.open(OperationOpening(call: OperationFactRepositoryTests.click("c11"), startedAtMS: TaskFixtures.t0 + 3))
        await #expect(throws: (any Error).self) {
            try await memory.store.db2BWrite { transaction in
                try transaction.execute("INSERT INTO memory_call_routes(event_id,route) VALUES ((SELECT event_id FROM memory_events WHERE event_uuid='c11'),'native')")
            }
        }
        #expect(try await memory.facts.route(of: "c11") == nil, "a started call has no route")
        await memory.store.close()
    }

    @Test
    func rungRequiresTheCallToHaveEnded() async throws {
        let memory = try await TaskFixtures.open22()
        _ = try await memory.facts.open(OperationOpening(call: OperationFactRepositoryTests.click("r11"), startedAtMS: TaskFixtures.t0 + 3))
        await #expect(throws: (any Error).self) {
            try await memory.store.db2BWrite { transaction in
                try transaction.execute("INSERT INTO memory_call_rungs(event_id,rung,how) VALUES ((SELECT event_id FROM memory_events WHERE event_uuid='r11'),'accessibility','pressed')")
            }
        }
        #expect(try await memory.facts.rung(of: "r11") == nil, "a started call has no rung")
        await memory.store.close()
    }
}
