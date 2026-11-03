import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 admission")
struct SchemaMigration22AdmissionTests {
    @Test(arguments: [(Int64(1), Int64(2)), (2, 3), (3, 5), (100, 150)])
    func directSpaceThreshold(bytes: Int64, needed: Int64) throws {
        #expect(try SQLiteMigration22.requiredSpace(sourceBytes: bytes, shape: .unified19) == needed)
        #expect(try SQLiteMigration22.requiredSpace(sourceBytes: bytes, shape: .command20) == needed)
        #expect(try SQLiteMigration22.requiredSpace(sourceBytes: bytes, shape: .facts21) == needed)
    }

    @Test(arguments: [(Int64(1), Int64(3)), (2, 5), (3, 8), (100, 250)])
    func historicalSpaceThreshold(bytes: Int64, needed: Int64) throws {
        #expect(try SQLiteMigration22.requiredSpace(sourceBytes: bytes, shape: .historical("main-1")) == needed)
    }

    @Test
    func insufficientSpaceIsTypedAndChangesNothing() throws {
        let url = try source()
        let before = try Data(contentsOf: url)
        let bytes = Int64(before.count)
        let needed = try SQLiteMigration22.requiredSpace(sourceBytes: bytes, shape: .unified19)
        #expect(throws: SQLiteMigration22.Refusal.notEnoughSpace(needed: needed, available: needed - 1)) {
            try SQLiteMigration22.withAdmission(
                from: url,
                shape: .unified19,
                canMigrate: { true },
                availableSpace: { _ in needed - 1 }
            ) { _ in Issue.record("Low space admitted") }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
                == [url.lastPathComponent, url.lastPathComponent + ".lock"].sorted()
        )
        try SQLiteMigration22.withAdmission(
            from: url,
            shape: .unified19,
            canMigrate: { true },
            availableSpace: { _ in needed }
        ) { connection throws in
            #expect(connection.isInTransaction)
            #expect(try connection.query("SELECT value FROM sample") { try $0.text(0) } == ["kept"])
        }
    }

    @Test
    func personEpisodeAndPresenceRefuseBeforeReading() throws {
        let url = try source()
        #expect(throws: SQLiteMigration22.Refusal.personEpisodeOpen) {
            try SQLiteMigration22.withAdmission(
                from: url,
                shape: .unified19,
                canMigrate: { false },
                availableSpace: { _ in
                    Issue.record("Capacity queried during episode")
                    return .max
                }
            ) { _ in Issue.record("Episode admitted") }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path + ".lock"))
        let presence = try #require(try SQLiteMemoryPresence.take(.shared, of: url))
        defer { presence.release() }
        #expect(throws: SQLiteMigration22.Refusal.sourceInUse) {
            try SQLiteMigration22.withAdmission(
                from: url,
                shape: .unified19,
                canMigrate: { true },
                availableSpace: { _ in .max }
            ) { _ in Issue.record("Occupied source admitted") }
        }
    }

    @Test
    func sourceIsReadOnlyIncludingWAL() throws {
        let url = try source(wal: true)
        let files = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let before = try files.map(snapshot)
        #expect(before[1].data.count > 0)
        try SQLiteMigration22.withAdmission(
            from: url,
            shape: .unified19,
            canMigrate: { true },
            availableSpace: { _ in .max }
        ) { connection throws in
            #expect(connection.path.contains("mode=ro"))
            #expect(connection.path.contains("readonly_shm=1"))
            #expect(connection.isInTransaction)
            #expect(try connection.query("SELECT value FROM sample") { try $0.text(0) } == ["kept", "in WAL"])
            #expect(throws: (any Error).self) { try connection.execute("INSERT INTO sample VALUES ('refused')") }
        }
        let after = try files.map(snapshot)
        for index in files.indices {
            #expect(before[index].data == after[index].data)
            #expect(before[index].modified == after[index].modified)
        }
    }

    @Test
    func sourceURIQuotesReservedCharacters() throws {
        let url = try source(name: "archive ?#% é.sqlite")
        try SQLiteMigration22.withAdmission(
            from: url,
            shape: .unified19,
            canMigrate: { true },
            availableSpace: { _ in .max }
        ) { connection throws in
            #expect(try connection.query("SELECT value FROM sample") { try $0.text(0) } == ["kept"])
        }
    }

    @Test
    func capacityProviderErrorsArePreserved() throws {
        struct CapacityFailure: Error, Equatable {}
        let url = try source()
        #expect(throws: CapacityFailure()) {
            try SQLiteMigration22.withAdmission(
                from: url,
                shape: .unified19,
                canMigrate: { true },
                availableSpace: { _ in throw CapacityFailure() }
            ) { _ in Issue.record("Unknown capacity admitted") }
        }
    }

    @Test
    func spaceArithmeticCannotWrap() throws {
        #expect(throws: (any Error).self) {
            try SQLiteMigration22.requiredSpace(sourceBytes: .max, shape: .unified19)
        }
    }

    @Test
    func missingSHMIsRefusedWithoutCreatingIt() throws {
        let url = try source(wal: true)
        let shm = URL(fileURLWithPath: url.path + "-shm")
        let kept = URL(fileURLWithPath: shm.path + ".kept")
        try FileManager.default.moveItem(at: shm, to: kept)
        let before = try Data(contentsOf: url)
        let wal = try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
        #expect(throws: SQLiteMigration22.Refusal.sourceNotReadable) {
            try SQLiteMigration22.withAdmission(
                from: url,
                shape: .unified19,
                canMigrate: { true },
                availableSpace: { _ in .max }
            ) { _ in Issue.record("Missing SHM admitted") }
        }
        #expect(!FileManager.default.fileExists(atPath: shm.path))
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) == wal)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    private func source(name: String = "memory.sqlite", wal: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SchemaMigration22-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(name)
        let db = try SQLiteConnection(path: url.path)
        defer { db.close() }
        try db.disableAutomaticCloseCheckpoint()
        try db.execute("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('kept')")
        if wal {
            try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO sample VALUES ('in WAL')")
        }
        return url
    }

    private func snapshot(_ url: URL) throws -> (data: Data, modified: Date) {
        (
            try Data(contentsOf: url),
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        )
    }
}
