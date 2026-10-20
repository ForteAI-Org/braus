//
//  SQLiteCallFieldRows.swift
//  Braus
//

import CryptoKit
import EngineCore
import Foundation
import Memory

/// SQLiteCallFieldRows records structured adapter arguments, results and data contexts within the caller's
/// transaction or snapshot. Identical facts are idempotent; conflicting facts refuse the whole conclusion.
///
/// An argument leaf's reference is decided here, from the archive, never from the caller: a text or number leaf that is
/// exactly one kept identifier field (`StructuredField.namesAnItem`) of one earlier call of the same attempt is a
/// `result_reference`; one that two or more earlier results held is `ambiguous_reference`; any other is a constant.
enum SQLiteCallFieldRows {

    // MARK: Results

    static func record(_ transaction: SQLiteTransaction, results: [StructuredField], of eventID: String) throws -> MemoryReceipt {
        guard !results.isEmpty else { return .alreadyApplied }
        let stored = try self.results(transaction, eventID)
        if !stored.isEmpty {
            guard stored == results.sorted(by: { $0.path < $1.path }) else {
                throw SQLiteFactRows.conflict("\(eventID):result_fields", stored: "\(stored)", offered: "\(results)")
            }
            return .alreadyApplied
        }
        for field in results {
            try transaction.execute(
                """
                INSERT INTO memory_call_result_fields (event_id, field_path, value_kind, text_value, withheld_reason)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.text(eventID), .text(field.path), .text(field.kind.rawValue), text(field.text), text(field.withheld?.rawValue)]
            )
        }
        return .committed
    }

    static func results(_ handle: some SQLiteQuerying, _ eventID: String) throws -> [StructuredField] {
        try handle.query(
            "SELECT field_path, value_kind, text_value, withheld_reason FROM memory_call_result_fields WHERE event_id = ? ORDER BY field_path",
            [.text(eventID)]
        ) { row in
            try StructuredField(path: try row.text(0) ?? "", kind: StructuredField.ValueKind(rawValue: try row.text(1) ?? "") ?? .null,
                                text: try row.text(2), withheld: try row.text(3).flatMap(WithholdingReason.init(rawValue:)))
        }
    }

    // MARK: Arguments

    static func record(_ transaction: SQLiteTransaction, arguments: [CallArgumentField], of eventID: String) throws -> MemoryReceipt {
        guard !arguments.isEmpty else { return .alreadyApplied }
        let resolved = try arguments.map { try resolve($0, of: eventID, in: transaction) }
        let stored = try self.arguments(transaction, eventID)
        if !stored.isEmpty {
            guard stored == resolved.sorted(by: { $0.field.path < $1.field.path }) else {
                throw SQLiteFactRows.conflict("\(eventID):argument_fields", stored: "\(stored)", offered: "\(resolved)")
            }
            return .alreadyApplied
        }
        for argument in resolved {
            let field = argument.field
            try transaction.execute(
                """
                INSERT INTO memory_call_argument_fields (event_id, field_path, value_kind, field_kind, text_value,
                    withheld_reason, source_event_id, source_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(eventID), .text(field.path), .text(field.kind.rawValue), .text(argument.kind.rawValue), text(field.text),
                 text(field.withheld?.rawValue), text(argument.sourceEventID), text(argument.sourcePath)]
            )
        }
        return .committed
    }

    /// The leaf as the archive reads it: a reference to the one earlier kept identifier that held its value in the
    /// call's attempt, ambiguous when several did, a constant otherwise.
    static func resolve(_ argument: CallArgumentField, of eventID: String, in handle: some SQLiteQuerying) throws -> CallArgumentField {
        let field = argument.field
        guard field.withheld == nil, field.kind == .text || field.kind == .number, let value = field.text, !value.isEmpty else {
            return CallArgumentField(field: field)
        }
        let candidates = try earlierResults(holding: value, kind: field.kind, before: eventID, in: handle)
            .filter(\.field.namesAnItem)
        switch candidates.count {
            case 0 : return CallArgumentField(field: field)
            case 1 : return CallArgumentField(field: field, kind: .resultReference, sourceEventID: candidates[0].eventID,
                                              sourcePath: candidates[0].field.path)
            default: return CallArgumentField(field: field, kind: .ambiguousReference)
        }
    }

