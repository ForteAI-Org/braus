@testable import AutomationRuntime
import Foundation
import Testing
@testable import SQLiteMemory

@Suite("Person episode migration admission", .serialized)
struct DB2DPersonEpisodesTests {
    @Test func nestedEpisodesBalanceAndNeverUnderflow() {
        let initial = MemoryService.PersonEpisodes.anyOpen
        MemoryService.PersonEpisodes.began()
        MemoryService.PersonEpisodes.began()
        #expect(MemoryService.PersonEpisodes.anyOpen)
        MemoryService.PersonEpisodes.ended()
        #expect(MemoryService.PersonEpisodes.anyOpen)
        MemoryService.PersonEpisodes.ended()
        #expect(MemoryService.PersonEpisodes.anyOpen == initial)
        if !initial {
            MemoryService.PersonEpisodes.ended()
            #expect(!MemoryService.PersonEpisodes.anyOpen)
        }
    }

    @Test func statusDoesNotOpenAnArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = MemoryService(directory: directory)
        #expect(await service.status().migrationProgress == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await service.close()
    }

    @Test func serviceWaitsForThePersonEpisodeBeforeMigrating() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("memory.sqlite")
        let source = try SQLiteConnection(path: url.path)
        try source.execute(SQLiteMemorySchema.historical19Text())
        try source.execute("PRAGMA user_version=19")
        source.close()
        let before = try Data(contentsOf: url)
        let service = MemoryService(directory: directory, configuration: .init(reopenInterval: .zero))
        MemoryService.PersonEpisodes.began()
        do {
            defer { MemoryService.PersonEpisodes.ended() }
            await #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) { _ = try await service.ready() }
            #expect(try Data(contentsOf: url) == before)
        }
        let repositories = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await service.ready()
        }
        #expect(try await repositories.store.diagnostics().schemaVersion == 22)
        #expect(await service.status().migrationProgress?.phase == "swapping")
        await service.close()
    }

    @Test func successfulBackupKeepsMigrationSourceAvailableForRollback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationRetention-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("memory.sqlite")
        let source = try SQLiteConnection(path: live.path)
        try source.execute("PRAGMA journal_mode=DELETE")
        try source.execute(SQLiteMemorySchema.historical19Text())
        try source.execute("PRAGMA user_version=19")
        source.close()
        let before = try Data(contentsOf: live)
        let service = MemoryService(directory: directory, configuration: .init(backupInterval: .zero))
        await service.setBackupEnvironment(now: { Date() }, capacity: { _ in Int64.max })
        _ = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await service.ready()
        }
        await service.waitForBackup()
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: live.path + ".migration-22.done"))) as? [String: Any])
        let name = try #require(record["kept"] as? String)
        let kept = directory.appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        await service.close()
        if FileManager.default.fileExists(atPath: kept.path) {
            #expect(try Data(contentsOf: kept) == before)
            try SQLiteMemoryStore.rollBack(at: live, to: name)
            #expect(try Data(contentsOf: live) == before)
        }
    }

}
