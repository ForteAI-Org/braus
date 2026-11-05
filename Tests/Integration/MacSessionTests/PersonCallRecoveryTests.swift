import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SQLiteMemory
import Testing

/// The person-operated recovery API opens the existing write gate without replaying a call or changing its effect.
@MainActor
@Suite(.serialized)
struct PersonCallRecoveryTests {
    @Test(arguments: [SessionProfile.Memory.readLearn, .read, .off])
    func reviewAndAcknowledgeLetsTheWorkerSendANewCall(_ mode: SessionProfile.Memory) async throws {
        let directory = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = ReconciliationTests.RemindersFake()
        let tools = ReconciliationTests.tools(directory, adapter, profile: SessionProfile.app.replacing(memory: mode))
        _ = try await ReconciliationTests.complete(tools, "r-1")
        await #expect(throws: AutomationFailure.self) { _ = try await ReconciliationTests.complete(tools, "r-1") }
        #expect(adapter.completed == 1)
        let memory = MemoryService.shared(for: directory)
        let review = try await memory.callsRequiringReview(source: .app, streamID: "p206")
        let call = try #require(review.first)
        #expect(call.canAcknowledge)
        try await memory.acknowledgeUnresolvedCall(call.id, source: .app, streamID: "p206")
        #expect(adapter.completed == 1, "acknowledging invokes no application")
        #expect(try await memory.perform { try await $0.facts.effect(of: call.id) }?.performed == .uncertain)
        _ = try await ReconciliationTests.complete(tools, "r-1")
        #expect(adapter.completed == 2, "only a subsequent explicit tool call executes another write")
        await memory.close()
    }
}
