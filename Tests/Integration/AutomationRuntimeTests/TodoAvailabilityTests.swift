import AutomationRuntime
import Memory
import Testing
@testable import SQLiteMemory

struct TodoAvailabilityTests {
    @Test func activeSchemaSupportsTodoWithoutAddingTables() async throws {
        let memory = try W.service()
        try await memory.perform { try await $0.todos.requireAvailable() }
        let version = try await memory.perform { repositories in
            try await repositories.store.read {
                try $0.query("PRAGMA user_version") { $0.integer(0) }.first ?? nil
            }
        }
        #expect(version == 22)
        await memory.close()
    }
}
