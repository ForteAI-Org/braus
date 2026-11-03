import EngineCore
import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema 22 Job B repositories")
struct DB2BRepositoryTests {
    private func open() async throws -> SQLiteMemoryStore {
        let store = SQLiteMemoryStore(url: try temporaryDatabase("repositories22"), schema: .version22)
        try await store.open()
        return store
    }

    @Test
    func eventsAndCallsKeepPublicIdentities() async throws {
        let store = try await open()
        let calls = SQLiteAgentCallRepository(store: store)
        let call = try AgentCallFixtures.call("call", .act(target: "Save", verb: .click, value: nil, section: nil))
        #expect(try await calls.record(call) == .committed)
        #expect(try await calls.record(call) == .alreadyApplied)
        #expect(try await calls.call("call")?.event.hasSameImmutableContent(as: call.event) == true)
        #expect(try await calls.calls(inTrace: "trace-1", after: nil, limit: 10).map(\.event.eventID) == ["call"])
        #expect(
            try await SQLiteTraceRepository(store: store).entries(inTrace: "trace-1", after: nil, limit: 10).map(
                \.event.eventID
            ) == ["call"]
        )
        await store.close()
    }

    @Test
    func taskOccurrencesAndLabelsKeepPublicIdentities() async throws {
        let store = try await open()
        let tasks = SQLiteTaskRepository(store: store)
        let occurrence = try TaskOccurrenceRecord(taskOccurrenceID: "attempt", startedAtMS: 1, status: .observed)
        #expect(try await tasks.record(occurrence) == .committed)
        #expect(try await tasks.record(occurrence) == .alreadyApplied)
        #expect(try await tasks.occurrence("attempt")?.isExactly(occurrence) == true)
        let label = try TaskLabelRecord(
            labelID: "label",
            taskOccurrenceID: "attempt",
            label: "Save",
            assignedBy: "fixture",
            status: .candidate,
            assignedAtMS: 1
        )
        let inserted = try await tasks.insert(label)
        #expect(inserted.receipt == .committed)
        #expect(try await tasks.labels(of: "attempt").first?.isExactly(inserted.label) == true)
        #expect(Int64(inserted.label.labelID) != nil)
        let second = try await tasks.insert(label)
        #expect(second.label.labelID != inserted.label.labelID)
        #expect(try await tasks.labels(of: "attempt").count == 2)
        await store.close()
    }

    @Test
    func stepOccurrenceKeepsPublicIdentity() async throws {
        let store = try await open()
        let steps = SQLiteStepOccurrenceRepository(store: store)
        let occurrence = try StepOccurrenceRecord(stepOccurrenceID: "step", startedAtMS: 1, status: .observed)
        let inserted = try await steps.insert(occurrence)
        #expect(inserted.receipt == .committed)
        #expect(try await steps.record(inserted.occurrence) == .alreadyApplied)
        #expect(
            try await steps.occurrence(inserted.occurrence.stepOccurrenceID)?.record.isExactly(inserted.occurrence)
                == true
        )
        await store.close()
    }
}

@Suite("Schema 22 recorded outcomes")
struct DB2BOutcomeTests {
    @Test(arguments: [ActOutcomeKind.foundActed, .actedUnverified, .actedNoop, .honestMiss, .ambiguous, .refused])
    func outcomeUsesFiveColumns(_ kind: ActOutcomeKind) async throws {
        let memory = try await AgentCallFixtures.open22()
        let call = try AgentCallFixtures.call("outcome", .act(target: "Save", verb: .click, value: nil, section: nil))
        _ = try await memory.calls.record(call)
        _ = try await memory.calls.advance([AgentCallTransition("outcome", .started(atMS: AgentCallFixtures.t0))])
        let progress = AgentCallProgress(
            .completed,
            result: .outcome(kind, message: "result"),
            endedAtMS: AgentCallFixtures.t0 + 1
        )
        #expect(try await memory.calls.advance([AgentCallTransition("outcome", progress)]) == .committed)
        #expect(try await memory.calls.call("outcome")?.progress.isExactly(progress) == true)
        #expect(
            try await memory.count(
                "SELECT count(*) FROM memory_agent_actions WHERE result_kind IS NULL AND gesture IS NOT NULL AND effect IS NOT NULL AND recovery IS NOT NULL AND outcome_origin='recorded'"
            ) == 1
        )
        await memory.store.close()
    }
}

