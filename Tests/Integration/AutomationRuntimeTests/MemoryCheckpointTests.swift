import AutomationRuntime
import Foundation
@testable import SQLiteMemory
import Testing

@Suite("Memory checkpoints during queue pauses")
struct MemoryCheckpointTests {
    @Test func checkpointOnlyAfterTwoSecondsOfEmptyQueue() async throws {
        let service = try W.service(.init(store: .init(checkpointFrames: 1, forcedCheckpointFrames: 16000)))
        let repositories = try await service.ready()
        _ = try await repositories.store.checkpoint()
        await service.enqueue("checkpoint input") { repositories in
            try await repositories.store.write {
                try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('first.app')")
            }
        }
        #expect(await service.flush(within: .seconds(10)))
        let initial = try await repositories.store.diagnostics().checkpoints
        try await Task.sleep(for: .milliseconds(1100))
        #expect(try await repositories.store.diagnostics().checkpoints == initial)
        await service.enqueue("checkpoint input") { repositories in
            try await repositories.store.write {
                try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('second.app')")
            }
        }
        #expect(await service.flush(within: .seconds(10)))
        try await Task.sleep(for: .milliseconds(1100))
        #expect(try await repositories.store.diagnostics().checkpoints == initial)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await repositories.store.diagnostics().pauseCheckpoints == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let paused = try await repositories.store.diagnostics()
        #expect(paused.pauseCheckpoints == 1)
        #expect(paused.checkpoints == initial + 1)
        #expect(paused.residualWALFrames == 0)
        await service.close()
    }
}
