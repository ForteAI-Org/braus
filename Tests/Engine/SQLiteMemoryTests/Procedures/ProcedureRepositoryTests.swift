//
//  ProcedureRepositoryTests.swift
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

/// ProcedureRepositoryTests prove schema 3 on real files: archives of schema 2 and 1 holding D1's facts
/// migrate keeping every row and inventing nothing; the procedure repository builds a candidate from
/// those facts, keeps one occurrence per call, versions interpretations, appends evaluations only when
/// a decision changes, keeps a part's state history, puts a policy in quarantine without deleting, and
/// stores templated arguments that a reader of the Route tables reads back exactly.
@Suite("Schema 3 and the procedure repository on real archives")
struct ProcedureRepositoryTests {

    /// An archive holding a task with one concluded, verified call, written through D1's repositories.
    static func populated() async throws -> TaskFixtures.Memory {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        _ = try await memory.facts.open(try OperationOpening(call: try OperationFactRepositoryTests.click("c1"),
                                                              startedAtMS: TaskFixtures.t0 + 1, attribution: attribution))
        _ = try await memory.facts.conclude(try OperationFactRepositoryTests.conclusion("c1"))
        return memory
    }

    static func tables(of version: Int32) throws -> [String] {
        SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.text(of: version))
    }

    static func downgrade(_ url: URL, to version: Int32) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        try SchemaShape.downgrade(raw, to: version)
        _ = try raw.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.integer(0) }
    }

    @Test("an archive of schema 2 with D1's facts migrates to the current schema after its copy, keeping every row; nothing is learned or qualified by the migration")
    func migratesFromTwo() async throws {
        let memory = try await Self.populated()
        await memory.store.close()
        try Self.downgrade(memory.url, to: 2)
        let tables = try Self.tables(of: 2)
        let before = try SchemaMigrationTests.counts(tables, at: memory.url)
        #expect(before["memory_operation_verifications"] == 1 && before["memory_tasks"] == 1)
        #expect(SQLiteMemoryInspection.inspect(memory.url).shape == .migratable(from: 2))
        let reader = SQLiteMemoryStore(url: memory.url)
        #expect(await storeError { try await reader.open(.existingArchive) }
                == .schema(.migrationRequired(found: 2, supported: SQLiteMemorySchema.version)))

        let store = try await SQLiteMemoryStore.open(at: memory.url)
        let migration = try #require(try await store.diagnostics().migration)
        #expect(migration.fromVersion == 2 && migration.toVersion == SQLiteMemorySchema.version)
        #expect(try await store.read { try SchemaShape($0) } == SchemaShape.current)
        let recorded = try await store.read { snapshot in
            try snapshot.query("SELECT to_version || ':' || from_version FROM memory_schema_migrations ORDER BY to_version") {
                try $0.text(0) ?? ""
            }
        }
        #expect(recorded == ["2:0", "\(SQLiteMemorySchema.version):2"], "the bootstrap of schema 2 and this migration: \(recorded)")
        for table in ["memory_procedure_candidates", "memory_procedure_versions", "memory_part_qualifications", "brain_relations",
                      "brain_relation_applications", "brain_relation_evaluations", "brain_relation_evidence", "memory_variant_prefixes",
                      "memory_variant_prefix_checks"] {
            #expect(try await count("SELECT count(*) FROM \(table)", in: store) == 0, "\(table): no knowledge invented by a migration")
        }
        await store.close()
        var after = try SchemaMigrationTests.counts(tables, at: memory.url)
        #expect(after["memory_schema_migrations"] == (before["memory_schema_migrations"] ?? 0) + 1, "the migration is recorded")
        after["memory_schema_migrations"] = before["memory_schema_migrations"]
        #expect(after == before, "every row of schema 2 is kept")
        let copy = memory.url.deletingLastPathComponent().appendingPathComponent(migration.copyName)
        #expect(SQLiteMemoryInspection.inspect(copy).shape == .migratable(from: 2), "the copy is the archive of schema 2 as it was")

        // The facts migrated are what D2 builds from: the candidate and the relations come from them now.
        let reopened = try await SQLiteMemoryStore.open(at: memory.url)
        let procedures = SQLiteProcedureRepository(store: reopened)
        let (receipt, candidate) = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer,
                                                                                    at: TaskFixtures.t0 + 100))
        #expect(receipt == .committed && candidate.steps.map(\.callEventID) == ["c1"])
        let relations = SQLiteBrainRelationRepository(store: reopened)
        #expect(try await relations.applyPending(at: TaskFixtures.t0 + 100) == 1)
        #expect(try await relations.application(of: "c1")?.exclusion == .noBeforeState,
                "a call whose samples were never placed in a state teaches no relation, and says so")
        #expect(try await relations.applyPending(at: TaskFixtures.t0 + 200) == 0, "a call is applied once")
        await reopened.close()
    }

    @Test("an archive of schema 1 migrates to the current schema in one transaction, recorded from 1")
    func migratesFromOne() async throws {
        let url = try await SchemaMigrationTests.populatedVersion1()
        let before = try SchemaMigrationTests.counts(try Self.tables(of: 1), at: url)
        let store = try await SQLiteMemoryStore.open(at: url)
        let migration = try #require(try await store.diagnostics().migration)
        #expect(migration.fromVersion == 1 && migration.toVersion == SQLiteMemorySchema.version)
        #expect(try await count("SELECT count(*) FROM memory_schema_migrations WHERE from_version = 1 AND to_version = \(SQLiteMemorySchema.version)",
                                in: store) == 1)
        await store.close()
        #expect(try SchemaMigrationTests.counts(try Self.tables(of: 1), at: url) == before)
    }

    @Test("a migration from schema 2 that fails inside its transaction leaves schema 2 whole with its copy, and the next open migrates")
    func failedMigrationFromTwo() async throws {
        struct Fault: Error {}
        let memory = try await Self.populated()
        await memory.store.close()
        try Self.downgrade(memory.url, to: 2)
        let before = try SchemaMigrationTests.counts(try Self.tables(of: 2), at: memory.url)
        let store = SQLiteMemoryStore(url: memory.url)
        await store.injectMigrationFault { throw Fault() }
        await #expect(throws: (any Error).self) { try await store.open() }
        #expect(SQLiteMemoryInspection.inspect(memory.url).shape == .migratable(from: 2))
        #expect(try SchemaMigrationTests.counts(try Self.tables(of: 2), at: memory.url) == before)
        let retried = try await SQLiteMemoryStore.open(at: memory.url)
        #expect(try await retried.diagnostics().migration?.fromVersion == 2)
        await retried.close()
    }

    /// A candidate of the populated archive, interpreted, with its version.
    static func interpreted(_ memory: TaskFixtures.Memory, outcome: DeclaredPartOutcome? = .completed)
        async throws -> (SQLiteProcedureRepository, String) {
        _ = try await memory.tasks.checkpoint(try TaskCheckpointDraft(kind: .end, declared: .completed), attempt: "attempt-1",
                                              at: TaskFixtures.t0 + 90, by: TaskFixtures.producer)
        let procedures = SQLiteProcedureRepository(store: memory.store)
        let (_, candidate) = try #require(try await procedures.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer,
                                                                              at: TaskFixtures.t0 + 100))
        let interpretation = try ProcedureInterpretation(candidateID: candidate.candidateID, parts: [
            try PartStatement(reference: .procedure, label: "Open the export menu", outcome: outcome),
            try PartStatement(reference: .step(0), label: "Click Export", outcome: nil),
        ])
        let outcome = try await procedures.interpret(interpretation, by: TaskFixtures.producer, at: TaskFixtures.t0 + 110)
        return (procedures, outcome.routeID)
    }

    @Test("an evaluation is appended only when its decision changes; a part's state keeps it and the parts containing it out of the catalogue without deleting anything; a retired part never comes back, not even through its parent")
    func statesAndEvaluations() async throws {
        let memory = try await Self.populated()
        let (procedures, routeID) = try await Self.interpreted(memory)
        let catalogue = try await procedures.catalogue()
        #expect(catalogue.map { $0.part.kind } == [.procedure, .step])
        #expect(try await memory.count("SELECT count(*) FROM memory_part_qualifications") == 2)
        _ = try await procedures.requalify(routeID: routeID, at: TaskFixtures.t0 + 120)
        #expect(try await memory.count("SELECT count(*) FROM memory_part_qualifications") == 2, "the same decision is not repeated")
        let step = try #require(catalogue.first { $0.part.kind == .step })
        #expect(step.contract.contains { $0.kind == .application && $0.bundleID == AgentCallFixtures.app.bundleID })

        #expect(try await procedures.setState(.toReevaluate, of: step.part.partID, reason: "a contrary proof", by: "test",
                                               at: TaskFixtures.t0 + 130) == .committed)
        #expect(try await procedures.catalogue().isEmpty, "the procedure contains the step to evaluate again")
        #expect(try await procedures.setState(.usable, of: step.part.partID, reason: "evaluated again", by: "test",
                                               at: TaskFixtures.t0 + 140) == .committed)
        #expect(try await procedures.catalogue().count == 2)
        #expect(try await procedures.setState(.retired, of: step.part.partID, reason: "the application changed", by: "test",
                                               at: TaskFixtures.t0 + 150) == .committed)
        await #expect(throws: ProcedureError.retired(partID: step.part.partID)) {
            _ = try await procedures.setState(.usable, of: step.part.partID, reason: "again", by: "test", at: TaskFixtures.t0 + 160)
        }
        #expect(try await procedures.catalogue().isEmpty, "a retired step does not come back through its procedure")
        #expect(try await memory.count("SELECT count(*) FROM memory_part_states") == 3)
        #expect(try await procedures.version(routeID)?.version.parts.count == 2, "a retired part is kept with its version")
        await memory.store.close()
    }

    @Test("a policy put in quarantine stops what it admitted from being offered and deletes nothing")
    func quarantine() async throws {
        let memory = try await Self.populated()
        let (procedures, routeID) = try await Self.interpreted(memory)
        #expect(try await procedures.catalogue().count == 2)
        #expect(try await procedures.quarantine(policy: QualificationPolicy.version, reason: "the rule admitted a false pass",
                                                 at: TaskFixtures.t0 + 200) == .committed)
        #expect(try await procedures.quarantine(policy: QualificationPolicy.version, reason: "again", at: TaskFixtures.t0 + 210)
                == .alreadyApplied)
        #expect(try await procedures.catalogue().isEmpty)
        let stored = try #require(try await procedures.version(routeID))
        #expect(stored.qualifications.values.allSatisfy { $0.verdict == .admitted }, "the decisions are kept as they were made")
        await memory.store.close()
    }

    @Test("two connections building and interpreting at once, as two processes would: one candidate, one occurrence, one version for the same statements, ordered revisions for different ones")
    func concurrentProducers() async throws {
        let memory = try await Self.populated()
        _ = try await memory.tasks.checkpoint(try TaskCheckpointDraft(kind: .end, declared: .completed), attempt: "attempt-1",
                                              at: TaskFixtures.t0 + 90, by: TaskFixtures.producer)
        let other = try await SQLiteMemoryStore.open(at: memory.url)
        let one = SQLiteProcedureRepository(store: memory.store), two = SQLiteProcedureRepository(store: other)
        async let a = one.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer, at: TaskFixtures.t0 + 100)
        async let b = two.buildCandidate(attemptID: "attempt-1", for: TaskFixtures.producer, at: TaskFixtures.t0 + 101)
        let (first, second) = (try #require(try await a), try #require(try await b))
        #expect(first.1.candidateID == second.1.candidateID)
        #expect([first.0, second.0].filter { $0 == .committed }.count == 1, "one build wrote it, the other found it")
        #expect(try await memory.count("SELECT count(*) FROM memory_procedure_candidates") == 1)
        #expect(try await memory.count("SELECT count(*) FROM memory_step_occurrences") == 1)

        func statement(_ label: String) throws -> ProcedureInterpretation {
            try ProcedureInterpretation(candidateID: first.1.candidateID, parts: [
                try PartStatement(reference: .procedure, label: label, outcome: .completed),
                try PartStatement(reference: .step(0), label: "Click Export", outcome: nil),
            ])
        }
        async let same1 = one.interpret(try statement("Open the export menu"), by: TaskFixtures.producer, at: TaskFixtures.t0 + 110)
        async let same2 = two.interpret(try statement("Open the export menu"), by: TaskFixtures.producer, at: TaskFixtures.t0 + 111)
        let (x, y) = (try await same1, try await same2)
        #expect(x.routeID == y.routeID && [x.receipt, y.receipt].filter { $0 == .committed }.count == 1)
        async let other1 = one.interpret(try statement("Open the menu of exports"), by: TaskFixtures.producer, at: TaskFixtures.t0 + 120)
        async let other2 = two.interpret(try statement("Show the export menu"), by: TaskFixtures.producer, at: TaskFixtures.t0 + 121)
        let (p, q) = (try await other1, try await other2)
        #expect(Set([p.revision, q.revision]) == [2, 3], "each offer takes the next revision in turn")
        let versions = try await one.versions(ofAttempt: "attempt-1")
        #expect(versions.count == 3 && versions.filter(\.isCurrent).count == 1, "one chain, one current version")
        await other.close()
        await memory.store.close()
    }

    @Test("a templated argument is stored as its segments and read back exactly, in its place among the operation's arguments")
    func templateRoundTrip() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let routes = SQLiteRouteRepository(store: store)
        let parameters = [RouteParameter(parameterID: "p-name", name: "name", direction: .input, valueType: .text, isRequired: true),
                          RouteParameter(parameterID: "p-ext", name: "extension", direction: .input, valueType: .text, isRequired: true)]
        let operation = StepOperation(operationID: "op", position: 0, tool: .typeText, arguments: [
            OperationArgument(name: "target", position: 0, value: .literal(.text("Name"))),
            OperationArgument(name: "text", position: 0, value: .template([.parameter("p-name"), .literal("."), .parameter("p-ext")])),
            OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true))),
        ])
        let definition = RouteDefinition(routeID: "r", name: "Set the name", createdAtMS: TaskFixtures.t0, parameters: parameters,
                                         steps: [ProcedureStep(stepID: "s", position: 0, goalText: "Set <name>.<extension>",
                                                               bundleID: "com.apple.Preview", operations: [operation])])
        #expect(try await routes.record(definition, state: RouteState(status: .draft)) == .committed)
        let read = try #require(try await routes.route("r"))
        #expect(read.definition.isExactly(definition))
        #expect(try await routes.record(definition, state: RouteState(status: .draft)) == .alreadyApplied)
        let literal = StepOperation(operationID: "op2", position: 0, tool: .typeText, arguments: [
            OperationArgument(name: "target", position: 0, value: .literal(.text("Name"))),
            OperationArgument(name: "text", position: 0, value: .template([.literal("only")])),
            OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true))),
        ])
        let refused = RouteDefinition(routeID: "r2", name: "n", createdAtMS: TaskFixtures.t0, parameters: parameters,
                                      steps: [ProcedureStep(stepID: "s2", position: 0, goalText: "g", operations: [literal])])
        await #expect(throws: RouteError.self) { _ = try await routes.record(refused, state: RouteState(status: .draft)) }
        await store.close()
    }
}
