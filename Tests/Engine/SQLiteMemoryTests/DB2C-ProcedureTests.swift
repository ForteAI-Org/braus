import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Procedure catalogue on schema 22", .serialized)
struct DB2CProcedureTests {
    @Test func candidateUsesStoredOccurrencesOnEveryReadAndRetry() async throws {
        let memory = try await TaskFixtures.open22()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        _ = try await memory.facts.open(try OperationOpening(call: OperationFactRepositoryTests.click("c1"),
            startedAtMS: TaskFixtures.t0 + 1, attribution: attribution))
        _ = try await memory.facts.conclude(try OperationFactRepositoryTests.conclusion("c1"))
        let procedures = SQLiteProcedureRepository(store: memory.store)
        let first = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer, at: TaskFixtures.t0 + 100))
        let second = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer, at: TaskFixtures.t0 + 101))
        #expect(second.receipt == .alreadyApplied)
        #expect(second.candidate.steps == first.candidate.steps)
        let occurrences = SQLiteStepOccurrenceRepository(store: memory.store)
        for step in first.candidate.steps {
            #expect(Int64(step.stepOccurrenceID) != nil)
            #expect(try await occurrences.occurrence(step.stepOccurrenceID)?.taskOccurrenceID == "attempt-1")
            #expect(try await occurrences.memberships(of: step.stepOccurrenceID).first?.eventID == step.callEventID)
        }
        await memory.store.close()
    }

    @Test func migratedVersionAndRecallCatalogueKeepTheirContent() async throws {
        let memory = try await ProcedureRepositoryTests.populated(schema: .historical19)
        let (_, route) = try await ProcedureRepositoryTests.interpreted(memory)
        let oldProcedures = SQLiteProcedureRepository(store: memory.store)
        let previous = try #require(try await oldProcedures.version(route))
        let expectedOffered = try await oldProcedures.catalogue().count
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".migrating-22-c")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let procedures = SQLiteProcedureRepository(store: store)
        let saved = try #require(try await procedures.version(route))
        #expect(saved.version.definition.name == previous.version.definition.name)
        #expect(saved.version.definition.steps.map(\.goalText) == previous.version.definition.steps.map(\.goalText))
        #expect(saved.version.parts.map(\.label) == previous.version.parts.map(\.label))
        #expect(saved.version.parts.map(\.declaredOutcome) == previous.version.parts.map(\.declaredOutcome))
        #expect(saved.contract.map(\.kind) == previous.contract.map(\.kind))
        #expect(saved.isCurrent == previous.isCurrent)
        let rebuilt = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer, at: TaskFixtures.t0 + 120))
        #expect(rebuilt.receipt == .alreadyApplied)
        #expect(rebuilt.candidate.candidateID == saved.version.candidateID)
        let interpretation = try ProcedureInterpretation(candidateID: rebuilt.candidate.candidateID, parts: [
            try PartStatement(reference: .procedure, label: "Open the export menu", outcome: .completed),
            try PartStatement(reference: .step(0), label: "Click Export", outcome: nil)
        ])
        let repeated = try await procedures.interpret(interpretation, by: TaskFixtures.producer, at: TaskFixtures.t0 + 130)
        #expect(repeated.receipt == .alreadyApplied)
        #expect(repeated.routeID == route)
        let recall = SQLiteRecallRepository(store: store)
        let generation = try await recall.startGeneration(format: .labelled, spaceID: nil, at: ProcedureFixtures.t0 + 100)
        _ = try await recall.enumerate(generation, pageSize: 100, at: ProcedureFixtures.t0 + 101)
        let entries = try await recall.entries(of: generation).entries
        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.routeID)) == [route])
        let changed = try ProcedureInterpretation(candidateID: rebuilt.candidate.candidateID, parts: [
            try PartStatement(reference: .procedure, label: "Open the export options", outcome: .completed),
            try PartStatement(reference: .step(0), label: "Choose Export", outcome: nil)
        ])
        let revised = try await procedures.interpret(changed, by: TaskFixtures.producer, at: TaskFixtures.t0 + 140)
        #expect(revised.receipt == .committed)
        #expect(revised.revision == 2)
        let latest = try #require(try await procedures.version(revised.routeID))
        #expect(latest.version.definition.supersedesRouteID == route)
        #expect(latest.version.parts.first?.label == "Open the export options")
        #expect(try await procedures.requalify(routeID: revised.routeID, at: TaskFixtures.t0 + 150).count == latest.version.parts.count)
        #expect(try await procedures.versions(ofAttempt: "attempt-1").count == 2)
        let offeredNow = try await procedures.catalogue()
        #expect(offeredNow.count == expectedOffered, "qualifications: \(latest.qualifications)")
        #expect(try await procedures.reevaluateOutdated(at: TaskFixtures.t0 + 160).isEmpty)
        #expect(try await procedures.method(of: revised.routeID)?.count == 1)
        _ = try await procedures.families()
        _ = try await procedures.adaptations()
        #expect(try await procedures.knownPhases(candidateID: rebuilt.candidate.candidateID).isEmpty)
        let step = try #require(latest.version.parts.first { $0.kind == .step })
        #expect(try await procedures.setState(.toReevaluate, of: step.partID, reason: "a contrary proof", by: "test", at: TaskFixtures.t0 + 170) == .committed)
        #expect(try await procedures.catalogue().isEmpty)
        #expect(try await procedures.setState(.usable, of: step.partID, reason: "evaluated again", by: "test", at: TaskFixtures.t0 + 180) == .committed)
        let offeredAgain = try await procedures.catalogue()
        #expect(offeredAgain.count == expectedOffered)
        _ = try await procedures.recordResult(.nothing(reason: "no separate result"), reading: .nothing, attemptID: "attempt-1", eventID: "result", by: TaskFixtures.producer, at: TaskFixtures.t0 + 190)
        #expect(try await procedures.results(ofAttempt: "attempt-1").count == 1)
        let inspection = try #require(try await procedures.inspect(taskID: "task-1"))
        #expect(inspection.counts.operationalSteps == 1)
        #expect(inspection.counts.versions == 2)
        let rows = try await store.read { try SQLiteMemoryInspection.taskRows($0, filter: "1", values: [], limit: 20) }
        #expect(rows.first?.taskID == "task-1")
        #expect(rows.first?.versions == 2)

        _ = try await procedures.setState(.retired, of: step.partID, reason: "retired_by_person", by: "person", at: TaskFixtures.t0 + 200)
        let states = try await store.read {
            try $0.query("SELECT reason_code,recorded_by FROM memory_part_states WHERE state='retired'") {
                [try $0.text(0), try $0.text(1)]
            }
        }
        #expect(states == [["retired_by_person", "person"]])
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }
}
