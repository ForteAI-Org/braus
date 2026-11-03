import Foundation
import Memory

/// Resolves public identities only at repository boundaries, within the borrowed transaction.
enum DB2CIdentity {
    static let sharedParents = ["memory_task_attempts": "memory_task_occurrences", "memory_agent_actions": "memory_events",
        "memory_verifications": "memory_events", "memory_operation_verifications": "memory_events", "memory_procedure_versions": "memory_routes",
        "memory_parameter_details": "memory_route_parameters"]

    static let contextOwners = ["event_id": "memory_events", "call_event_id": "memory_events", "verification_event_id": "memory_events",
        "parent_event_id": "memory_events", "sample_event_id": "memory_events", "source_event_id": "memory_events",
        "task_id": "memory_tasks", "task_occurrence_id": "memory_task_occurrences", "route_id": "memory_routes",
        "scene_id": "brain_scenes", "from_scene_id": "brain_scenes", "to_scene_id": "brain_scenes",
        "part_id": "memory_procedure_parts", "whole_part_id": "memory_procedure_parts", "relation_id": "brain_relations",
        "origin_id": "memory_archive_origins"]

    static let dependentPrefixes: [String: String] = [
        "memory_route_parameters": "parameter", "memory_route_steps": "step",
        "memory_step_checks": "check", "memory_step_operations": "operation"
    ]

    static let entities: [String: (key: String, uuid: String)] = [
        "brain_relations": ("relation_id", "relation_uuid"),
        "memory_archive_origins": ("origin_id", "origin_uuid"),
        "memory_routes": ("route_id", "route_uuid"),
        "brain_groups": ("group_id", "group_id"),
        "brain_transitions": ("transition_id", "transition_id"),
        "brain_scene_elements": ("scene_element_id", "scene_element_id"),
        "memory_procedure_parts": ("part_id", "part_uuid"),
        "brain_anchors": ("anchor_id", "anchor_id"),
        "brain_scenes": ("scene_id", "scene_uuid"),
        "memory_events": ("event_id", "event_uuid"),
        "memory_tasks": ("task_id", "task_uuid"),
        "memory_task_occurrences": ("task_occurrence_id", "task_occurrence_uuid")
    ]

    static func groupID(_ handle: some SQLiteQuerying, _ text: String) throws -> UUID? {
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return UUID(uuidString: text) }
        guard let value = Int64(text) else { return UUID(uuidString: text) }
        let digits = String(UInt64(bitPattern: value), radix: 16)
        let suffix = String(repeating: "0", count: 16 - digits.count) + digits
        return UUID(uuidString: "00000000-0000-0000-" + suffix.prefix(4) + "-" + suffix.suffix(12))
    }

    static func column(_ handle: some SQLiteQuerying, _ table: String) throws -> String {
        guard let entity = entities[table] else { throw SQLiteRecallRows.malformed(table, "identity", "unknown entity") }
        return try SQLiteRowIdentity(handle).usesIntegerKeys ? entity.uuid : entity.key
    }

    static func key(_ handle: some SQLiteQuerying, _ table: String, _ publicID: String?) throws -> SQLiteValue {
        guard let publicID else { return .null }
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return .text(publicID) }
        if let prefix = dependentPrefixes[table], publicID.hasPrefix(prefix + ":") {
            return Int64(publicID.dropFirst(prefix.count + 1)).map(SQLiteValue.integer) ?? .null
        }
        guard let entity = entities[table] else { return Int64(publicID).map(SQLiteValue.integer) ?? .null }
        if table == "brain_groups", let uuid = UUID(uuidString: publicID) {
            let digits = uuid.uuidString.replacingOccurrences(of: "-", with: "")
            guard digits.prefix(16) == String(repeating: "0", count: 16), let value = UInt64(digits.suffix(16), radix: 16) else { return .null }
            return .integer(Int64(bitPattern: value))
        }
        if entity.key == entity.uuid { return Int64(publicID).map(SQLiteValue.integer) ?? .null }
        return try handle.query("SELECT \(entity.key) FROM \(table) WHERE \(entity.uuid) = ?", [.text(publicID)]) {
            $0.integer(0).map(SQLiteValue.integer) ?? .null
        }.first ?? .null
    }

    static func publicReference(_ handle: some SQLiteQuerying, _ table: String, _ reference: String) throws -> String {
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return reference }
        if let prefix = dependentPrefixes[table] {
            return "CASE WHEN \(reference) IS NULL THEN NULL ELSE '\(prefix):' || \(reference) END"
        }
        guard let entity = entities[table] else { return reference }
        if table == "brain_groups" {
            return "CASE WHEN \(reference) IS NULL THEN NULL ELSE printf('00000000-0000-0000-%04X-%012X', (\(reference) >> 48) & 65535, \(reference) & 281474976710655) END"
        }
        if entity.key == entity.uuid { return reference }
        return "(SELECT public_identity.\(entity.uuid) FROM \(table) public_identity WHERE public_identity.\(entity.key) = \(reference))"
    }
}

/// Assigns dependent keys in a single reserved write, without retaining producer IDs in the archive.
struct DB2CRouteIdentity {
    private let transaction: SQLiteTransaction
    private var assigned: [String: [[UInt8]: Int64]] = [:]

    init(_ transaction: SQLiteTransaction, definition: RouteDefinition) throws {
        self.transaction = transaction
        let owned: [(String, String, [String])] = [
            ("memory_routes", "route_id", [definition.routeID]),
            ("memory_route_parameters", "parameter_id", definition.parameters.map(\.parameterID)),
            ("memory_route_steps", "step_id", definition.steps.map(\.stepID)),
            ("memory_step_checks", "check_id", definition.steps.flatMap { $0.checks.map(\.checkID) }),
            ("memory_step_operations", "operation_id", definition.steps.flatMap { $0.operations.flatMap { [$0.operationID] + $0.children.map(\.operationID) } })
        ]
        for (table, column, ids) in owned {
            let maximum = try transaction.query("SELECT coalesce(max(\(column)), 0) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0
            guard maximum <= Int64.max - Int64(ids.count) else { throw RouteError.invalidDefinition(.repeatedID(definition.routeID)) }
            for (offset, id) in ids.enumerated() { assigned[table, default: [:]][Array(id.utf8)] = maximum + Int64(offset) + 1 }
        }
    }

    func key(_ table: String, _ id: String?) throws -> SQLiteValue {
        guard let id else { return .null }
        if let value = assigned[table]?[Array(id.utf8)] { return .integer(value) }
        return try DB2CIdentity.key(transaction, table, id)
    }
}

/// Repository checks run under the same write reservation as the rows they validate.
enum DB2CCoherence {
    static func validate(_ transaction: SQLiteTransaction) throws {
        guard try SQLiteRowIdentity(transaction).usesIntegerKeys else { return }
        let failures = try SchemaCoherence.check(transaction)
        guard failures.isEmpty else { throw SQLiteRecallRows.malformed("schema_coherence", "write", failures.joined(separator: ", ")) }
    }
}
