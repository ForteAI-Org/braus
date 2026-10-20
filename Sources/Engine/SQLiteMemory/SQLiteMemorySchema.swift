//
//  SQLiteMemorySchema.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import CryptoKit
import Foundation
import Memory

/// SQLiteMemorySchema is the DDL this module ships and what the bootstrap and the migration need to
/// know about it: the `user_version` the current schema carries, the one text that creates it, the part
/// of that text an earlier schema an archive migrates from is, and the tables they create. The text is
/// edited in place; a new archive runs it whole. Its part 1 is version 1: an archive at exactly that shape
/// gets, in its migration, every object of the later parts it lacks, each as the text writes it, so all
/// end at one shape. The text carries no `PRAGMA`, `BEGIN` or `COMMIT` of its own; the store owns those
/// boundaries. Documentation/Engine/MemorySchema.md says what the resource is and how the schema came to
/// one text; the header of brain-living-memory-schema.sql names the document of each of its parts.
enum SQLiteMemorySchema {

    /// The schema version bootstrapped by this build. Public historical schemas are recognized by their
    /// exact object digests and rebuilt transactionally; unknown or modified shapes are refused.
    static let version: Int32 = 19

    /// The resource of the current schema, the one text a new archive runs.
    static let resourceName      = "brain-living-memory-schema"
    static let resourceExtension = "sql"

    /// The earlier schemas an archive migrates from, by version, each the parts of the one text that are that
    /// schema whole, from part 1 to the part named: version 1 is part 1, the base. Only its exact shape is read from it,
    /// to recognize such an archive; what the migration creates comes from the later parts.
    static let migrations: [Int32: Int] = [1: 1]

    /// HistoricalShape identifies a supported earlier schema by its exact object digest.
    struct HistoricalShape: Sendable, Equatable {
        let name   : String
        let version: Int32
        let digest : String
        /// The derived rows of this version, written when the migration creates the tables they fill.
        let derivedFrom: Int32?
    }

    static let historicalShapes = [
        // a9a7f8c..f44fb67, brain-living-memory-schema.sql sha256 9df535ab…: main before the value change.
        HistoricalShape(name: "main-1", version: 1, digest: "858ba5c594ed0e5d9a2c8c18167658282c93e8dc687ecf0a5ed6c5120b227f93",
                        derivedFrom: 1),
        // e600a65..7ee2552, the seven texts (sha256 c34e4c39…) or the one text (cb8debcd…), the same objects.
        HistoricalShape(name: "d3-7", version: 7, digest: "c5b10b676fa08c80697f8973f1e3e0d76c83d7144c65f533fc82fca735139825",
                        derivedFrom: nil),
        // d30a16b..7a64595, the one text (sha256 60189583… at 7a64595, 8ad0d557… at d30a16b), the same objects.
        HistoricalShape(name: "rename-app-7", version: 7, digest: "aee1cd5dcd45884a4488c2e4290ed3754230ce6e27f83b5add866a824cf196f4",
                        derivedFrom: nil),
        // 5ed5118..cd5c77c (main), the one text (sha256 cc568899…): only memory_value_redactions differs, by its reason CHECK.
        HistoricalShape(name: "main-8", version: 8, digest: "fabb6a92a8dcedd34562a2700cdac9075b5bc8a4520541d17a32a5d07ae937c6",
                        derivedFrom: nil),
        // 1106ec6a..0760d604 (ron/unified-engine-integration), the one text (sha256 d2c7248a…): only
        // memory_operation_verification_limits differs, by its limit CHECK.
        HistoricalShape(name: "unified-9", version: 9, digest: "39d1a2145b35a9843b8400086d44050ca7d819af0fdd548548a28bdec17f210f",
                        derivedFrom: nil),
        // 800ad2f9..7b9d8dee (ron/unified-engine-integration), the one text (sha256 fe7152d7…): it lacks
        // memory_call_routes only.
        HistoricalShape(name: "unified-10", version: 10, digest: "9c5dfb5eefc3b48023f4f6e9236a8e143cf2a9b8efce23f4d3aa32779e0d39a0",
                        derivedFrom: nil),
        // 2069ed04..66f16f21 (ron/unified-engine-integration), the one text (sha256 ca0739d5…): it lacks
        // memory_call_adapter_dispatches only.
        HistoricalShape(name: "unified-11", version: 11, digest: "d6ebbc90e13e9d2535df237101d4c9d12a8403f3ce2d0041e435fd7c4f5d6bda",
                        derivedFrom: nil),
        HistoricalShape(name: "unified-12", version: 12, digest: "678cada0d20db43f38c32a3c20e50f4770ca1a647ef53e5344e828d74c77ee69",
                        derivedFrom: nil),
    ]

