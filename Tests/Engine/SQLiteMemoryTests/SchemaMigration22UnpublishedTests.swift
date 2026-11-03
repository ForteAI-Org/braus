import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 unpublished families")
struct SchemaMigration22UnpublishedTests {
    @Test(arguments: [false, true])
    func invalidRequestRetainsEveryUnpublishedName(_ invalidName: Bool) async throws {
        let (source, target) = try SchemaMigration22CoordinatorTests().makeSource()
        if !invalidName {
            let writer = try SQLiteConnection(path: source.path, mayCreate: false)
            try writer.execute("CREATE TABLE extra(value TEXT) STRICT")
            writer.close()
        }
        let orphan = URL(fileURLWithPath: source.path + ".migrating-22-orphan")
        try Data("unpublished".utf8).write(to: orphan)
        await #expect(throws: (any Error).self) {
            _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
                keepingSourceAs: invalidName ? "../invalid" : source.lastPathComponent + ".schema-19-test",
                availableSpace: { _ in .max }, progress: { _ in })
        }
        #expect(try Data(contentsOf: orphan) == Data("unpublished".utf8))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func completeUnrecordedFamilyMovesToAbandonedAndRetiresThroughRA1() throws {
        let (source, _) = try SchemaMigration22CoordinatorTests().makeSource()
        let orphan = URL(fileURLWithPath: source.path + ".migrating-22-orphan")
        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes { try Data(("kept" + suffix).utf8).write(to: URL(fileURLWithPath: orphan.path + suffix)) }
        let before = try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: orphan.path + $0)) }
        let retained = try SQLiteMigration22.withReservation(
            from: source, shape: .unified19, canMigrate: { true }, availableSpace: { _ in .max }
        ) { try SQLiteMigration22.retainUnpublished(from: source, admission: $0) }
        let abandoned = URL(fileURLWithPath: orphan.path + ".abandoned")
        #expect(retained == [abandoned])
        #expect(try suffixes.map { try Data(contentsOf: URL(fileURLWithPath: abandoned.path + $0)) } == before)
        let retirement = try SQLiteArchiveRetirement.retire(abandoned, into: source.deletingLastPathComponent().appendingPathComponent(".retired"))
        #expect(retirement.state == .retired)
        #expect(retirement.memberCount == 4)
    }

    @Test
    func allAbandonedDestinationsAreCheckedBeforeAnyRename() throws {
        let (source, _) = try SchemaMigration22CoordinatorTests().makeSource()
        let bases = ["a", "z"].map { URL(fileURLWithPath: source.path + ".migrating-22-" + $0) }
        for url in bases { try Data("kept".utf8).write(to: url) }
        let occupied = URL(fileURLWithPath: bases[1].path + ".abandoned-shm")
        try Data("occupied".utf8).write(to: occupied)
        #expect(throws: SQLiteMigration22.Refusal.nameTaken(occupied.lastPathComponent)) {
            try SQLiteMigration22.withReservation(
                from: source, shape: .unified19, canMigrate: { true }, availableSpace: { _ in .max }
            ) { try SQLiteMigration22.retainUnpublished(from: source, admission: $0) }
        }
        for url in bases { #expect(try Data(contentsOf: url) == Data("kept".utf8)) }
        #expect(try Data(contentsOf: occupied) == Data("occupied".utf8))
    }

    @Test
    func nextMigrationRetainsAnEarlierUnrecordedBuild() async throws {
        let (source, target) = try SchemaMigration22CoordinatorTests().makeSource()
        let orphan = URL(fileURLWithPath: source.path + ".migrating-22-orphan")
        try Data("unpublished".utf8).write(to: orphan)
        _ = try await SQLiteMigration22.migrate(from: source, shape: .unified19, into: target,
            keepingSourceAs: source.lastPathComponent + ".schema-19-test", availableSpace: { _ in .max }, progress: { _ in })
        #expect(try Data(contentsOf: URL(fileURLWithPath: orphan.path + ".abandoned")) == Data("unpublished".utf8))
        try SQLiteMigration22.withSource(at: source) { db throws in
            #expect(try db.query("PRAGMA user_version") { $0.integer(0) } == [22])
        }
    }
}
