//
//  SQLiteMemorySchema.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory

/// SQLiteMemorySchema is the DDL this module ships and what the bootstrap and the migration need to
/// know about it: the `user_version` the current schema carries, the one text that creates it, the
/// frozen text of each earlier schema an archive migrates from, and the tables they create. The current
/// text is edited in place, as main edits its own; a new archive runs it whole. An archive at the exact
/// shape of an earlier schema gets, in its migration, every object of the current text it lacks, each as
/// the current text writes it, so all end at one shape. The texts carry no `PRAGMA`, `BEGIN` or `COMMIT`
/// of their own; the store owns those boundaries. Documentation/Engine/MemorySchema.md says what the
/// resources are and how the schema came to one text; the header of brain-living-memory-schema.sql
/// names the document of each of its parts.
enum SQLiteMemorySchema {

    /// The schema version this build bootstraps and opens. A file at version 0 with no tables is empty
    /// and is bootstrapped; a file at a version of `migrations` is migrated; any other is refused,
    /// versions 2 to 6 among them: development steps of the G76 plans, never released.
    static let version: Int32 = 7

    /// The resource of the current schema, the one text a new archive runs.
    static let resourceName      = "brain-living-memory-schema"
    static let resourceExtension = "sql"

    /// The frozen resources of the earlier schemas an archive migrates from, by version: version 1, as
    /// main shipped it. Only its exact shape is read from it, to recognize such an archive; what the
    /// migration creates comes from the current text.
    static let migrations: [Int32: String] = [1: "brain-living-memory-schema-1"]

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

    /// The text that creates schema `version` in an empty file: the current one, or an earlier one this build
    /// migrates from.
    static func text(of version: Int32) throws -> String {
        if version == Self.version { return try text() }
        guard let name = migrations[version] else {
            throw MemoryStoreError.unavailable(.resourceMissing("schema \(version)"))
        }
        return try resource(name)
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
