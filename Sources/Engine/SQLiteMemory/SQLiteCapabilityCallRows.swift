import Foundation
import Memory

/// SQLiteCapabilityCallRows writes capability facts atomically using only schema 22.
/// Earlier archives return a typed unavailable failure before writing any rows.
public struct SQLiteCapabilityCallRows: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case unavailable(schemaVersion: Int)
        case conflict(String)
        case unknownCall(String)
    }

    public struct Opening: Sendable {
        public let event: MemoryEventRecord
        public let capabilityID: String
        public let effect: String
        public let channel: String
        public let origin: String
        public let originName: String?
        public let arguments: [StructuredField]
        public let attribution: TaskCallAttribution?

        public init(event: MemoryEventRecord, capabilityID: String, effect: String, channel: String,
                    origin: String, originName: String?, arguments: [StructuredField], attribution: TaskCallAttribution?) {
            self.event = event
            self.capabilityID = capabilityID
            self.effect = effect
            self.channel = channel
            self.origin = origin
            self.originName = originName
            self.arguments = arguments
            self.attribution = attribution
        }
    }

    private let store: SQLiteMemoryStore
    public init(store: SQLiteMemoryStore) { self.store = store }

    public func began(_ opening: Opening) async throws {
        try await store.write { try Self.began(opening, in: $0) }
    }

    public func ended(_ opening: Opening, atMS: Int64, results: [StructuredField], failure: String?,
                      verification: String, verified: Bool?) async throws {
        try await store.write {
            try Self.ended(opening, atMS: atMS, results: results, failure: failure,
                           verification: verification, verified: verified, in: $0)
        }
    }

    private static func requireAvailable(in tx: SQLiteTransaction) throws {
        let version = try tx.query("PRAGMA user_version") { Int($0.integer(0) ?? 0) }.first ?? 0
        let exists = try tx.query("SELECT count(*) FROM sqlite_schema WHERE name = 'memory_call_capabilities'") {
            $0.integer(0) ?? 0
        }.first == 1
        guard (version == 0 || version >= 22), exists else { throw Failure.unavailable(schemaVersion: version) }
    }

    package static func began(_ opening: Opening, in tx: SQLiteTransaction) throws {
        try requireAvailable(in: tx)
        if let event = try eventID(opening.event.eventID, in: tx) {
            let stored = try tx.query("""
                SELECT capability_id,effect_class,channel,origin,origin_name FROM memory_call_capabilities WHERE event_id = ?
                """, [.integer(event)]) {
                    (try $0.text(0), try $0.text(1), try $0.text(2), try $0.text(3), try $0.text(4))
                }.first
            guard let stored, stored.0 == opening.capabilityID, stored.1 == opening.effect,
                  stored.2 == opening.channel, stored.3 == opening.origin, stored.4 == opening.originName,
                  try fieldsMatch(opening.arguments, event: event, result: false, in: tx) else {
                throw Failure.conflict(opening.event.eventID)
            }
            return
        }
        let event = try insertEvent(opening.event, in: tx)
        try tx.execute("""
            INSERT INTO memory_agent_actions (event_id,tool_kind,execution_status,started_at_ms)
            VALUES (?,?,'started',?)
            """, [.integer(event), .text(opening.capabilityID), .integer(opening.event.occurredAtMS)])
        try tx.execute("""
            INSERT INTO memory_call_capabilities (event_id,capability_id,effect_class,channel,origin,origin_name)
            VALUES (?,?,?,?,?,?)
            """, [.integer(event), .text(opening.capabilityID), .text(opening.effect), .text(opening.channel),
                  .text(opening.origin), text(opening.originName)])
        try fields(opening.arguments, event: event, result: false, in: tx)
        if let attribution = opening.attribution {
            guard let attributionIDs = try tx.query("""
                SELECT o.task_occurrence_id,t.task_id,r.task_revision_id FROM memory_task_occurrences o
                JOIN memory_task_attempts a ON a.task_occurrence_id = o.task_occurrence_id
                JOIN memory_tasks t ON t.task_id = a.task_id
                JOIN memory_task_revisions r ON r.task_id = t.task_id AND r.revision = ?
                WHERE o.task_occurrence_uuid = ? AND t.task_uuid = ? AND o.status = 'in_progress'
                """, [.integer(Int64(attribution.revision)), .text(attribution.attemptID), .text(attribution.taskID)], {
                    ($0.integer(0), $0.integer(1), $0.integer(2))
                }).first, let attempt = attributionIDs.0, let task = attributionIDs.1, let revision = attributionIDs.2 else {
                throw Failure.conflict(attribution.attemptID)
            }
            try tx.execute("""
                INSERT INTO memory_task_events (task_occurrence_id,event_id,position,role)
                SELECT ?,?,ifnull(max(position)+1,0),'action' FROM memory_task_events WHERE task_occurrence_id = ?
                """, [.integer(attempt), .integer(event), .integer(attempt)])
            try tx.execute("""
                INSERT INTO memory_task_call_revisions (event_id,task_occurrence_id,task_id,revision,task_revision_id)
                VALUES (?,?,?,?,?)
                """, [.integer(event), .integer(attempt), .integer(task), .integer(Int64(attribution.revision)),
                      .integer(revision)])
        }
    }

    package static func ended(_ opening: Opening, atMS: Int64, results: [StructuredField], failure: String?,
                              verification: String, verified: Bool?, in tx: SQLiteTransaction) throws {
        try requireAvailable(in: tx)
        guard let event = try eventID(opening.event.eventID, in: tx) else { throw Failure.unknownCall(opening.event.eventID) }
        let status = failure == nil ? "completed" : "failed"
        let prior = try tx.query("SELECT execution_status,result_message FROM memory_agent_actions WHERE event_id = ?",
                                 [.integer(event)]) { (try $0.text(0), try $0.text(1)) }.first
        if prior?.0 != "started" {
            guard prior?.0 == status, prior?.1 == failure,
                  try fieldsMatch(results, event: event, result: true, in: tx) else {
                throw Failure.conflict(opening.event.eventID)
            }
            return
        }
        try tx.execute("""
            UPDATE memory_agent_actions SET execution_status = ?,completed_at_ms = ?,result_message = ? WHERE event_id = ?
            """, [.text(status), .integer(atMS), text(failure), .integer(event)])
        try fields(results, event: event, result: true, in: tx)
        let verificationEvent = MemoryEventRecord(eventID: opening.event.eventID + "/verification",
            source: opening.event.source, streamID: opening.event.streamID, traceID: opening.event.traceID,
            sessionID: opening.event.sessionID, kind: .verification, occurredAtMS: atMS)
        let check = try insertEvent(verificationEvent, in: tx)
        try tx.execute("""
            INSERT INTO memory_verifications (event_id,scope,method,verdict)
            VALUES (?,?,?,?)
            """, [.integer(check), .text(VerificationScope.call.rawValue), .text(verification),
                  .text(verified.map { $0 ? "passed" : "failed" } ?? "unknown")])
        try tx.execute("""
            INSERT INTO memory_operation_verifications
                (event_id,call_event_id,contract_version,condition_kind,method_version,performed)
            VALUES (?,?,1,?,?,'uncertain')
            """, [.integer(check), .integer(event), .text(verification == "readBack" ? "state_read_back" : "none"),
                  .text(verification)])
    }

    private static func eventID(_ uuid: String, in tx: SQLiteTransaction) throws -> Int64? {
        try tx.query("SELECT event_id FROM memory_events WHERE event_uuid = ?", [.text(uuid)]) { $0.integer(0) }.first ?? nil
    }

    private static func insertEvent(_ event: MemoryEventRecord, in tx: SQLiteTransaction) throws -> Int64 {
        try tx.execute("""
            INSERT INTO memory_events (event_uuid,source,source_stream_id,trace_id,session_id,event_kind,occurred_at_ms,
                monotonic_ns,capture_status) VALUES (?,?,?,?,?,?,?,?,?)
            """, [.text(event.eventID), .text(event.source.rawValue), .text(event.streamID), text(event.traceID),
                  text(event.sessionID), .text(event.kind.rawValue), .integer(event.occurredAtMS),
                  event.monotonicNS.map(SQLiteValue.integer) ?? .null, .text(event.captureStatus.rawValue)])
        guard let id = try eventID(event.eventID, in: tx) else { throw Failure.unknownCall(event.eventID) }
        return id
    }

    private static func fieldsMatch(_ fields: [StructuredField], event: Int64, result: Bool,
                                    in tx: SQLiteTransaction) throws -> Bool {
        let sql = result
            ? "SELECT field_path,value_kind,text_value,withheld_reason FROM memory_call_result_fields WHERE event_id = ? ORDER BY field_path"
            : "SELECT field_path,value_kind,text_value,withheld_reason FROM memory_call_argument_fields WHERE event_id = ? ORDER BY field_path"
        let stored = try tx.query(sql, [.integer(event)]) {
            [try $0.text(0), try $0.text(1), try $0.text(2), try $0.text(3)]
        }
        let offered = fields.sorted { $0.path < $1.path }.map { field in
            [Optional(field.path), Optional(field.kind.rawValue), field.text, field.withheld?.rawValue]
        }
        return stored == offered
    }

    private static func fields(_ fields: [StructuredField], event: Int64, result: Bool, in tx: SQLiteTransaction) throws {
        for field in fields {
            if result {
                try tx.execute("""
                    INSERT INTO memory_call_result_fields (event_id,field_path,value_kind,text_value,withheld_reason)
                    VALUES (?,?,?,?,?)
                    """, [.integer(event), .text(field.path), .text(field.kind.rawValue), text(field.text), text(field.withheld?.rawValue)])
            } else {
                try tx.execute("""
                    INSERT INTO memory_call_argument_fields (event_id,field_path,value_kind,field_kind,text_value,withheld_reason)
                    VALUES (?,?,?,'constant',?,?)
                    """, [.integer(event), .text(field.path), .text(field.kind.rawValue), text(field.text), text(field.withheld?.rawValue)])
            }
        }
    }

    private static func text(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}
