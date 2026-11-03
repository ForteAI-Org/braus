import CoreGraphics
import EngineCore
import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema 22 capture and input repositories")
struct DB2BCaptureTests {
    @Test
    func capturesKeepContentAndShareElementSets() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let captures = SQLiteCaptureRepository(store: store)
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [SceneFixtures.button("Compose", y: 700)]))
        for id in ["one", "two"] {
            let sample = SceneFixtures.sample(id, of: window)
            #expect(try await captures.record(SceneFixtures.event(id)) == .committed)
            #expect(try await captures.record(sample) == .committed)
            #expect(try await captures.record(sample) == .alreadyApplied)
            #expect(try await captures.sample(sample.key) == sample)
            #expect(try await captures.event(id)?.captureStatus == .complete)
        }
        let sets = try await store.read {
            try $0.query(
                "SELECT count(DISTINCT set_id) FROM memory_event_observations WHERE observation_kind='capture'",
                []
            ) { $0.integer(0) }.first
        }
        #expect(sets == 1)
        await store.close()
    }

    @Test
    func inputsAndCorrelationsKeepPublicIDs() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let inputs = SQLiteObservedInputRepository(store: store)
        let input = try ObservedInputRecord(
            event: AttributionFixtures.watcherEvent("input"),
            input: AttributionFixtures.click("Save")
        )
        #expect(try await inputs.record(input) == .committed)
        #expect(try await inputs.record(input) == .alreadyApplied)
        #expect(try await inputs.input("input")?.input.isExactly(input.input) == true)
        await store.close()
    }
}

@Suite("Schema 22 call reconciliation references")
struct DB2BReconciliationTests {
    @Test
    func acknowledgementKeepsTheCallIdentity() async throws {
        let memory = try await AgentCallFixtures.open22()
        let facts = SQLiteOperationFactRepository(store: memory.store)
        _ = try await memory.calls.record(
            try AgentCallFixtures.call("call", .scroll(direction: .down, lines: 1, target: nil, section: nil))
        )
        let fact = try CallReconciliation(
            callEventID: "call",
            kind: .acknowledged,
            declaredBy: .person,
            recordedAtMS: 1
        )
        #expect(try await facts.reconcile(fact) == .committed)
        #expect(try await facts.reconciliations(of: "call").map(\.callEventID) == ["call"])
        await memory.store.close()
    }
}

extension DB2BReconciliationTests {
    @Test
    func startedCallsKeepEventUUIDs() async throws {
        let memory = try await AgentCallFixtures.open22()
        let facts = SQLiteOperationFactRepository(store: memory.store)
        _ = try await facts.open(
            OperationOpening(
                call: AgentCallFixtures.call("call", .scroll(direction: .down, lines: 1, target: nil, section: nil)),
                startedAtMS: AgentCallFixtures.t0
            )
        )
        let executorID = try await memory.store.write { transaction in
            try transaction.execute("INSERT INTO memory_executors(source,process_id,started_at_ms) VALUES ('app',1,1)")
            let id = try SQLiteIdentityRows.lastInsertedRow(transaction)
            try transaction.execute(
                "INSERT INTO memory_call_executors(event_id,executor_id) VALUES ((SELECT event_id FROM memory_events WHERE event_uuid='call'),?)",
                [.integer(id)]
            )
            return id
        }
        let started = try await facts.startedCalls(excludingExecutor: String(executorID + 1))
        #expect(started.map(\.eventID) == ["call"])
        #expect(started.map(\.executorID) == [String(executorID)])
        await memory.store.close()
    }

    @Test
    func unresolvedCallsKeepTheirExistingOrder() async throws {
        let memory = try await AgentCallFixtures.open22()
        let facts = SQLiteOperationFactRepository(store: memory.store)
        for id in ["z", "a"] {
            _ = try await facts.open(
                OperationOpening(
                    call: AgentCallFixtures.call(id, .scroll(direction: .down, lines: 1, target: nil, section: nil)),
                    startedAtMS: AgentCallFixtures.t0
                )
            )
        }
        let calls = try await facts.unresolvedCalls(source: .app, streamID: "worker-1", excludingExecutor: nil)
        #expect(calls.map(\.eventID) == ["a", "z"])
        await memory.store.close()
    }
}

extension DB2BReconciliationTests {
    @Test(arguments: [false, true])
    func allocatedExecutorCanBeLinkedAndExcluded(schema22: Bool) async throws {
        let memory = try await TaskFixtures.open(schema: schema22 ? .version22 : .historical19)
        let executor = try await memory.facts.allocateExecutor(source: "app", processID: 1, startedAtMS: TaskFixtures.t0)
        #expect(schema22 ? Int64(executor.executorID) != nil : UUID(uuidString: executor.executorID) != nil)
        var opening = try OperationOpening(call: OperationFactRepositoryTests.click("allocated-executor"), startedAtMS: TaskFixtures.t0)
        opening.executor = executor
        #expect(try await memory.facts.open(opening) == .committed)
        #expect(try await memory.facts.open(opening) == .alreadyApplied)
        #expect(try await memory.facts.startedCalls(excludingExecutor: executor.executorID).isEmpty)
        #expect(try await memory.facts.startedCalls(excludingExecutor: schema22 ? "0" : "other").map(\.executorID) == [executor.executorID])
        await memory.store.close()
    }

    @Test func producerExecutorUUIDIsRefusedWithoutWriting() async throws {
        let memory = try await TaskFixtures.open22()
        var opening = try OperationOpening(call: OperationFactRepositoryTests.click("unknown-executor"), startedAtMS: TaskFixtures.t0)
        opening.executor = ExecutorRecord(executorID: "unallocated-uuid", source: "app", processID: 1, startedAtMS: TaskFixtures.t0)
        let offered = opening
        let failure = await storeError { _ = try await memory.facts.open(offered) }
        guard case .identity? = failure else {
            Issue.record("An executor must be allocated before it can be linked")
            await memory.store.close()
            return
        }
        #expect(try await memory.count("SELECT count(*) FROM memory_executors") == 0)
        #expect(try await memory.count("SELECT count(*) FROM memory_events") == 0)
        await memory.store.close()
    }
}