    /// The kept result leaves of the calls before `eventID` in its attempt that hold exactly `value`, in call order.
    static func earlierResults(holding value: String, kind: StructuredField.ValueKind, before eventID: String,
                               in handle: some SQLiteQuerying) throws -> [(eventID: String, field: StructuredField)] {
        try handle.query(
            """
            SELECT r.event_id, r.field_path, r.value_kind, r.text_value FROM memory_call_result_fields r
            JOIN memory_task_events s ON s.event_id = r.event_id AND s.role = 'action'
            JOIN memory_task_events c ON c.event_id = ? AND c.role = 'action' AND c.task_occurrence_id = s.task_occurrence_id
            WHERE r.text_value = ? AND r.value_kind = ? AND r.withheld_reason IS NULL AND s.position < c.position
            ORDER BY s.position, r.field_path
            """,
            [.text(eventID), .text(value), .text(kind.rawValue)]
        ) { row in
            (try row.text(0) ?? "", try StructuredField(path: try row.text(1) ?? "", kind: kind, text: try row.text(3)))
        }
    }

    /// The values among `values` that are identifiers another attempt's results produced and that neither a result of
    /// `attemptID` nor an input of its task holds (P2-02): a value a run would take from the history, not from itself.
    static func historicalValues(_ handle: some SQLiteQuerying, _ values: [String], attemptID: String) throws -> [String] {
        try values.filter { value in
            let elsewhere = try handle.query(
                """
                SELECT r.field_path FROM memory_call_result_fields r JOIN memory_task_events t ON t.event_id = r.event_id
                WHERE r.text_value = ? AND r.withheld_reason IS NULL AND t.task_occurrence_id <> ?
                """,
                [.text(value), .text(attemptID)]
            ) { try $0.text(0) ?? "" }
            guard elsewhere.contains(where: { (try? StructuredField(path: $0, kind: .text, text: value).namesAnItem) == true })
            else { return false }
            let here = try handle.query(
                """
                SELECT count(*) FROM memory_call_result_fields r JOIN memory_task_events t ON t.event_id = r.event_id
                WHERE r.text_value = ? AND r.withheld_reason IS NULL AND t.task_occurrence_id = ?
                """,
                [.text(value), .text(attemptID)]
            ) { $0.integer(0) ?? 0 }.first ?? 0
            let input = try handle.query(
                """
                SELECT count(*) FROM memory_task_values v JOIN memory_task_attempts a ON a.task_id = v.task_id
                WHERE a.task_occurrence_id = ? AND v.text_value = ?
                """,
                [.text(attemptID), .text(value)]
            ) { $0.integer(0) ?? 0 }.first ?? 0
            return here == 0 && input == 0
        }
    }

    static func arguments(_ handle: some SQLiteQuerying, _ eventID: String) throws -> [CallArgumentField] {
        try handle.query(
            """
            SELECT field_path, value_kind, field_kind, text_value, withheld_reason, source_event_id, source_path
            FROM memory_call_argument_fields WHERE event_id = ? ORDER BY field_path
            """,
            [.text(eventID)]
        ) { row in
            let field = try StructuredField(path: try row.text(0) ?? "", kind: StructuredField.ValueKind(rawValue: try row.text(1) ?? "") ?? .null,
                                            text: try row.text(3), withheld: try row.text(4).flatMap(WithholdingReason.init(rawValue:)))
            return CallArgumentField(field: field, kind: CallArgumentField.Kind(rawValue: try row.text(2) ?? "") ?? .constant,
                                     sourceEventID: try row.text(5), sourcePath: try row.text(6))
        }
    }

