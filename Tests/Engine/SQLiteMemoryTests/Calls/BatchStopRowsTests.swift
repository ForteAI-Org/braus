import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

struct BatchStopRowsTests {
    typealias F = AgentCallFixtures

    private func open() async throws -> F.Memory {
        let url = try temporaryDatabase()
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        return F.Memory(url: url, store: store, calls: SQLiteAgentCallRepository(store: store),
                        captures: SQLiteCaptureRepository(store: store))
    }

    private func start(_ memory: F.Memory, count: Int = 3) async throws {
        let request = AgentCallRequest.act(target: "Next", verb: .click, value: nil, section: nil)
        let (batch, children) = try F.batch("b", Array(repeating: request, count: count))
        _ = try await memory.calls.record(batch: batch, steps: children)
        _ = try await memory.calls.advance([AgentCallTransition("b", .started)])
    }

    private func end(_ memory: F.Memory, _ position: Int, _ kind: ActOutcomeKind) async throws {
        _ = try await memory.calls.advance([
            AgentCallTransition("b.\(position)", .started),
            AgentCallTransition("b.\(position)", F.outcome(kind))
        ])
    }

    @Test func takeoverWritesOneTypedRowAndRoundTrips() async throws {
        let memory = try await open()
        try await start(memory)
        try await end(memory, 0, .foundActed)
        try await end(memory, 1, .foundActed)
        _ = try await memory.calls.advance([AgentCallTransition("b.2", F.ended(.skipped))])
        let progress = AgentCallProgress(.completed, result: .batch(stopped: true, attempted: 2, verified: 2),
            endedAtMS: F.t0 + 100, batchConclusion: .stopped(at: 2, reason: .personInControl))
        _ = try await memory.calls.advance([AgentCallTransition("b", progress)])
        #expect(try await memory.count("SELECT count(*) FROM memory_batch_stops WHERE event_id=(SELECT event_id FROM memory_events WHERE event_uuid='b') AND stopped_at_position=2 AND reason='person_in_control'") == 1)
        #expect(try await memory.calls.call("b")?.progress.batchConclusion == progress.batchConclusion)
        #expect(try await memory.calls.advance([AgentCallTransition("b", progress)]) == .alreadyApplied)
        await memory.store.close()
    }

    @Test func unknownIntermediateCanFinishAndRoundTrip() async throws {
        let memory = try await open()
        try await start(memory)
        for (index, kind) in [ActOutcomeKind.foundActed, .actedUnverified, .foundActed].enumerated() {
            try await end(memory, index, kind)
        }
        let progress = AgentCallProgress(.completed, result: .batch(stopped: false, attempted: 3, verified: 2),
            endedAtMS: F.t0 + 100, batchConclusion: .ranToEnd)
        _ = try await memory.calls.advance([AgentCallTransition("b", progress)])
        #expect(try await memory.calls.call("b")?.progress.batchConclusion == .ranToEnd)
        #expect(try await memory.count("SELECT count(*) FROM memory_batch_stops") == 0)
        await memory.store.close()
    }

    @Test func stepAfterStopIsRejected() async throws {
        let memory = try await open()
        try await start(memory)
        for index in 0..<3 { try await end(memory, index, .foundActed) }
        let progress = AgentCallProgress(.completed, result: .batch(stopped: true, attempted: 3, verified: 3),
            endedAtMS: F.t0 + 100, batchConclusion: .stopped(at: 1, reason: .personInControl))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("b", progress)]) }
                == .batchNotSettled(eventID: "b"))
        await memory.store.close()
    }

    @Test func legacyHasNoPolicyRow() async throws {
        let memory = try await open()
        try await start(memory, count: 1)
        try await end(memory, 0, .foundActed)
        _ = try await memory.calls.advance([AgentCallTransition("b", F.ended(.completed,
            .batch(stopped: false, attempted: 1, verified: 1)))])
        #expect(try await memory.calls.call("b")?.progress.batchConclusion == nil)
        #expect(try await memory.count("SELECT count(*) FROM memory_batch_stops") == 0)
        await memory.store.close()
    }

    @Test func menuIsAllowedButOpeningSessionIsNot() throws {
        let (parent, menu) = try F.batch("b", [.menu(path: "File > Save")])
        try SQLiteAgentCallRows.validate(batch: parent, steps: menu)
        let (_, open) = try F.batch("b", [.openSession(app: "Other", window: nil)])
        #expect(throws: AgentCallError.self) { try SQLiteAgentCallRows.validate(batch: parent, steps: open) }
        #expect(!AgentTool.menu.isBatchStep)
    }
}
