//
//  HistoricalArchiveTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import CryptoKit
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// HistoricalArchiveTests prove the migration of the archives two earlier builds made (R63): `main-1`, schema 1 as main
/// shipped it before the value change, and `d3-7`, version 7 of the D3 build the live run R01 used. The shapes come from the
/// exact texts those builds ran (`Fixtures/schema-main-1.sql` from f44fb67, `Fixtures/schema-d3-7.sql` from 7ee2552;
/// since 13 October 2026 their first comment line names the product as Braus, their SQL objects untouched), never from
/// the current text. The rows come from the product's producers: a task learned through the tools on the
/// current schema is brought to the historical shape by rebuilding the tables that text writes otherwise and dropping what
/// it lacks, and the result is checked equal, object for object, to the historical text's. Then the product opens it.
@MainActor
@Suite("Archives of earlier builds: recognized exactly, migrated whole, refused otherwise", .serialized)
struct HistoricalArchiveTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    /// A historical text of the fixtures, with the sha256 of the file its commit holds.
    static func text(_ name: String, sha256: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sql"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256, "\(name) is not the commit's text")
        return String(decoding: data, as: UTF8.self)
    }

    static func mainOne() throws -> String {
        try text("schema-main-1", sha256: "a073430d7f6292fe21794a09422190b48e0c64ba869fa6e60bae86e8aceecd0c")
    }

    static func renameAppSeven() throws -> String {
        try text("schema-rename-app-7", sha256: "6018958381a1ac8b913bad090c0204a655fc1024615009fc629efae1b029aa8e")
    }

    static func dThreeSeven() throws -> String {
        try text("schema-d3-7", sha256: "f899eb33bc4184c2e676fd40773f2ddf6c99d274a06c2350d0fc620130b92bac")
    }

    /// The digest this build recognizes a historical shape by.
    static func digest(_ name: String) -> String {
        SQLiteMemorySchema.historicalShapes.first { $0.name == name }?.digest ?? "no shape \(name)"
    }

    /// Brings a closed archive of the current schema to the shape `text` creates at `version`: what the text lacks is
    /// dropped, each table it writes otherwise is rebuilt under its statement with the columns both have, the indexes and
    /// triggers it writes are written again. Answers the digest of the result's objects.
    static func convert(_ url: URL, to text: String, version: Int32) throws -> String {
        let target = try SQLiteMemorySchema.orderedObjects(of: text)
        let wanted = Dictionary(uniqueKeysWithValues: target.map { ("\($0.type)|\($0.name)", $0) })
        let connection = try SQLiteConnection(path: url.path)
        defer { connection.close() }
        try connection.execute("PRAGMA foreign_keys = OFF")
        try connection.execute("PRAGMA legacy_alter_table = ON")
        try connection.execute("BEGIN IMMEDIATE")
        let found = try connection.query("SELECT type, name, sql, tbl_name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY rowid") {
            (type: try $0.text(0) ?? "", name: try $0.text(1) ?? "", sql: try $0.text(2), table: try $0.text(3) ?? "")
        }
        let dropped = found.filter { $0.type == "table" && wanted["table|\($0.name)"] == nil }.map(\.name)
        let rebuilt = found.filter { $0.type == "table" && wanted["table|\($0.name)"] != nil && wanted["table|\($0.name)"]?.sql != $0.sql }.map(\.name)
        for item in found where item.type != "table" {
            if wanted["\(item.type)|\(item.name)"]?.sql == item.sql, !dropped.contains(item.table), !rebuilt.contains(item.table) { continue }
            try connection.execute("DROP \(item.type == "index" ? "INDEX" : "TRIGGER") \(item.name)")
        }
        for table in dropped.reversed() { try connection.execute("DROP TABLE \(table)") }
        for table in rebuilt {
            try connection.execute("ALTER TABLE \(table) RENAME TO \(table)__current")
            try connection.execute(wanted["table|\(table)"]?.sql ?? "")
            let kept = try connection.query("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" }
            let list = kept.joined(separator: ", ")
            try connection.execute("INSERT INTO \(table) (\(list)) SELECT \(list) FROM \(table)__current")
            try connection.execute("DROP TABLE \(table)__current")
        }
        let present = Set(try connection.query("SELECT type || '|' || name FROM sqlite_schema") { try $0.text(0) ?? "" })
        for object in target where object.type != "table" && !present.contains("\(object.type)|\(object.name)") {
            try connection.execute(object.sql ?? "")
        }
        // The record of the archive's bootstrap names the version that bootstrapped it, as the earlier build wrote it.
        if present.contains("table|memory_schema_migrations") {
            try connection.execute("UPDATE memory_schema_migrations SET to_version = \(version) WHERE from_version = 0")
        }
        try connection.execute("PRAGMA user_version = \(version)")
        try connection.execute("COMMIT")
        try connection.execute("PRAGMA foreign_keys = ON")
        #expect(try connection.query("PRAGMA foreign_key_check") { try $0.text(0) ?? "" }.isEmpty, "the fixture keeps every reference")
        return SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: connection))
    }

    /// Every row of every table of the archive's shape, by the columns `text` gives each table, in a stable order: what a
    /// migration must keep.
    static func rows(_ url: URL, columnsOf text: String) throws -> [String: [String]] {
        let scratch = try SQLiteConnection(path: ":memory:")
        defer { scratch.close() }
        try scratch.execute(text)
        let tables = try scratch.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") { try $0.text(0) ?? "" }
        var columns: [String: [String]] = [:]
        for table in tables { columns[table] = try scratch.query("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" } }
        let connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
        defer { connection.close() }
        var rows: [String: [String]] = [:]
        for (table, list) in columns {
            let quoted = list.map { "quote(\($0))" }.joined(separator: " || ',' || ")
            rows[table] = try connection.query("SELECT \(quoted) FROM \(table) ORDER BY \(list.joined(separator: ", "))") { try $0.text(0) ?? "" }
        }
        return rows
    }

    /// Learns the photo export through the tools on the current schema, closes the archive and answers its file.
    static func learned() async throws -> (LearningSession, URL, String) {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        await L.close(session)
        return (session, L.url(session), routeID)
    }

    // MARK: The shapes

    @Test("the historical texts are the commits' own, and each shape this build recognizes is the digest of one of them")
    func shapesPinned() throws {
        let main = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(of: try Self.mainOne()))
        let d3 = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(of: try Self.dThreeSeven()))
        let renameApp = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(of: try Self.renameAppSeven()))
        #expect(main == Self.digest("main-1") && d3 == Self.digest("d3-7") && renameApp == Self.digest("rename-app-7"))
        let current = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(of: try SQLiteMemorySchema.text()))
        let partOne = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(of: try SQLiteMemorySchema.text(of: 1)))
        #expect(Set([main, d3, renameApp, current, partOne]).count == 5, "five distinct shapes")
    }

    // MARK: Migrations

    @Test("an archive of the D3 build (d3-7, as R01's) migrates whole: every row kept, the new fields unknown, its copy beside it at d3-7, and the Recall proposes its procedure again")
    func dThreeSevenMigrates() async throws {
        let (session, url, routeID) = try await Self.learned()
        let text = try Self.dThreeSeven()
        #expect(try Self.convert(url, to: text, version: 7) == Self.digest("d3-7"), "the fixture is exactly d3-7")
        let before = try Self.rows(url, columnsOf: text)
        #expect((before["brain_transitions"]?.count ?? 0) > 0 && (before["memory_agent_actions"]?.count ?? 0) > 0)
        #expect((before["brain_relations"]?.count ?? 0) > 0 && (before["memory_procedure_versions"]?.count ?? 0) == 1)

        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let status = await memory.status()
        _ = try await memory.perform { try await $0.procedures.version(routeID) }
        let migrated = await memory.status()
        #expect(migrated.lastMigration?.contains("from schema d3-7 to 8") == true, "\(String(describing: migrated.lastMigration)) \(status)")
        #expect(await memory.flush(within: .seconds(10)))
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        await memory.close()
        MemoryService.forget(session.directory)

        let after = try Self.rows(url, columnsOf: text)
        for (table, kept) in before where table != "memory_schema_migrations" && !table.hasPrefix("memory_recall_") {
            #expect(after[table] == kept, "\(table) keeps its rows")
        }
        #expect(try rawRows("SELECT count(*) FROM brain_transitions WHERE effect_label IS NOT NULL OR effect_value IS NOT NULL", at: url) == ["0"])
        #expect(try rawRows("SELECT count(*) FROM memory_agent_actions WHERE observed_effect_label IS NOT NULL", at: url) == ["0"])
        let records = try rawRows("SELECT from_version || ':' || to_version || ':' || ifnull(copy_name, '') FROM memory_schema_migrations ORDER BY to_version", at: url)
        #expect(records.count == 2 && records.first == "0:7:" && records.last?.hasPrefix("7:8:memory.sqlite.schema-d3-7-") == true,
                "the bootstrap of the D3 build, then this migration with its copy: \(records)")
        let copies = try FileManager.default.contentsOfDirectory(atPath: session.directory.path).filter { $0.hasPrefix("memory.sqlite.schema-d3-7-") && !$0.contains("-wal") && !$0.contains("-shm") }
        #expect(copies.count == 1)
        let copy = session.directory.appendingPathComponent(copies.first ?? "none")
        let connection = try SQLiteConnection(path: copy.path, readOnly: true, mayCreate: false)
        #expect(SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: connection)) == Self.digest("d3-7"),
                "the way back to the earlier build")
        connection.close()
        #expect(try rawRows("PRAGMA foreign_key_check", at: url).isEmpty && rawRows("PRAGMA integrity_check", at: url) == ["ok"])

        // Usable: the Recall proposes the migrated procedure to a new task.
        let reopened = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: reopened, configuration: L.configuration()))
        #expect(await RecallService.shared(for: reopened).waitUntilIdle(within: .seconds(60)))
        let proposal = try await P.task(P.tools(session, stream: "after-migration"), RecallChoiceToolTests.proposeRequest)["recall_proposal"]
        #expect(proposal["sources"].array?.contains { $0["version"].string == routeID } == true, "\(proposal)")
        await L.close(session)
    }

    @Test("an archive of main before the value change (main-1) migrates whole: its facts and Brain kept, the scene shapes and label keys derived, and it learns again")
    func mainOneMigrates() async throws {
        let (session, url, _) = try await Self.learned()
        let text = try Self.mainOne()
        #expect(try Self.convert(url, to: text, version: 1) == Self.digest("main-1"), "the fixture is exactly main-1")
        let before = try Self.rows(url, columnsOf: text)
        #expect((before["memory_events"]?.count ?? 0) > 0 && (before["brain_transitions"]?.count ?? 0) > 0)

        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session, stream: "after-main")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Rotate the photo again","recall":false}"#)
        #expect(begun["status"].string == "begun", "\(begun)")
        #expect((await memory.status()).lastMigration?.contains("from schema main-1 to 8") == true)
        _ = try await P.task(tools, #"{"operation":"end","outcome":"abandoned"}"#)
        #expect(await memory.flush(within: .seconds(10)))
        await L.close(session)

        let after = try Self.rows(url, columnsOf: text)
        for (table, kept) in before {
            // The new task wrote its own facts after the migration: the earlier rows are all still there, unchanged; the
            // Brain, which no app action of it touched, is exactly as it was.
            #expect(Set(kept).isSubset(of: Set(after[table] ?? [])), "\(table) keeps its rows")
            if table.hasPrefix("brain_") { #expect(after[table] == kept, "\(table) is unchanged") }
        }
        #expect(try rawRows("SELECT count(*) > 0 FROM brain_anchor_label_keys", at: url) == ["1"], "derived in the migration")
        #expect(try rawRows("SELECT (SELECT count(*) FROM brain_scene_shapes) = (SELECT count(*) FROM brain_scenes WHERE scene_kind <> 'app')", at: url) == ["1"])
        #expect(try rawRows("SELECT from_version || ':' || to_version FROM memory_schema_migrations", at: url) == ["1:8"])
        #expect(try rawRows("PRAGMA foreign_key_check", at: url).isEmpty)
    }

    @Test("a migration that fails rolls back whole: the archive stays exactly d3-7 with every row, its copy beside it, and the next open migrates it")
    func failedMigrationRollsBack() async throws {
        let (_, url, _) = try await Self.learned()
        let text = try Self.dThreeSeven()
        _ = try Self.convert(url, to: text, version: 7)
        let before = try Self.rows(url, columnsOf: text)
        let store = SQLiteMemoryStore(url: url)
        await store.injectMigrationFault { throw MemoryStoreError.unavailable(.closed) }
        await #expect(throws: (any Error).self) { try await store.open() }
        await store.close()
        let connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
        #expect(SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: connection)) == Self.digest("d3-7"))
        #expect(try connection.query("PRAGMA user_version") { $0.integer(0) ?? 0 } == [7])
        connection.close()
        #expect(try Self.rows(url, columnsOf: text) == before, "nothing of the failed migration stays")

        let again = try await SQLiteMemoryStore.open(at: url)
        #expect(try await again.diagnostics().migration?.fromShape == "d3-7")
        await again.close()
    }

    @Test("two producers opening one d3-7 archive at once: one migrates, the other finds it current; one migration is recorded")
    func concurrentOpens() async throws {
        let (_, url, _) = try await Self.learned()
        _ = try Self.convert(url, to: try Self.dThreeSeven(), version: 7)
        async let first = SQLiteMemoryStore.open(at: url)
        async let second = SQLiteMemoryStore.open(at: url)
        let stores = try await [first, second]
        var migrations = 0
        for store in stores {
            if try await store.diagnostics().migration != nil { migrations += 1 }
            await store.close()
        }
        #expect(migrations == 1)
        #expect(try rawRows("SELECT count(*) FROM memory_schema_migrations WHERE from_version = 7 AND to_version = 8", at: url) == ["1"])
    }

    @Test("an archive of version 7 as rename-app wrote it since the merge (rename-app-7) migrates whole: every row, its origins table rebuilt, its copy beside it")
    func renameAppSevenMigrates() async throws {
        let (_, url, _) = try await Self.learned()
        let text = try Self.renameAppSeven()
        #expect(try Self.convert(url, to: text, version: 7) == Self.digest("rename-app-7"), "the fixture is exactly rename-app-7")
        let before = try Self.rows(url, columnsOf: text)
        let store = try await SQLiteMemoryStore.open(at: url)
        let migration = try await store.diagnostics().migration
        #expect(migration?.fromVersion == 7 && migration?.toVersion == 8 && migration?.fromShape == "rename-app-7", "\(String(describing: migration))")
        await store.close()
        let after = try Self.rows(url, columnsOf: text)
        for (table, kept) in before where !["memory_schema_migrations", "memory_recall_work"].contains(table) {
            #expect(after[table] == kept, "\(table) is unchanged")
        }
        #expect(try rawRows("SELECT from_version || ':' || to_version FROM memory_schema_migrations ORDER BY to_version", at: url) == ["0:7", "7:8"])
        #expect(try rawRows("PRAGMA foreign_key_check", at: url).isEmpty)
    }

    /// Real archives of earlier builds, copied with their logs into a fresh folder and opened by the product: what each
    /// keeps, what each is refused for. `BRAUS_HISTORICAL_ARCHIVES` names a folder of `<label>/memory.sqlite` copies, made
    /// read-only by the caller; nothing is written there. The answers go to `BRAUS_HISTORICAL_OUT` (a new folder).
    nonisolated static var realArchives: URL? {
        ProcessInfo.processInfo.environment["BRAUS_HISTORICAL_ARCHIVES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @Test("real archives of earlier builds, opened by the product on copies: each migrated with every row, or refused untouched",
          .enabled(if: realArchives != nil, "BRAUS_HISTORICAL_ARCHIVES names no folder of copied archives"))
    func realArchivesMigrate() async throws {
        let source = try #require(Self.realArchives)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRAUS_HISTORICAL_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String: JSONValue] = [:]
        for label in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
            let original = source.appendingPathComponent(label).appendingPathComponent("memory.sqlite")
            guard FileManager.default.fileExists(atPath: original.path) else { continue }
            let folder = try W.directory()
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: original.path + suffix) {
                let copy = folder.appendingPathComponent("memory.sqlite" + suffix).path
                try FileManager.default.copyItem(atPath: original.path + suffix, toPath: copy)
                // The originals are read-only; the copy is the product's to open.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy)
            }
            let url = folder.appendingPathComponent("memory.sqlite")
            let probe = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
            let version = try probe.query("PRAGMA user_version") { $0.integer(0) ?? 0 }.first ?? 0
            let digest = SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: probe))
            let tables = try probe.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") { try $0.text(0) ?? "" }
            var counts: [String: Int] = [:]
            for table in tables { counts[table] = Int(try probe.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0) }
            probe.close()
            let known = SQLiteMemorySchema.historicalShapes.first { $0.digest == digest }?.name
            let text = known == "main-1" ? try Self.mainOne() : known == "d3-7" ? try Self.dThreeSeven()
                : known == "rename-app-7" ? try Self.renameAppSeven() : nil
            let before = try text.map { try Self.rows(url, columnsOf: $0) }
            var entry: [String: JSONValue] = ["user_version": .number(Double(version)), "digest": .string(digest),
                                              "rows": .number(Double(counts.values.reduce(0, +)))]
            do {
                let store = try await SQLiteMemoryStore.open(at: url)
                let migration = try await store.diagnostics().migration
                await store.close()
                entry["outcome"] = .string(migration.map { "migrated from \($0.fromShape ?? String($0.fromVersion)) to \($0.toVersion)" } ?? "opened as current")
                if let text, let before {
                    let after = try Self.rows(url, columnsOf: text)
                    // The migration adds its own record and queues one rebuild of the index: rows added, none changed.
                    let added = ["memory_schema_migrations", "memory_recall_work"]
                    let changed = before.filter { table, kept in
                        added.contains(table) ? !Set(kept).isSubset(of: Set(after[table] ?? [])) : after[table] != kept
                    }.map(\.key).sorted()
                    entry["tables_changed"] = .array(changed.map(JSONValue.string))
                    #expect(changed.isEmpty, "\(label): \(changed)")
                }
                entry["foreign_key_check"] = .number(Double(try rawRows("PRAGMA foreign_key_check", at: url).count))
                entry["integrity_check"] = .string(try rawRows("PRAGMA integrity_check", at: url).joined(separator: ";"))
                // The migrated copy, closed, with its log files, for the readers that inspect archives of version 8.
                let kept = out.appendingPathComponent("migrated").appendingPathComponent(label, isDirectory: true)
                try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                    try? FileManager.default.copyItem(atPath: url.path + suffix, toPath: kept.appendingPathComponent("memory.sqlite" + suffix).path)
                }
            } catch {
                entry["outcome"] = .string("refused: \(error)")
                let probe = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
                entry["untouched"] = .bool(SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: probe)) == digest)
                probe.close()
            }
            report[label] = .object(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(report)).write(to: out.appendingPathComponent("real-archives.json"))
    }

    @Test("a reader refuses a d3-7 archive as found; a file one statement off any known shape is refused untouched by every opener")
    func refusals() async throws {
        let (_, url, _) = try await Self.learned()
        _ = try Self.convert(url, to: try Self.dThreeSeven(), version: 7)
        let digest = { () throws -> String in
            let connection = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
            defer { connection.close() }
            return SQLiteMemorySchema.digest(of: try SQLiteMemorySchema.objects(in: connection))
        }
        await #expect(throws: MemoryStoreError.schema(.migrationRequired(found: 7, supported: 8))) {
            _ = try await SQLiteMemoryStore.open(at: url, opening: .existingArchive)
        }
        #expect(try digest() == Self.digest("d3-7"))
        // One trigger dropped: no known shape any more.
        let connection = try SQLiteConnection(path: url.path)
        try connection.execute("DROP TRIGGER memory_recall_requirements_valid")
        connection.close()
        let altered = try digest()
        await #expect(throws: (any Error).self) { _ = try await SQLiteMemoryStore.open(at: url) }
        #expect(try digest() == altered, "refused untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.contains(".schema-") }
        #expect(leftovers.isEmpty, "no copy is made of a file that is not migrated")
    }
}
