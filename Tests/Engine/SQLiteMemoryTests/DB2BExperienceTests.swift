import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema 22 experience identities")
struct DB2BExperienceTests {
    @Test
    func insertionReturnsStoreIdentity() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        try await store.write {
            try $0.execute(
                "INSERT INTO memory_routes(route_uuid,name,status,created_at_ms) VALUES ('route','Save','active',1)"
            )
        }
        let repository = SQLiteExperienceRepository(store: store)
        let offered = try ExperienceRecord(experienceID: "producer", phrase: "Save", routeID: "route", createdAtMS: 1)
        #expect(try await repository.record(offered) == .committed)
        let stored = try #require(try await repository.experiences(ofRoute: "route").first)
        #expect(Int64(stored.experienceID) != nil)
        #expect(
            stored.phrase == offered.phrase && stored.routeID == offered.routeID
                && stored.createdAtMS == offered.createdAtMS
        )
        #expect(try await repository.experience(stored.experienceID)?.isExactly(stored) == true)
        #expect(try await repository.record(stored) == .alreadyApplied)
        let second = try await repository.insert(offered)
        #expect(second.experience.experienceID != stored.experienceID)
        #expect(
            try await store.read { try $0.query("SELECT count(*) FROM memory_experiences", []) { $0.integer(0) }.first }
                == 2
        )
        await store.close()
    }
}

@Suite("Schema 22 typed experience bindings")
struct DB2BExperienceBindingTests {
    @Test
    func bindingsAndUsesKeepTheirValues() async throws {
        let memory = try await AttributionFixtures.open22()
        let types: [ParameterValueType] = [.text, .integer, .real, .boolean]
        let parameterIDs = try await memory.store.write { transaction in
            try transaction.execute(
                "INSERT INTO memory_routes(route_uuid,name,status,created_at_ms) VALUES ('route','Save','active',1)"
            )
            return try types.map { type in
                try transaction.execute(
                    "INSERT INTO memory_route_parameters(route_id,name,direction,value_type,is_required) VALUES ((SELECT route_id FROM memory_routes WHERE route_uuid='route'),?,'input',?,1)",
                    [.text(type.rawValue), .text(type.rawValue)]
                )
                return "parameter:\(try SQLiteIdentityRows.lastInsertedRow(transaction))"
            }
        }
        let literals: [BrainArgument.Value] = [.text("Café"), .integer(2), .real(0.5), .boolean(true)]
        let bindings = try zip(zip(parameterIDs, types), literals).map {
            try ExperienceBinding(parameterID: $0.0.0, valueType: $0.0.1, source: .literal($0.1))
        }
        let repository = SQLiteExperienceRepository(store: memory.store)
        let offered = try ExperienceRecord(
            experienceID: "producer",
            phrase: "Save",
            routeID: "route",
            createdAtMS: 1,
            bindings: bindings
        )
        let inserted = try await repository.insert(offered)
        #expect(inserted.receipt == .committed)
        let stored = try #require(try await repository.experience(inserted.experience.experienceID))
        #expect(stored.isExactly(inserted.experience))
        _ = try await memory.calls.record(AttributionFixtures.agentCall("call"))
        #expect(
            try await repository.record(
                ExperienceUse(experienceID: stored.experienceID, eventID: "call", verdict: .passed)
            ) == .committed
        )
        #expect(try await repository.uses(of: stored.experienceID).map(\.eventID) == ["call"])
        #expect(
            try await repository.useCounts(of: stored.experienceID)
                == ExperienceUseCounts(passed: 1, failed: 0, unknown: 0)
        )
        await memory.store.close()
    }
}

extension DB2BExperienceTests {
    @Test
    func aReturnedIdentityRefusesDifferentContent() async throws {
        let memory = try await AttributionFixtures.open22()
        try await memory.store.write {
            try $0.execute(
                "INSERT INTO memory_routes(route_uuid,name,status,created_at_ms) VALUES ('route','Save','active',1)"
            )
        }
        let repository = SQLiteExperienceRepository(store: memory.store)
        let inserted = try await repository.insert(
            ExperienceRecord(experienceID: "producer", phrase: "Save", routeID: "route", createdAtMS: 1)
        )
        let conflict = try ExperienceRecord(
            experienceID: inserted.experience.experienceID,
            phrase: "Other",
            routeID: "route",
            createdAtMS: 1
        )
        let error = await storeError { _ = try await repository.record(conflict) }
        guard case .identity? = error else {
            Issue.record("different content under a returned identity must conflict")
            return
        }
        #expect(
            try await repository.experience(inserted.experience.experienceID)?.isExactly(inserted.experience) == true
        )
        #expect(try await memory.count("SELECT count(*) FROM memory_experiences") == 1)
        await memory.store.close()
    }
}

@Suite("Qualified schema 22 step references")
struct DB2QualifiedStepTests {
    @Test func assignmentEvidenceAndExperienceKeepQualifiedIDs() async throws {
        let memory = try await AttributionFixtures.open22()
        try await memory.store.write {
            try $0.execute("INSERT INTO memory_routes(route_uuid,name,status,created_at_ms) VALUES ('route','Save','active',1)")
            try $0.execute("INSERT INTO memory_route_steps(route_id,position,goal_text,step_kind) VALUES (1,0,'Save','goal')")
        }
        let steps = SQLiteStepOccurrenceRepository(store: memory.store)
        let inserted = try await steps.insert(StepOccurrenceRecord(stepOccurrenceID: "offered", startedAtMS: 1, endedAtMS: 2, status: .completed))
        let id = inserted.occurrence.stepOccurrenceID
        #expect(try await steps.assign(id, toTask: nil, step: "step:1", by: "test") == .committed)
        #expect(try await steps.assign(id, toTask: nil, step: "step:1", by: "test") == .alreadyApplied)
        #expect(try await steps.occurrence(id)?.stepID == "step:1")
        let evidence = try DefinitionEvidence(.step(stepID: "step:1", stepOccurrenceID: id), relation: .supports, assessedBy: "test", assessedAtMS: 2)
        _ = try await steps.record(evidence)
        #expect(try await steps.evidence(ofStep: "step:1").first?.isExactly(evidence) == true)
        let experiences = SQLiteExperienceRepository(store: memory.store)
        let saved = try await experiences.insert(ExperienceRecord(experienceID: "offered", phrase: "Save", routeID: "route", stepID: "step:1", createdAtMS: 2))
        #expect(try await experiences.experience(saved.experience.experienceID)?.stepID == "step:1")
        #expect(try await experiences.record(saved.experience) == .alreadyApplied)
        await memory.store.close()
    }
}
