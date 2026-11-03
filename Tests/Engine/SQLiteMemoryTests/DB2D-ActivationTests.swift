import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Schema 22 activation", .serialized)
struct DB2DActivationTests {
    private func source() throws -> URL {
        let url = try temporaryDatabase("activation")
        let db = try SQLiteConnection(path: url.path)
        defer { db.close() }
        try db.execute(SQLiteMemorySchema.historical19Text())
        try db.execute("PRAGMA user_version=19")
        return url
    }

    @Test func newStoresUse22() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase("active22"))
        #expect(try await store.read { try $0.query("PRAGMA user_version") { $0.integer(0) } } == [22])
        await store.close()
    }

    @Test func cliNeedsMigrateFlag() async throws {
        let url = try source()
        let before = try Data(contentsOf: url)
        for policy: MigrationPolicy in [.never, .onlyWithFlag(false)] {
            let store = SQLiteMemoryStore(url: url, migrationPolicy: policy)
            await #expect(throws: MemoryStoreError.schema(.migrationRequired(found: 19, supported: 22))) {
                try await store.open()
            }
            await store.close()
            #expect(try Data(contentsOf: url) == before)
        }
        let store = SQLiteMemoryStore(url: url, migrationPolicy: .onlyWithFlag(true))
        try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await store.open()
        }
        #expect(try await store.diagnostics().schemaVersion == 22)
        let copy = try #require(try await store.diagnostics().migration?.copyName)
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(copy)) == before)
        #expect(store.migrationProgress?.phase == "swapping")
        await store.close()
        try SQLiteMemoryStore.rollBack(at: url, to: copy)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func personEpisodePreventsMigration() async throws {
        let url = try source()
        let before = try Data(contentsOf: url)
        let store = SQLiteMemoryStore(url: url, canMigrate: { false })
        await #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) { try await store.open() }
        await store.close()
        #expect(try Data(contentsOf: url) == before)
        let allowed = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await SQLiteMemoryStore.open(at: url)
        }
        #expect(try await allowed.diagnostics().schemaVersion == 22)
        await allowed.close()
    }

    @Test func oldVersionGuardRefuses22WithoutWriting() async throws {
        let url = try temporaryDatabase("oldGuard")
        try SQLiteMigration22File.create(at: url) { _ in } verify: { _ in }
        let before = try Data(contentsOf: url)
        let old = SQLiteMemoryStore(url: url, schema: .historical19)
        await #expect(throws: MemoryStoreError.schema(.future(found: 22, supported: 19))) { try await old.open() }
        await old.close()
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func readerNeverMigratesEvenWithAutomaticPolicy() async throws {
        let url = try source()
        let before = try Data(contentsOf: url)
        let store = SQLiteMemoryStore(url: url)
        await #expect(throws: MemoryStoreError.schema(.migrationRequired(found: 19, supported: 22))) {
            try await store.open(.existingArchive)
        }
        await store.close()
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func refusalKeepsCommittedWALAndSharedMemoryUnchanged() async throws {
        let url = try source()
        let writer = try SQLiteConnection(path: url.path, mayCreate: false)
        defer { writer.close() }
        try writer.disableAutomaticCloseCheckpoint()
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try writer.execute("""
            INSERT INTO memory_schema_migrations(to_version,from_version,migrated_at_ms,copy_name)
            VALUES(19,0,1,NULL)
            """)
        writer.close()
        let family = ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
        let bytes = try family.map { try Data(contentsOf: $0) }
        let dates = try family.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        #expect(bytes[1].count > 32)
        let store = SQLiteMemoryStore(url: url, migrationPolicy: .onlyWithFlag(false))
        await #expect(throws: MemoryStoreError.schema(.migrationRequired(found: 19, supported: 22))) {
            try await store.open()
        }
        await store.close()
        #expect(try family.map { try Data(contentsOf: $0) } == bytes)
        #expect(try family.map {
            try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } == dates)
    }


    @Test func modifiedSourceIsRefusedBeforeCreatingAConversion() async throws {
        let url = try source()
        let db = try SQLiteConnection(path: url.path, mayCreate: false)
        try db.execute("CREATE TABLE extra(value TEXT) STRICT")
        db.close()
        let before = try Data(contentsOf: url)
        let store = SQLiteMemoryStore(url: url)
        do {
            try await store.open()
            Issue.record("A changed source was accepted")
        } catch let error as MemoryStoreError {
            guard case .schema(.differentShape) = error else { throw error }
        }
        await store.close()
        #expect(try Data(contentsOf: url) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains("migrating-22") || $0.contains("migration-work-22") })
    }


    @Test func corruptOpeningKeepsTheHistoricalErrorClassification() async throws {
        let url = try temporaryDatabase("invalid")
        let before = Data(repeating: 0x5A, count: 8192)
        try before.write(to: url)
        let store = SQLiteMemoryStore(url: url)
        let error = await storeError { try await store.open() }
        if case .open(let fault)? = error { #expect(fault.code.primary == 26) }
        else { Issue.record("The historical open error classification changed") }
        await store.close()
        #expect(try Data(contentsOf: url) == before)
    }

}