@Suite("Schema 22 occurrence references")
struct DB2BOccurrenceReferenceTests {
    @Test
    func assignmentsMembershipsAndEvidenceKeepTheirSubjects() async throws {
        let memory = try await AttributionFixtures.open22()
        let stepID = try await memory.store.write { transaction in
            try transaction.execute(
                "INSERT INTO memory_routes(route_uuid,name,status,created_at_ms) VALUES ('route','Save','active',1)"
            )
            try transaction.execute(
                "INSERT INTO memory_route_steps(route_id,position,step_kind,goal_text) VALUES ((SELECT route_id FROM memory_routes WHERE route_uuid='route'),0,'goal','Save')"
            )
            return "step:\(try SQLiteIdentityRows.lastInsertedRow(transaction))"
        }
        _ = try await memory.tasks.record(
            TaskOccurrenceRecord(taskOccurrenceID: "attempt", startedAtMS: 1, status: .observed)
        )
        let steps = SQLiteStepOccurrenceRepository(store: memory.store)
        let inserted = try await steps.insert(
            StepOccurrenceRecord(stepOccurrenceID: "producer", startedAtMS: 1, status: .observed)
        )
        let id = inserted.occurrence.stepOccurrenceID
        #expect(try await steps.assign(id, toTask: "attempt", step: stepID, by: "fixture") == .committed)
        #expect(try await steps.occurrence(id)?.taskOccurrenceID == "attempt")
        _ = try await memory.verifications.record(
            VerificationRecord(
                event: AttributionFixtures.verificationEvent("verification"),
                scope: .step,
                method: .sceneText,
                verdict: .passed
            )
        )
        let membership = try StepMembership(
            stepOccurrenceID: id,
            eventID: "verification",
            position: 0,
            role: .verification
        )
        #expect(try await steps.attribute(verification: "verification", to: membership) == .committed)
        #expect(try await steps.memberships(of: id).first?.isExactly(membership) == true)
        let routeEvidence = try DefinitionEvidence(
            .route(routeID: "route", taskOccurrenceID: "attempt"),
            relation: .supports,
            assessedBy: "fixture",
            assessedAtMS: 1
        )
        let stepEvidence = try DefinitionEvidence(
            .step(stepID: stepID, stepOccurrenceID: id),
            relation: .supports,
            assessedBy: "fixture",
            assessedAtMS: 1
        )
        #expect(try await steps.record(routeEvidence) == .committed)
        #expect(try await steps.record(stepEvidence) == .committed)
        #expect(try await steps.evidence(ofRoute: "route").first?.isExactly(routeEvidence) == true)
        #expect(try await steps.evidence(ofStep: stepID).first?.isExactly(stepEvidence) == true)
        await memory.store.close()
    }
}

@Suite("Schema 22 existing dry run behavior")
struct DB2BDryRunTests {
    @Test
    func dryRunKeepsTheExistingResult() async throws {
        let memory = try await AgentCallFixtures.open22()
        _ = try await memory.calls.record(
            AgentCallFixtures.call("dry", .act(target: "Save", verb: .click, value: nil, section: nil))
        )
        _ = try await memory.calls.advance([AgentCallTransition("dry", .started(atMS: AgentCallFixtures.t0))])
        let progress = AgentCallProgress(
            .completed,
            result: .outcome(.dryRun, message: "preview"),
            endedAtMS: AgentCallFixtures.t0 + 1
        )
        #expect(try await memory.calls.advance([AgentCallTransition("dry", progress)]) == .committed)
        #expect(try await memory.calls.call("dry")?.progress.isExactly(progress) == true)
        await memory.store.close()
    }
}

@Suite("Schema 22 task value content")
struct DB2BTaskValueTests {
    @Test
    func textValuesHaveContentDigests() async throws {
        let memory = try await TaskFixtures.open22()
        _ = try await TaskFixtures.begin(memory)
        let digests = try await memory.store.read { snapshot in
            try snapshot.query("SELECT value_digest FROM memory_task_values WHERE content='text'", []) { $0.bytes(0) }
        }
        #expect(digests == [Array(Digest16.of("foto_demo.png"))])
        await memory.store.close()
    }
}
