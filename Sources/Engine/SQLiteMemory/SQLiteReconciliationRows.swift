//
//  SQLiteReconciliationRows.swift
//  Braus
//

import EngineCore
import Foundation
import Memory

/// SQLiteReconciliationRows is the codec of part 8's executors and reconciliations (P2-06), inside the caller's
/// transaction or snapshot. An executor's row is written once, with the first call it starts; a call's executor with
/// the call's start; a reconciliation at its call's next sequence, never changing anything written before.
enum SQLiteReconciliationRows {

    static func link(_ transaction: SQLiteTransaction, call eventID: String, to executor: ExecutorRecord) throws -> MemoryReceipt {
        try transaction.execute(
            "INSERT OR IGNORE INTO memory_executors (executor_id, source, process_id, started_at_ms) VALUES (?, ?, ?, ?)",
            [.text(executor.executorID), .text(executor.source), .integer(Int64(executor.processID)), .integer(executor.startedAtMS)]
        )
        let stored = try transaction.query("SELECT executor_id FROM memory_call_executors WHERE event_id = ?", [.text(eventID)]) {
            try $0.text(0)
        }.first ?? nil
        if let stored {
            guard stored == executor.executorID else {
                throw SQLiteFactRows.conflict("\(eventID):executor", stored: stored, offered: executor.executorID)
            }
            return .alreadyApplied
        }
        try transaction.execute("INSERT INTO memory_call_executors (event_id, executor_id) VALUES (?, ?)",
                                [.text(eventID), .text(executor.executorID)])
        return .committed
    }

