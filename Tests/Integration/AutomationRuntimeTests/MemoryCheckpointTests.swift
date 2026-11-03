import AutomationRuntime
import Foundation
@testable import SQLiteMemory
import Testing

@Suite("Memory checkpoints during queue pauses")
struct MemoryCheckpointTests {
    @Test func partialCheckpointRearmsPause() async throws {
        let service = try W.service(.init(store: .init(checkpointFrames: 1)))
        let repositories = try await service.ready()
        _ = try await repositories.store.checkpoint()
        let reader = try SQLiteConnection(path: repositories.store.url.path, readOnly: true)
        defer { reader.close() }
        try reader.execute("BEGIN")
        _ = try reader.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }
        await service.enqueue("checkpoint input") { repositories in
            _ = try await repositories.store.write {
                try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('held.app')")
            }
        }
        #expect(await service.flush(within: .seconds(10)))
        let firstDeadline = ContinuousClock.now + .seconds(8)
        while try await repositories.store.diagnostics().pauseCheckpoints == 0,
              ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let partial = try await repositories.store.diagnostics()
        #expect(partial.pauseCheckpoints >= 1)
        #expect(partial.residualWALFrames > 1)
        try reader.execute("COMMIT")
        reader.close()
        let nextDeadline = ContinuousClock.now + .seconds(8)
        while try await repositories.store.diagnostics().residualWALFrames > 1,
              ContinuousClock.now < nextDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = try await repositories.store.diagnostics()
        #expect(completed.pauseCheckpoints >= 2)
        #expect(completed.residualWALFrames == 0)
        await service.close()
    }

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
