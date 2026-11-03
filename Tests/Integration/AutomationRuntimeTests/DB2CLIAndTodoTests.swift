import Foundation
import Memory
import Testing
@testable import SQLiteMemory
@testable import AutomationRuntime

struct DB2CLIAndTodoTests {
    @Test func producerPolicyRefuses19AndMigrationEnablesTodos() async throws {
        let memory = try W.service()
        let old = SQLiteMemoryStore(url: memory.url, schema: .historical19)
        try await old.open()
        await old.close()
        let before = try Data(contentsOf: memory.url)
        try await memory.setMigrationPolicy(.onlyWithFlag(false))
        await #expect(throws: (any Error).self) {
            try await memory.perform { try await $0.todos.requireAvailable() }
        }
        #expect(try Data(contentsOf: memory.url) == before)
        #expect(MemoryService.describe(MemoryStoreError.schema(.migrationRequired(found: 19, supported: 22)))
            .contains("memory --migrate"))
        await memory.close()
        let migrated = MemoryService(directory: memory.directory, configuration: .init(migrationPolicy: .onlyWithFlag(true)))
        try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await migrated.perform { try await $0.todos.requireAvailable() }
        }
        #expect(try await migrated.perform { try await $0.store.diagnostics().schemaVersion } == 22)
        await migrated.close()
    }

    @Test func cliSelectsPolicyBeforeDispatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Tools/Engine/braus/main.swift"), encoding: .utf8)
        let policy = try #require(source.range(of: "setMigrationPolicy(.onlyWithFlag(false))"))
        let dispatch = try #require(source.range(of: "switch command"))
        #expect(policy.lowerBound < dispatch.lowerBound)
    }
}