    /// The digest of a set of objects: sorted by type and name, `type|name|sql` on one line each, sha256.
    static func digest(of objects: Set<SchemaObject>) -> String {
        let canonical = objects.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
            .map { "\($0.type)|\($0.name)|\($0.sql ?? "")" }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Brings an archive at a historical shape to the current one, inside the caller's write transaction, on a connection
    /// whose foreign keys are off (a pragma that a transaction cannot change). Nothing is guessed: the archive must hold no
    /// object the current text does not; each table the current text writes otherwise is rebuilt under that text, its rows
    /// copied column by column, the columns it lacks left NULL as the current text allows (a field no earlier build knew
    /// stays unknown); every index and trigger written otherwise, or on a rebuilt table, is dropped and written again; then
    /// every object the archive lacks is created as the migration from version 1 creates them, with the rows derived from
    /// its own when the tables they fill are new. A row an earlier constraint admitted and the current one refuses, or a
    /// reference left dangling, fails the statement or the check that follows, and the caller rolls everything back.
    /// Answers the tables it created.
    static func rebuild(_ connection: SQLiteConnection, from shape: HistoricalShape) throws -> [String] {
        let current = try orderedObjects(of: try text())
        let wanted = Dictionary(uniqueKeysWithValues: current.map { ("\($0.type)|\($0.name)", $0) })
        let found = try connection.query(
            "SELECT type, name, sql, tbl_name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY rowid"
        ) { (object: SchemaObject(type: try $0.text(0) ?? "", name: try $0.text(1) ?? "", sql: try $0.text(2)), table: try $0.text(3) ?? "") }
        let foreign = found.filter { wanted["\($0.object.type)|\($0.object.name)"] == nil }.map(\.object.label)
        guard foreign.isEmpty else {
            throw MemoryStoreError.schema(.differentShape(foreign))
        }
        let rebuilt = found.filter { $0.object.type == "table" && wanted["table|\($0.object.name)"]?.sql != $0.object.sql }.map(\.object.name)
        // Names are this module's own: those of the current text, which every found object matched.
        for item in found where item.object.type != "table" {
            guard wanted["\(item.object.type)|\(item.object.name)"]?.sql != item.object.sql || rebuilt.contains(item.table) else { continue }
            try connection.execute("DROP \(item.object.type == "index" ? "INDEX" : "TRIGGER") \(item.object.name)")
        }
        // A renamed table keeps the references other tables and triggers make to its name: they name the rebuilt one.
        try connection.execute("PRAGMA legacy_alter_table = ON")
        defer { try? connection.execute("PRAGMA legacy_alter_table = OFF") }
        for table in rebuilt {
            let aside = "\(table)__before_rebuild"
            func columns(_ name: String) throws -> [String] {
                try connection.query("PRAGMA table_info(\(name))") { try $0.text(1) ?? "" }
            }
            let kept = try columns(table)
            try connection.execute("ALTER TABLE \(table) RENAME TO \(aside)")
            try connection.execute(wanted["table|\(table)"]?.sql ?? "")
            let now = try columns(table)
            let lost = kept.filter { !now.contains($0) }
            guard lost.isEmpty else {
                throw MemoryStoreError.schema(.differentShape(lost.map { "column \(table).\($0)" }))
            }
            let list = kept.joined(separator: ", ")
            try connection.execute("INSERT INTO \(table) (\(list)) SELECT \(list) FROM \(aside)")
            try connection.execute("DROP TABLE \(aside)")
        }
        let present = Set(try connection.query("SELECT type || '|' || name FROM sqlite_schema") { try $0.text(0) ?? "" })
        let added = current.filter { !present.contains("\($0.type)|\($0.name)") }
        let tables = added.filter { $0.type == "table" }
        for object in tables { try connection.execute(object.sql ?? "") }
        if let version = shape.derivedFrom, let rows = derivedRows[version],
           tables.contains(where: { rows.contains("INSERT INTO \($0.name) ") }) {
            try connection.execute(rows)
        }
        for object in added where object.type == "index" { try connection.execute(object.sql ?? "") }
        for object in added where object.type == "trigger" { try connection.execute(object.sql ?? "") }
        let dangling = try connection.query("PRAGMA foreign_key_check") { try $0.text(0) ?? "" }
        guard dangling.isEmpty else {
            throw MemoryStoreError.schema(.differentShape(Array(Set(dangling)).sorted().map { "references of \($0)" }))
        }
        return tables.map(\.name)
    }

    /// The line that opens and closes the header of each part of the one text.
    static let partRule = "-- " + String(repeating: "=", count: 109) + "\n"

    /// What an archive of an earlier schema needs that the current text's statements cannot create: rows
    /// derived from its own, written after the tables and before the indexes and triggers. Version 1 gets the
    /// shapes of the structural scenes it holds. The store derives the rest in the same transaction (the
    /// anchors' label keys, one rebuild of the Recall's index).
    static let derivedRows: [Int32: String] = [1: """
        INSERT INTO brain_scene_shapes (scene_id, app_id, role_key)
        SELECT s.scene_id, s.app_id,
               ifnull((SELECT group_concat(r.role, char(31) ORDER BY r.role) FROM brain_scene_roles r WHERE r.scene_id = s.scene_id), '')
        FROM brain_scenes s WHERE s.scene_kind <> 'app'
        """]

    /// The text that creates the current schema in an empty file.
    static func text() throws -> String {
        try resource(resourceName)
    }

    /// The text that creates schema `version` in an empty file: the current one, or the part of it that is
    /// an earlier one this build migrates from.
    static func text(of version: Int32) throws -> String {
        if version == Self.version { return try text() }
        guard let last = migrations[version] else {
            throw MemoryStoreError.unavailable(.resourceMissing("schema \(version)"))
        }
        let whole = try text()
        return try (1...last).map { try self.part($0, of: whole) }.joined()
    }

    /// Part `number` of the one text, its statements without its header: the text holds a header, then for
    /// each part a header between two rules and the part's statements.
    static func part(_ number: Int, of text: String) throws -> String {
        let segments = text.components(separatedBy: partRule)
        guard number >= 1, segments.count >= 2 * number + 1,
              segments[2 * number - 1].hasPrefix("-- Part \(number). ") else {
            throw MemoryStoreError.unavailable(.resourceMissing("part \(number) of the schema"))
        }
        return segments[2 * number]
    }

    /// The text that migrates a file at the exact shape of `version` to the current schema: every table the
    /// current text creates and that version does not, in creation order, then the rows derived from its own,
    /// then the indexes, then the triggers, each statement as the current text writes it. Refused when an
    /// object of that version is not in the current text exactly as that version wrote it: a migration only adds.
    static func migrationText(from version: Int32) throws -> String {
        let earlier = try objects(of: try text(of: version))
        let current = try orderedObjects(of: try text())
        guard earlier.isSubset(of: Set(current)) else {
            throw MemoryStoreError.unavailable(.resourceMissing("migration from \(version)"))
        }
        let added = current.filter { !earlier.contains($0) }
        let statements = added.filter { $0.type == "table" }.compactMap(\.sql)
            + [derivedRows[version]].compactMap { $0 }
            + added.filter { $0.type == "index" }.compactMap(\.sql)
            + added.filter { $0.type == "trigger" }.compactMap(\.sql)
        return statements.map { $0 + ";" }.joined(separator: "\n\n")
    }

    /// One resource's text, read from the module's bundle.
    private static func resource(_ name: String) throws -> String {
        let file = "\(name).\(resourceExtension)"
        guard let url = Bundle.module.url(forResource: name, withExtension: resourceExtension) else {
            throw MemoryStoreError.unavailable(.resourceMissing(file))
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MemoryStoreError.unavailable(.resourceMissing(file))
        }
    }

    /// Columns this build writes that an earlier development form of schema 1 did not have, as
    /// `(table, column)`. A file at version 1 or later with every table but without one of them is
    /// that earlier form: refused untouched, never migrated. The first distributed database carries them
    /// all; the list exists because files bootstrapped during development already exist at the same
    /// `user_version`. Table and column names are this module's own literals.
    static let requiredColumns: [(table: String, column: String)] = [
        ("brain_anchors", "current_group_id"),
        ("memory_operation_arguments", "brain_application_id"),
        ("memory_agent_actions", "started_at_ms"),
        // S3-d correction: a file the S3-d build created (42 tables, no duration, encoded effects) is
        // refused untouched by the table set and by these; nothing migrates or resets it.
        ("memory_agent_actions", "duration_ms"),
        ("memory_agent_actions", "observed_state_before"),
        ("memory_events", "origin_event_id"),
        // The value change: a file bootstrapped before it has neither pair and is refused untouched.
        ("brain_transitions", "effect_label"),
        ("memory_agent_actions", "observed_effect_label"),
    ]

    /// SchemaObject is one table, index or trigger as `sqlite_schema` keeps it: its type, its name
    /// and the exact statement that created it.
    struct SchemaObject: Sendable, Equatable, Hashable {
        let type: String
        let name: String
        let sql : String?

        /// How a difference names it: `type name`.
        var label: String { "\(type) \(name)" }
    }

    /// The objects the text creates, read from a scratch database in memory that ran it: the exact
    /// shape a file bootstrapped by this build has. The library's own objects (`sqlite_%`) are left
    /// out on both sides.
    static func objects(of text: String) throws -> Set<SchemaObject> {
        let scratch = try SQLiteConnection(path: ":memory:")
        defer { scratch.close() }
        try scratch.execute(text)
        return try objects(in: scratch)
    }

    /// The objects a database holds, the library's own left out.
    static func objects(in connection: SQLiteConnection) throws -> Set<SchemaObject> {
        Set(try orderedObjects(in: connection))
    }

    /// The objects the text creates, in the order it creates them.
    static func orderedObjects(of text: String) throws -> [SchemaObject] {
        let scratch = try SQLiteConnection(path: ":memory:")
        defer { scratch.close() }
        try scratch.execute(text)
        return try orderedObjects(in: scratch)
    }

    /// The objects a database holds, in the order they were created, the library's own left out.
    static func orderedObjects(in connection: SQLiteConnection) throws -> [SchemaObject] {
        try connection.query(
            "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY rowid"
        ) { SchemaObject(type: try $0.text(0) ?? "", name: try $0.text(1) ?? "", sql: try $0.text(2)) }
    }

    /// The objects that differ between a file and the expected shape, missing, extra or written
    /// differently, as sorted labels; empty when the file is exactly the expected shape.
    static func differences(found: Set<SchemaObject>, expected: Set<SchemaObject>) -> [String] {
        Set(found.symmetricDifference(expected).map(\.label)).sorted()
    }

    /// What the current schema holds that schema `version` does not, in the order that removes it from
    /// a file: the triggers first, then the indexes, then the tables, the last created first. Nothing in
    /// the product goes back to an earlier schema; a test uses this to leave a file exactly at the shape
    /// an earlier build bootstraps, with the rows the earlier tables hold. The current text writes every
    /// object of an earlier schema as that schema did, so nothing else needs putting back.
    static func objectsAdded(since version: Int32) throws -> [SchemaObject] {
        let earlier = try objects(of: try text(of: version))
        let current = try text()
        let added   = try objects(of: current).subtracting(earlier)
        let tables  = tableNames(in: current)
        func rank(_ object: SchemaObject) -> Int {
            switch object.type {
                case "trigger": 0
                case "index"  : 1
                default       : 2
            }
        }
        return added.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.type == "table" { return (tables.firstIndex(of: a.name) ?? 0) > (tables.firstIndex(of: b.name) ?? 0) }
            return a.name < b.name
        }
    }

    /// Every table the text creates, in creation order, read from its `CREATE TABLE` lines.
    static func tableNames(in text: String) -> [String] {
        let prefix = "CREATE TABLE "
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }
}
