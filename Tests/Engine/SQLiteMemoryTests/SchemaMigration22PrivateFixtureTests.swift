import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 supplied private fixtures")
struct SchemaMigration22PrivateFixtureTests {
    @Test
    func migratesCommand20() throws {
        try convert(name: "command-20", shape: .command20) { db throws in
            let kinds = try db.query("SELECT step_kind FROM memory_candidate_steps") { try $0.text(0) }
            #expect(kinds.contains("capability_call"))
            let calls = try db.query("SELECT capability_id,origin,channel,effect_class FROM memory_call_capabilities") {
                [try $0.text(0),try $0.text(1),try $0.text(2),try $0.text(3)]
            }
            #expect(!calls.isEmpty)
            #expect(calls.allSatisfy { $0[0]?.isEmpty == false && $0[1] == "registered" && $0[2] == "command" && $0[3] != nil })
            #expect(try db.query("SELECT count(*) FROM memory_step_capabilities") { $0.integer(0) }.first != 0)
            #expect(try db.query("SELECT count(*) FROM memory_parameter_bindings") { $0.integer(0) }.first != 0)
            #expect(try db.query("SELECT count(*) FROM memory_operation_verifications WHERE condition_kind='state_read_back'") {
                $0.integer(0)
            }.first != 0)
        }
    }

    @Test
    func migratesFacts21() throws {
        try convert(name: "facts-21", shape: .facts21) { db throws in
            #expect(try db.query("SELECT name FROM sqlite_schema WHERE name='memory_learned_facts'") { try $0.text(0) }.isEmpty)
            #expect(try db.query("SELECT capability_id FROM memory_call_capabilities") { try $0.text(0) } == ["fixture.rename"])
            #expect(try db.query("SELECT step_kind FROM memory_candidate_steps") { try $0.text(0) } == ["capability_call"])
        }
    }

    private func convert(
        name: String,
        shape: SQLiteMigration22.SourceShape,
        verify: (SQLiteConnection) throws -> Void
    ) throws {
        let source = try makeSource(name: name)
        let directory = source.deletingLastPathComponent()
        let target = directory.appendingPathComponent("built.sqlite")
        let before = try Data(contentsOf: source)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SQLiteMigration22.withSource(at: source) { old in
            try SQLiteMigration22Normalization.withSource(old, shape: shape, workingAt: directory.appendingPathComponent("work")) { normalized in
                try SQLiteMigration22File.create(at: target) { db in
                    _ = try SQLiteMigration22Rows.copy(from: normalized, into: db, at: 0)
                } verify: { db throws in
                    try verify(db)
                    #expect(try SchemaCoherence.check(db).isEmpty)
                }
            }
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test(arguments: [20, 21])
    func coordinatorPreservesSourceCountsAndRollback(version: Int) async throws {
        let name = version == 20 ? "command-20" : "facts-21"
        let shape: SQLiteMigration22.SourceShape = version == 20 ? .command20 : .facts21
        let source = try makeSource(name: name, command: "Standalone")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: source)
        let copy = source.lastPathComponent + ".schema-" + name + "-fixture"
        let report = try await SQLiteMigration22.migrate(from: source, shape: shape,
            into: URL(fileURLWithPath: source.path + ".migrating-22-fixture"), keepingSourceAs: copy,
            availableSpace: { _ in .max }, progress: { _ in })
        #expect(report.commandStepsConverted == 1)
        #expect(report.personFactsLeftInSource == (version == 21 ? 1 : 0))
        #expect(try Data(contentsOf: directory.appendingPathComponent(copy)) == before)
        try SQLiteMigration22.withSource(at: source) { db throws in
            #expect(try db.query("SELECT origin_name FROM memory_call_capabilities") { try $0.text(0) } == ["Standalone"])
            #expect(try SchemaCoherence.check(db).isEmpty)
        }
        try SQLiteMigration22.rollBack(live: source, to: copy, stamp: "fixture")
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("migration-work") })
    }

    @Test(arguments: [20, 21])
    func activationRecognizesOnlyExactFixture(version: Int) async throws {
        let source = try makeSource(name: version == 20 ? "command-20" : "facts-21")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source)
        let denied = SQLiteMemoryStore(url: source, migrationPolicy: .never)
        await #expect(throws: MemoryStoreError.schema(.migrationRequired(found: Int32(version), supported: 22))) {
            try await denied.open()
        }
        await denied.close()
        #expect(try Data(contentsOf: source) == before)
        let allowed = SQLiteMemoryStore(url: source, migrationPolicy: .onlyWithFlag(true))
        try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in .max }) { try await allowed.open() }
        #expect(try await allowed.diagnostics().schemaVersion == 22)
        await allowed.close()
    }

    @Test(arguments: [20, 21])
    func missingCommandIdentifierIsRefusedWithoutChangingSource(version: Int) async throws {
        let source = try makeSource(name: version == 20 ? "command-20" : "facts-21", command: "")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: source)
        await #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["command identifier"])) {
            _ = try await SQLiteMigration22.migrate(from: source, shape: version == 20 ? .command20 : .facts21,
                into: URL(fileURLWithPath: source.path + ".migrating-22-fixture"), keepingSourceAs: "source.sqlite.schema-refused", availableSpace: { _ in .max }, progress: { _ in })
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: source.path + ".migration-22"))
    }

    private func makeSource(name: String, command: String = "fixture.rename") throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Integration/AutomationRuntimeTests/Fixtures")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Schema22Supplied-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("source.sqlite")
        do {
            let writer = try SQLiteConnection(path: source.path)
            defer { writer.close() }
            for prefix in ["schema-", "rows-"] {
                let text = try String(contentsOf: fixtures.appendingPathComponent(prefix + name + ".sql"), encoding: .utf8)
                try writer.execute(prefix == "rows-" ? text.replacingOccurrences(of: "fixture.rename", with: command) : text)
            }
        }
        return source
    }
}
