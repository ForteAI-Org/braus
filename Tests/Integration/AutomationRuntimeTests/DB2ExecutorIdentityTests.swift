import Foundation
import Memory
import Testing
import SQLiteMemory
@testable import AutomationRuntime

@Suite(.serialized)
struct DB2ExecutorIdentityTests {
    @Test func lockUsesTheStoredIdentity() async throws {
        let memory = try W.service()
        async let first = MemoryExecutor.current(memory: memory, source: .app)
        async let second = MemoryExecutor.current(memory: memory, source: .app)
        let (offered, other) = try await (first, second)
        let executor = try #require(offered)
        #expect(other?.record == executor.record)
        #expect(Int64(executor.record.executorID) != nil)
        #expect(MemoryExecutor.isRunning(executor.record.executorID, in: memory.directory) == true)
        let ids = try await memory.perform { repositories in
            try await repositories.store.read {
                try $0.query("SELECT executor_id FROM memory_executors") { try $0.text(0) }
            }
        }
        #expect(ids == [executor.record.executorID])
        let again = try #require(try await MemoryExecutor.current(memory: memory, source: .app))
        #expect(again.record == executor.record)
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: nil)
        let started = try await memory.perform { try await $0.facts.startedCalls(excludingExecutor: "0") }
        #expect(started.map(\.executorID) == [executor.record.executorID])
        #expect(try await memory.perform { try await $0.facts.startedCalls(excludingExecutor: executor.record.executorID) }.isEmpty)
        #expect(await MemoryExecutor.sweep(memory, folder: memory.directory, current: executor).isEmpty)
        try await recorder.end(.completed, result: nil, tool: .observe)
        await memory.close()
    }
}