    /// Matches only declared, same-name typed input parameters bound in the source attempt; no historical fallback.
    static func parameters(for field: StructuredField, among parameters: [RouteParameter],
                           bindings: [ParameterBinding], attemptID: String) -> [String] {
        guard field.withheld == nil, let text = field.text else { return [] }
        return parameters.filter { parameter in
            let pointer = "/" + parameter.name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            guard parameter.direction != .output, field.path == pointer else { return false }
            let compatible: Bool = switch field.kind {
                case .text: parameter.valueType == .text
                case .number: parameter.valueType == .real || (parameter.valueType == .integer && Int64(text) != nil)
                case .boolean: parameter.valueType == .boolean
                case .null: false
            }
            return compatible && bindings.contains { binding in
                guard binding.attemptID == attemptID, binding.parameterID == parameter.parameterID,
                      case .text(let value) = binding.content else { return false }
                if parameter.valueType == .integer { return Int64(value) != nil && Int64(value) == Int64(text) }
                return field.kind == .number ? Double(value) == Double(text) : value == text
            }
        }.map(\.parameterID)
    }

    // MARK: Data context

    static func record(_ transaction: SQLiteTransaction, context: CallDataContext, of eventID: String) throws -> MemoryReceipt {
        let accountRef = try context.account.map { try self.accountRef($0, in: transaction) }
        let offered = StoredContext(service: context.service, route: context.route.rawValue, profile: context.profile,
                                    accountRef: accountRef, accountSource: context.accountSource.rawValue,
                                    resourceKind: context.resourceKind, resource: context.resource)
        if let stored = try self.context(transaction, eventID) {
            guard stored == offered else {
                throw SQLiteFactRows.conflict("\(eventID):data_context", stored: "\(stored)", offered: "\(offered)")
            }
            return .alreadyApplied
        }
        try transaction.execute(
            """
            INSERT INTO memory_call_data_contexts (event_id, service, route, profile_ref, account_ref, account_source,
                resource_kind, resource_ref) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(eventID), .text(offered.service), .text(offered.route), text(offered.profile), text(offered.accountRef),
             .text(offered.accountSource), text(offered.resourceKind), text(offered.resource)]
        )
        return .committed
    }

    /// StoredContext is a data context as the archive keeps it: the account as its minimal identifier only.
    struct StoredContext: Sendable, Equatable {
        let service: String
        let route: String
        let profile: String?
        let accountRef: String?
        let accountSource: String
        let resourceKind: String?
        let resource: String?
    }

    static func context(_ handle: some SQLiteQuerying, _ eventID: String) throws -> StoredContext? {
        try handle.query(
            """
            SELECT service, route, profile_ref, account_ref, account_source, resource_kind, resource_ref
            FROM memory_call_data_contexts WHERE event_id = ?
            """,
            [.text(eventID)]
        ) { row in
            StoredContext(service: try row.text(0) ?? "", route: try row.text(1) ?? "", profile: try row.text(2),
                          accountRef: try row.text(3), accountSource: try row.text(4) ?? "unknown",
                          resourceKind: try row.text(5), resource: try row.text(6))
        }.first
    }

    /// The minimal identifier of an account in this archive: sixteen hex digits of the SHA-256 of the archive's salt and
    /// the account as written, trimmed and lowercased. The salt is made once, at random, the first time it is needed;
    /// two archives give the same account two identifiers, and the account itself is never stored.
    static func accountRef(_ account: String, in transaction: SQLiteTransaction) throws -> String {
        try transaction.execute("INSERT OR IGNORE INTO memory_identity_salts (salt_id, salt) VALUES (1, randomblob(32))")
        let salt = Data(try transaction.query("SELECT salt FROM memory_identity_salts WHERE salt_id = 1") { $0.bytes(0) ?? [] }
            .first ?? [])
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: salt + Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }


    private static func text(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
