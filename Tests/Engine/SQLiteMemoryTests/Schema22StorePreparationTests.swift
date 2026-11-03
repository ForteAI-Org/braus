import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema22 repository store preparation")
struct Schema22StorePreparationTests {
    @Test
    func explicit22StoreBootstrapsAndReopensTheFrozenDDL() async throws {
        let url = try temporaryDatabase("schema22")
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        #expect(try await store.read { try $0.query("PRAGMA user_version") { $0.integer(0) } } == [22])
        #expect(try await store.read { try $0.query("SELECT count(*) FROM sqlite_schema WHERE type='trigger'") { $0.integer(0) } } == [330])
        await store.close()
        try SQLiteMigration22.withSource(at: url) { db throws in
            #expect(try SQLiteMemorySchema.objects(in: db) == SQLiteMemorySchema.objects(of: SQLiteMigration22File.text()))
        }
        let reader = SQLiteMemoryStore(url: url, schema: .version22)
        try await reader.open(.existingArchive)
        #expect(try await reader.read { try $0.query("SELECT to_version FROM memory_schema_migrations") { $0.integer(0) } } == [22])
        await reader.close()
    }

    @Test
    func historicalOpeningRetainsSchemaAndFutureRefusal() async throws {
        let url = try temporaryDatabase("schema19")
        let ordinary = SQLiteMemoryStore(url: url, schema: .historical19)
        try await ordinary.open()
        #expect(try await ordinary.read { try $0.query("PRAGMA user_version") { $0.integer(0) } } == [19])
        await ordinary.close()
        let future = try temporaryDatabase("future22")
        let staged = SQLiteMemoryStore(url: future, schema: .version22)
        try await staged.open()
        await staged.close()
        let before = try Data(contentsOf: future)
        let current = SQLiteMemoryStore(url: future, schema: .historical19)
        await #expect(throws: MemoryStoreError.schema(.future(found: 22, supported: 19))) { try await current.open() }
        await current.close()
        #expect(try Data(contentsOf: future) == before)
    }
}