    static func append(_ transaction: SQLiteTransaction, _ fact: CallReconciliation) throws -> MemoryReceipt {
        if fact.kind == .observed, try !supports(transaction, fact) {
            throw OperationFactError.invalid(.emptyText(field: "compatible_reconciliation_evidence"))
        }
        if fact.kind == .acknowledged, fact.declaredBy != .person {
            throw OperationFactError.invalid(.emptyText(field: "person_acknowledgement"))
        }
        let sequence = 1 + (try transaction.query(
            "SELECT ifnull(max(sequence), 0) FROM memory_call_reconciliations WHERE event_id = ?", [.text(fact.callEventID)]
        ) { $0.integer(0) ?? 0 }.first ?? 0)
        try transaction.execute(
            """
            INSERT INTO memory_call_reconciliations (event_id, sequence, kind, finding, evidence_event_id, declared_by,
                recorded_at_ms, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(fact.callEventID), .integer(sequence), .text(fact.kind.rawValue), text(fact.finding?.rawValue),
             text(fact.evidenceEventID), .text(fact.declaredBy.rawValue), .integer(fact.recordedAtMS), text(fact.detail)]
        )
        return .committed
    }

    static func reconciliations(_ handle: some SQLiteQuerying, _ eventID: String) throws -> [CallReconciliation] {
        try handle.query(
            """
            SELECT kind, finding, evidence_event_id, declared_by, recorded_at_ms, detail FROM memory_call_reconciliations
            WHERE event_id = ? ORDER BY sequence
            """,
            [.text(eventID)]
        ) { row in
            try CallReconciliation(callEventID: eventID, kind: CallReconciliation.Kind(rawValue: try row.text(0) ?? "") ?? .acknowledged,
                                   finding: try row.text(1).flatMap(CallReconciliation.Finding.init(rawValue:)),
                                   evidenceEventID: try row.text(2),
                                   declaredBy: CallReconciliation.Declarer(rawValue: try row.text(3) ?? "") ?? .braus,
                                   recordedAtMS: row.integer(4) ?? 0, detail: try row.text(5))
        }
    }

    /// The unresolved calls of a stream: started and never ended under another executor (or none known), or concluded
    /// with an uncertain effect, with no observation that found the effect happened or not and no acknowledgement since.
    static func unresolved(_ handle: some SQLiteQuerying, source: String, streamID: String,
                           excludingExecutor executorID: String?) throws -> [(eventID: String, reason: UnresolvedCall.Reason, resource: String?)] {
        let candidates: [(eventID: String, reason: UnresolvedCall.Reason, resource: String?)] = try handle.query(
            """
            SELECT a.event_id, a.execution_status, d.resource_ref FROM memory_agent_actions a
            JOIN memory_events ev ON ev.event_id = a.event_id
            LEFT JOIN memory_call_effects f ON f.event_id = a.event_id
            LEFT JOIN memory_call_data_contexts d ON d.event_id = a.event_id
            LEFT JOIN memory_call_executors x ON x.event_id = coalesce(ev.parent_event_id, a.event_id)
            WHERE ev.source = ? AND ev.source_stream_id = ? AND a.tool_kind <> 'batch'
              AND ((a.execution_status = 'started' AND (x.executor_id IS NULL OR x.executor_id IS NOT ?))
                   OR (a.execution_status IN ('completed', 'failed', 'cancelled', 'interrupted') AND f.performed = 'uncertain'))
            ORDER BY a.started_at_ms, a.event_id
            """,
            [.text(source), .text(streamID), text(executorID)]
        ) { row in
            (try row.text(0) ?? "", (try row.text(1)) == "started" ? .neverEnded : .effectUncertain, try row.text(2))
        }
            return try candidates.filter { candidate in
            // Historical observations are revalidated too; invalid old facts remain in history without opening a gate.
            for fact in try reconciliations(handle, candidate.eventID) where fact.resolves {
                if fact.kind == .acknowledged && fact.declaredBy == .person { return false }
                if fact.kind == .observed, try supports(handle, fact) { return false }
            }
            return true
        }
    }

    /// Requires a successful read in the same producer stream, service and resource scope. An answer alone is no proof.
    private static func supports(_ handle: some SQLiteQuerying, _ fact: CallReconciliation) throws -> Bool {
        guard let evidenceID = fact.evidenceEventID,
              let original = try SQLiteAgentCallRows.call(handle, eventID: fact.callEventID),
              let evidence = try SQLiteAgentCallRows.call(handle, eventID: evidenceID),
              evidence.localOrder > original.localOrder,
              evidence.progress.status == .completed,
              original.event.source == evidence.event.source,
              original.event.streamID == evidence.event.streamID,
              let before = try SQLiteCallFieldRows.context(handle, fact.callEventID),
              let after = try SQLiteCallFieldRows.context(handle, evidenceID),
              before.service == after.service, before.route == after.route, before.profile == after.profile,
              before.accountRef == after.accountRef,
            before.accountRef != nil || before.accountSource == after.accountSource else { return false }
        if original.progress.status == .started {
            let ended = try reconciliations(handle, fact.callEventID).contains { $0.kind == .executorTerminated && $0.declaredBy == .braus }
            guard ended else { return false }
        }
        if original.progress.status != .started {
            let endOrder = try handle.query(
                "SELECT max(e.local_order) FROM memory_operation_verifications v JOIN memory_events e ON e.event_id = v.event_id WHERE v.call_event_id = ?",
                [.text(fact.callEventID)]
            ) { $0.integer(0) }.first ?? nil
            guard let endOrder, evidence.localOrder > endOrder else { return false }
        }
        let checks = try SQLiteProcedureRows.verifications(handle, call: evidenceID)
        guard checks.contains(where: {
            $0.condition == .adapterRead && $0.verdict == .passed
        }) else { return false }
        let results = try SQLiteCallFieldRows.results(handle, evidenceID).filter { $0.withheld == nil }
        if let dispatched = try SQLiteOperationFactRows.adapterDispatch(handle, fact.callEventID) {
            guard let read = try SQLiteOperationFactRows.adapterDispatch(handle, evidenceID),
                  read.adapter == dispatched.adapter, let resource = before.resource else { return false }
            return ReconciliationPolicy.supportsAdapter(adapter: dispatched.adapter, verb: dispatched.verb,
                                                         resource: resource, results: results, finding: fact.finding)
        }
        return false
    }

    static func started(_ handle: some SQLiteQuerying, excludingExecutor executorID: String) throws -> [(eventID: String, executorID: String)] {
        try handle.query(
            """
            SELECT a.event_id, x.executor_id FROM memory_agent_actions a
            JOIN memory_events ev ON ev.event_id = a.event_id
            JOIN memory_call_executors x ON x.event_id = coalesce(ev.parent_event_id, a.event_id)
            WHERE a.execution_status = 'started' AND x.executor_id <> ?
              AND NOT EXISTS (SELECT 1 FROM memory_call_reconciliations r WHERE r.event_id = a.event_id
                              AND r.kind = 'executor_terminated')
            ORDER BY a.event_id
            """,
            [.text(executorID)]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }
    }

    private static func text(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
