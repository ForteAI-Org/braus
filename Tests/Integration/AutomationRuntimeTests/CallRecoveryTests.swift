@testable import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SQLiteMemory
import Testing

@MainActor
@Suite(.serialized)
struct CallRecoveryTests {
    static func recorder(_ memory: MemoryService, ended: Bool) async throws -> CallRecorder {
        let recorder = W.recorder(memory)
        try await recorder.begin(.appCall(app: "files", verb: "find", arguments: #"{"text":"synthetic"}"#), app: nil)
        if ended { try await recorder.end(.failed, result: .error(message: "Synthetic legacy failure"), tool: .appCall) }
        return recorder
    }

    @Test func personRecoveryPreservesFactsAndIsIdempotent() async throws {
        let memory = try W.service()
        let recorder = try await Self.recorder(memory, ended: true)
        let before = try #require(try await memory.call(recorder.eventID))
        let review = try await memory.callsRequiringReview(source: .app, streamID: "worker-1")
        #expect(review.count == 1 && review.first?.canAcknowledge == true)
        for _ in 0..<2 {
            try await memory.acknowledgeUnresolvedCall(recorder.eventID, source: .app, streamID: "worker-1")
        }
        #expect(try await memory.callsRequiringReview(source: .app, streamID: "worker-1").isEmpty)
        let after = try #require(try await memory.call(recorder.eventID))
        #expect(after.progress.status == before.progress.status)
        #expect(try await memory.perform { try await $0.facts.effect(of: recorder.eventID) }?.performed == .uncertain)
        let facts = try await memory.perform { try await $0.facts.reconciliations(of: recorder.eventID) }
        #expect(facts.count == 1 && facts.first?.kind == .acknowledged && facts.first?.declaredBy == .person)
        await memory.close()
    }

    @Test(arguments: [MemoryEventSource.cli, .app])
    func anotherProducerCannotAcknowledge(_ source: MemoryEventSource) async throws {
        let memory = try W.service()
        let recorder = try await Self.recorder(memory, ended: true)
        await #expect(throws: CallRecoveryError.differentProducer) {
            try await memory.acknowledgeUnresolvedCall(recorder.eventID, source: source, streamID: "other-worker")
        }
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "worker-1", excludingExecutor: nil).count == 1)
        await memory.close()
    }

    @Test func startedCallsNeedConfirmedExecutorTermination() async throws {
        let memory = try W.service()
        let recorder = try await Self.recorder(memory, ended: false)
        let review = try await memory.callsRequiringReview(source: .app, streamID: "worker-1")
        #expect(review.first?.canAcknowledge == false)
        await #expect(throws: CallRecoveryError.stillRunning) {
            try await memory.acknowledgeUnresolvedCall(recorder.eventID, source: .app, streamID: "worker-1")
        }
        // A synthetic termination fact stands for the process-liveness sweep in this isolated archive.
        try await memory.reconcile(CallReconciliation(callEventID: recorder.eventID, kind: .executorTerminated,
            declaredBy: .braus, recordedAtMS: memory.clock.calendarMS()))
        try await memory.acknowledgeUnresolvedCall(recorder.eventID, source: .app, streamID: "worker-1")
        #expect(try await memory.call(recorder.eventID)?.progress.status == .started)
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "worker-1", excludingExecutor: nil).isEmpty)
        await memory.close()
    }

    @Test func knownNonEffectsCannotBeAcknowledgedAsUnresolved() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.appCall(app: "files", verb: "find", arguments: "{}"), app: nil)
        await recorder.notAttempted("synthetic_not_sent")
        try await recorder.end(.failed, result: .error(message: "Synthetic rejection"), tool: .appCall)
        await #expect(throws: CallRecoveryError.notUnresolved) {
            try await memory.acknowledgeUnresolvedCall(recorder.eventID, source: .app, streamID: "worker-1")
        }
        await memory.close()
    }

    @Test func reviewDoesNotCreateAnArchive() async throws {
        let memory = MemoryService(directory: try W.directory())
        #expect(try await memory.callsRequiringReview(source: .app, streamID: "worker-1").isEmpty)
        #expect(!memory.archiveExists)
        await memory.close()
    }

    @Test func personCanAcknowledgeAnUnknownOldExecutorWithoutInventingItsEnd() async throws {
        let memory = try W.service()
        let event = MemoryEventRecord(eventID: "unknown-executor", source: .app, streamID: "worker-1",
            kind: .action, occurredAtMS: memory.clock.calendarMS())
        let record = try AgentCallRecord(event: event, request: .appCall(app: "files", verb: "find", arguments: "{}"))
        let opening = try OperationOpening(call: record, startedAtMS: memory.clock.calendarMS())
        _ = try await memory.perform { try await $0.facts.open(opening) }
        #expect(try await memory.callsRequiringReview(source: .app, streamID: "worker-1").first?.canAcknowledge == true)
        try await memory.acknowledgeUnresolvedCall(event.eventID, source: .app, streamID: "worker-1")
        #expect(try await memory.call(event.eventID)?.progress.status == .started)
        let facts = try await memory.perform { try await $0.facts.reconciliations(of: event.eventID) }
        #expect(facts.count == 1 && facts.first?.kind == .acknowledged)
        await memory.close()
    }
}
