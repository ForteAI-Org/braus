import Foundation

/// SQLiteMigration22Plan resolves physical identities from the two frozen schemas.
/// Only key structure is inferred; changed content and new facts require explicit conversion rules.
final class SQLiteMigration22Plan {
    private struct Column {
        let name: String
        let type: String
        let primary: Int64
        let required: Bool
    }

    private struct Reference {
        let table: String
        let from: [String]
        let to: [String]
    }

    let keys: SQLiteMigration22Keys
    let tables: [String]
    private let old: [String: [Column]]
    private let new: [String: [Column]]
    private let oldReferences: [String: [Reference]]
    private let newReferences: [String: [Reference]]

    /// Borrows a historical snapshot and a destination write transaction, before destination triggers exist.
    /// Callers must first recognize the source's exact shape; identifiers come only from the bundled resources.
    init(source: SQLiteConnection, target: SQLiteConnection) throws {
        tables = SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.historical19Text())
        let destination = SQLiteMemorySchema.tableNames(in: try SQLiteMigration22File.text())
        old = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Self.columns(source, $0)) })
        new = try Dictionary(uniqueKeysWithValues: destination.map { ($0, try Self.columns(target, $0)) })
        oldReferences = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Self.references(source, $0)) })
        newReferences = try Dictionary(uniqueKeysWithValues: destination.map { ($0, try Self.references(target, $0)) })
        keys = try SQLiteMigration22Keys(in: target)
        var assigned: Set<String> = []
        var visiting: Set<String> = []
        func assign(_ table: String) throws {
            if assigned.contains(table) { return }
            guard visiting.insert(table).inserted else { throw Self.refusal("identity cycle in \(table)") }
            let columns = primary(table)
            let parent = oldReferences[table, default: []].first {
                $0.from == columns && $0.to == primary($0.table) && $0.table != table
            }?.table
            if let parent { try assign(parent) }
            let idColumn: String
            if table == "memory_events" { idColumn = "local_order" }
            else if columns.count == 1, old[table]?.first(where: { $0.name == columns[0] })?.type == "INTEGER" {
                idColumn = columns[0]
            } else { idColumn = "rowid" }
            try keys.assign(from: source, table: table, columns: columns, idColumn: idColumn, parent: parent)
            visiting.remove(table)
            assigned.insert(table)
        }
        for table in tables { try assign(table) }
    }

    /// Returns rules for structural changes, refusing a required addition without a supplied content rule.
    func fields(
        for table: String,
        overriding content: [String: SQLiteMigration22RowCopy.Field] = [:]
    ) throws -> [String: SQLiteMigration22RowCopy.Field] {
        guard tables.contains(table), let previous = old[table], let destination = new[table] else {
            throw Self.refusal("row table")
        }
        var fields = content
        for column in destination where fields[column.name] == nil {
            if let before = previous.first(where: { $0.name == column.name }) {
                guard before.type != column.type else { continue }
                guard before.type == "TEXT", column.type == "INTEGER" else {
                    throw Self.refusal("content rule for \(table).\(column.name)")
                }
                // A shared primary key still belongs to the referenced entity, including scoped historical keys.
                let parent = newReferences[table, default: []].first { $0.from == [column.name] }?.table
                    ?? (primary(table) == [column.name] ? table : Self.owner(of: column.name))
                guard let parent, primary(parent).count == 1 else {
                    throw Self.refusal("identity rule for \(table).\(column.name)")
                }
                fields[column.name] = .identity(parent, [column.name])
            } else if column.name.hasSuffix("_uuid") {
                let name = String(column.name.dropLast(5)) + "_id"
                guard previous.contains(where: { $0.name == name }) else {
                    throw Self.refusal("UUID rule for \(table).\(column.name)")
                }
                fields[column.name] = .source(name)
            } else if column.primary > 0 {
                fields[column.name] = .identity(table, primary(table))
            } else if let reference = newReferences[table, default: []].first(where: { $0.from == [column.name] }),
                      let historic = oldReferences[table, default: []].first(where: {
                          $0.table == reference.table && $0.to == primary(reference.table)
                      }) {
                fields[column.name] = .identity(reference.table, historic.from)
            } else if column.required {
                throw Self.refusal("content rule for \(table).\(column.name)")
            }
        }
        return fields
    }

    private func primary(_ table: String) -> [String] {
        if table == "memory_events" { return ["event_id"] }
        return old[table, default: []].filter { $0.primary > 0 }.sorted { $0.primary < $1.primary }.map(\.name)
    }

    private static func owner(of column: String) -> String? {
        switch column {
        case "event_id", "call_event_id", "sample_event_id", "verification_event_id", "watcher_event_id",
             "agent_event_id", "evidence_event_id", "origin_event_id", "parent_event_id", "source_event_id": "memory_events"
        case "task_id": "memory_tasks"
        case "task_occurrence_id", "resumes_task_occurrence_id": "memory_task_occurrences"
        case "route_id", "called_route_id", "supersedes_route_id", "variant_of_route_id", "cursor_route_id": "memory_routes"
        case "step_id": "memory_route_steps"
        case "parameter_id", "called_parameter_id", "source_parameter_id", "expected_parameter_id": "memory_route_parameters"
        case "operation_id", "parent_operation_id": "memory_step_operations"
        case "scene_id", "from_scene_id", "to_scene_id", "expected_scene_id": "brain_scenes"
        case "anchor_id", "expected_anchor_id": "brain_anchors"
        case "menu_command_id": "brain_menu_commands"
        case "scene_element_id", "parent_element_id": "brain_scene_elements"
        case "group_id", "current_group_id": "brain_groups"
        case "part_id", "parent_part_id", "produced_by_part_id", "whole_part_id": "memory_procedure_parts"
        case "query_id": "memory_recall_queries"
        case "proposal_id": "memory_recall_proposals"
        default: nil
        }
    }

    private static func columns(_ db: SQLiteConnection, _ table: String) throws -> [Column] {
        try db.query("PRAGMA table_info(\(table))") {
            Column(name: try $0.text(1) ?? "", type: try $0.text(2) ?? "", primary: $0.integer(5) ?? 0,
                   required: $0.integer(3) == 1 && $0.isNull(4))
        }
    }

    private static func references(_ db: SQLiteConnection, _ table: String) throws -> [Reference] {
        let rows = try db.query("PRAGMA foreign_key_list(\(table))") {
            (id: $0.integer(0) ?? 0, position: $0.integer(1) ?? 0, table: try $0.text(2) ?? "",
             from: try $0.text(3) ?? "", to: try $0.text(4) ?? "")
        }
        return Dictionary(grouping: rows, by: \.id).sorted { $0.key < $1.key }.map { _, rows in
            let ordered = rows.sorted { $0.position < $1.position }
            return Reference(table: ordered[0].table, from: ordered.map(\.from), to: ordered.map(\.to))
        }
    }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal {
        .verificationFailed([reason])
    }
}
