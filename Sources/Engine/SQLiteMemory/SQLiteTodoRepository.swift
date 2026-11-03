import Foundation
import Memory

/// SQLiteTodoRepository uses only the approved schema 22 tables. Older archives are read-only to this role.
public struct SQLiteTodoRepository: TodoStoring {
    private let store: SQLiteMemoryStore
    public init(store: SQLiteMemoryStore) { self.store = store }

    public func requireAvailable() async throws {
        try await store.read { try Self.requireAvailable(in: $0) }
    }

    public func current(of taskID: String) async throws -> Todo? {
        try await store.read { try Self.current(of: taskID, in: $0) }
    }

    public func append(_ revision: TodoRevision, expecting: Int) async throws -> Todo {
        try await store.write { try Self.append(revision, expecting: expecting, in: $0) }
    }

    public func revisions(of taskID: String) async throws -> [TodoRevision] {
        try await store.read { try Self.revisions(of: taskID, in: $0) }
    }

    public func attributedCalls(ofTask taskID: String, item: TodoRowID? = nil) async throws -> [CallAttribution] {
        try await store.read { try Self.attributedCalls(ofTask: taskID, item: item, in: $0) }
    }

    static func requireAvailable(in handle: some SQLiteQuerying) throws {
        let version = try handle.query("PRAGMA user_version", []) { Int($0.integer(0) ?? 0) }.first ?? 0
        guard version == 0 || version >= 22 else { throw TodoStoreError.unavailable(schemaVersion: version) }
        let exists = try handle.query(
            "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = 'memory_todo_revisions'", []
        ) { $0.integer(0) ?? 0 }.first == 1
        guard exists else {
            throw TodoStoreError.unavailable(schemaVersion: version)
        }
    }

    /// Reads the stopped reference only when this is still the producer's latest task.
    public func stoppedReference(_ uuid: String, for producer: TaskProducer) async throws -> [TodoRow]? {
        try await store.read { try Self.stoppedReference(uuid, for: producer, in: $0) }
    }

    static func stoppedReference(_ uuid: String, for producer: TaskProducer,
                                 in handle: some SQLiteQuerying) throws -> [TodoRow]? {
        try Self.requireAvailable(in: handle)
        let latest = try handle.query("""
            SELECT task_uuid,status FROM memory_tasks WHERE source = ? AND source_stream_id = ?
            ORDER BY task_id DESC LIMIT 1
            """, [.text(producer.source.rawValue), .text(producer.streamID)]) {
                (try $0.text(0) ?? "", try $0.text(1) ?? "")
            }.first
        guard latest?.0 == uuid, latest?.1 == "abandoned" else { return nil }
        let revisions = try Self.revisions(of: uuid, in: handle)
        guard revisions.last?.change == .stopped else { return nil }
        return try verifiedRows(ofTask: uuid, in: handle)
    }

    /// Returns rows whose latest state retains a passed check, rather than any historical passed check.
    public func verifiedRows(ofTask taskID: String) async throws -> [TodoRow] {
        try await store.read { try Self.verifiedRows(ofTask: taskID, in: $0) }
    }

    static func verifiedRows(ofTask uuid: String, in handle: some SQLiteQuerying) throws -> [TodoRow] {
        let rows = try current(of: uuid, in: handle)?.rows ?? []
        let passed = Set(try handle.query("""
            SELECT i.row_key FROM memory_todo_items i JOIN memory_tasks t ON t.task_id = i.task_id
            JOIN memory_todo_item_states s ON s.item_id = i.item_id
            WHERE t.task_uuid = ? AND s.status = 'done' AND s.check_verdict = 'passed'
                AND s.todo_revision_id = (SELECT max(latest.todo_revision_id) FROM memory_todo_item_states latest
                    WHERE latest.item_id = i.item_id)
            """, [.text(uuid)]) { TodoRowID(rawValue: try $0.text(0) ?? "") })
        return rows.filter { passed.contains($0.id) }
    }

    /// Restores an app's reference only within the same recorded producer and trace.
    public func stoppedTask(for producer: TaskProducer, traceID: String?) async throws
        -> (taskID: String, verifiedRows: [TodoRow])? {
        try await store.read { try Self.stoppedTask(for: producer, traceID: traceID, in: $0) }
    }

    static func stoppedTask(for producer: TaskProducer, traceID: String?, in handle: some SQLiteQuerying) throws
        -> (taskID: String, verifiedRows: [TodoRow])? {
        try requireAvailable(in: handle)
        guard let traceID, !traceID.isEmpty else { return nil }
        let uuid = try handle.query("""
            SELECT task_uuid FROM memory_tasks WHERE source = ? AND source_stream_id = ? AND trace_id = ?
            ORDER BY task_id DESC LIMIT 1
            """, [.text(producer.source.rawValue), .text(producer.streamID), .text(traceID)]) { try $0.text(0) }.first ?? nil
        guard let uuid, let rows = try stoppedReference(uuid, for: producer, in: handle) else { return nil }
        return (uuid, rows)
    }

    /// Supplies stable part identities and their recorded spans for a proposal's source versions.
    public func parts(in versions: [String]) async throws -> [(id: String, version: String, first: Int, last: Int)] {
        guard !versions.isEmpty else { return [] }
        return try await store.read { handle in
            try Self.requireAvailable(in: handle)
            let placeholders = Array(repeating: "?", count: versions.count).joined(separator: ",")
            return try handle.query("""
                SELECT p.part_uuid,r.route_uuid,p.first_position,p.last_position
                FROM memory_routes r JOIN memory_procedure_parts p ON p.route_id = r.route_id
                WHERE r.route_uuid IN (\(placeholders)) ORDER BY p.part_id
                """, versions.map(SQLiteValue.text)) { (id: try $0.text(0) ?? "", version: try $0.text(1) ?? "",
                             first: Int($0.integer(2) ?? 0), last: Int($0.integer(3) ?? 0)) }
        }
    }

    package static func append(_ revision: TodoRevision, expecting: Int, in tx: SQLiteTransaction) throws -> Todo {
        try requireAvailable(in: tx)
        let task = try taskID(revision.taskID, in: tx)
        let prior = try revisions(of: revision.taskID, in: tx)
        let number = prior.last?.number ?? 0
        guard number == expecting, expecting < Int.max, revision.number == expecting + 1 else {
            throw TodoStoreError.staleRevision(expected: expecting, current: number)
        }
        guard revision.rows.filter({ $0.status != .abandoned }).count <= Todo.rowLimit,
              Set(revision.rows.map(\.id)).count == revision.rows.count else {
            throw TodoStoreError.invalid("Invalid row count or duplicate row identity.")
        }
        for row in revision.rows {
            let suffix = row.id.rawValue.dropFirst()
            guard row.id.rawValue.first == "r", suffix.first != "0", !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !row.title.isEmpty, row.title.count <= Todo.titleLimit,
                  (row.expected?.texts.joined().count ?? 0) <= Todo.expectedLimit else {
                throw TodoStoreError.invalid("Invalid row identity, title or expectation length.")
            }
        }
        guard Set(prior.last?.rows.map(\.id) ?? []).isSubset(of: Set(revision.rows.map(\.id))) else {
            throw TodoStoreError.invalid("Removed rows must remain as abandoned history.")
        }
        let taskRevision = try tx.query(
            "SELECT task_revision_id FROM memory_task_revisions WHERE task_id = ? ORDER BY revision DESC LIMIT 1",
            [.integer(task)]
        ) { $0.integer(0) }.first ?? nil
        guard let taskRevision else { throw TodoStoreError.unknownTask(revision.taskID) }
        let (kind, reason) = code(revision.change)
        guard (reason?.utf8.count ?? 0) <= 200 else { throw TodoStoreError.invalid("Reason exceeds 200 bytes.") }
        try tx.execute("""
            INSERT INTO memory_todo_revisions (task_id,revision,task_revision_id,reason_kind,reason_text,recorded_at_ms)
            VALUES (?,?,?,?,?,?)
            """, [.integer(task), .integer(Int64(revision.number)), .integer(taskRevision), .text(kind),
                  reason.map(SQLiteValue.text) ?? .null, .integer(revision.recordedAtMS)])
        let revisionID = try scalar("SELECT last_insert_rowid()", [], in: tx)
        let previous = prior.last?.rows ?? []
        for (position, row) in revision.rows.enumerated() {
            let oldPosition = previous.firstIndex { $0.id == row.id }
            let old = oldPosition.map { previous[$0] }
            var itemID = try tx.query("SELECT item_id FROM memory_todo_items WHERE task_id = ? AND row_key = ?",
                                     [.integer(task), .text(row.id.rawValue)]) { $0.integer(0) }.first ?? nil
            if itemID == nil {
                try tx.execute("""
                    INSERT INTO memory_todo_items (item_uuid,task_id,first_revision,row_key,origin) VALUES (?,?,?,?,'plan')
                    """, [.text(UUID().uuidString), .integer(task), .integer(Int64(revision.number)), .text(row.id.rawValue)])
                itemID = try scalar("SELECT last_insert_rowid()", [], in: tx)
            }
            guard let itemID else { throw TodoStoreError.invalid("Missing row identity.") }
            let encoded = try TodoExpectationColumns.encode(row.expected, taskID: task, in: tx)
            let oldEncoded = try TodoExpectationColumns.encode(old?.expected, taskID: task, in: tx)
            var comparable = row
            comparable.expected = old?.expected
            let revisedExpectation = revision.revisedExpectations.contains(row.id)
            if old == comparable, encoded == oldEncoded, oldPosition == position, !revisedExpectation { continue }
            var expectationID = try tx.query("""
                SELECT expectation_revision_id FROM memory_todo_item_states WHERE item_id = ?
                ORDER BY todo_revision_id DESC LIMIT 1
                """, [.integer(itemID)]) { $0.integer(0) }.first ?? nil
            if old == nil || encoded != oldEncoded || revisedExpectation {
                expectationID = row.expected == nil ? nil : revisionID
                if let encoded {
                    try encoded.insert(itemID: itemID, revisionID: revisionID, in: tx)
                }
            }
            let closed = row.status == .done || row.status == .abandoned
            let closer = kind == "stopped" ? "braus" : "agent"
            let verdict: String?
            if case .rowFinished(let id, let result) = revision.change, id == row.id {
                verdict = result?.rawValue
            } else if revisedExpectation || encoded != oldEncoded || old?.app != row.app || (old?.status == .done && row.status == .pending) {
                verdict = "unknown"
            } else {
                verdict = try tx.query("""
                    SELECT check_verdict FROM memory_todo_item_states WHERE item_id = ?
                    ORDER BY todo_revision_id DESC LIMIT 1
                    """, [.integer(itemID)]) { try $0.text(0) }.first ?? nil
            }
            let partID = try row.part.map { part -> Int64 in
                guard let id = try tx.query("SELECT part_id FROM memory_procedure_parts WHERE part_uuid = ?",
                                            [.text(part)], { $0.integer(0) }).first ?? nil else {
                    throw TodoStoreError.invalid("Unknown memory part.")
                }
                return id
            }
            try tx.execute("""
                INSERT INTO memory_todo_item_states (item_id,todo_revision_id,position,title,app_name,linked_part_id,
                    status,closed_by,check_verdict,expectation_revision_id) VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.integer(itemID), .integer(revisionID), .integer(Int64(position)), .text(row.title),
                      row.app.map(SQLiteValue.text) ?? .null, partID.map(SQLiteValue.integer) ?? .null,
                      .text(row.status.rawValue), closed ? .text(closer) : .null,
                      verdict.map(SQLiteValue.text) ?? .null, expectationID.map(SQLiteValue.integer) ?? .null])
        }
        for call in revision.attributedCalls {
            guard let event = try tx.query("SELECT event_id FROM memory_events WHERE event_uuid = ?",
                                           [.text(call.eventID)], { $0.integer(0) }).first ?? nil else {
                throw TodoStoreError.unknownCall(call.eventID)
            }
            guard let item = try tx.query("SELECT item_id FROM memory_todo_items WHERE task_id = ? AND row_key = ?",
                                          [.integer(task), .text(call.row.rawValue)], { $0.integer(0) }).first ?? nil else {
                throw TodoStoreError.invalid("Call names an unknown row.")
            }
            try tx.execute("INSERT INTO memory_call_steps (event_id,item_id) VALUES (?,?)", [.integer(event), .integer(item)])
        }
        return Todo(taskID: revision.taskID, revision: revision.number, rows: revision.rows)
    }

    static func current(of taskID: String, in handle: some SQLiteQuerying) throws -> Todo? {
        guard let last = try revisions(of: taskID, in: handle).last else { return nil }
        return Todo(taskID: taskID, revision: last.number, rows: last.rows)
    }

    static func revisions(of uuid: String, in handle: some SQLiteQuerying) throws -> [TodoRevision] {
        try requireAvailable(in: handle)
        guard let task = try handle.query("SELECT task_id FROM memory_tasks WHERE task_uuid = ?",
                                         [.text(uuid)], { $0.integer(0) }).first ?? nil else { return [] }
        let revisions = try handle.query("""
            SELECT todo_revision_id,revision,reason_kind,reason_text,recorded_at_ms FROM memory_todo_revisions
            WHERE task_id = ? ORDER BY revision
            """, [.integer(task)]) {
                (id: $0.integer(0) ?? 0, number: Int($0.integer(1) ?? 0), kind: try $0.text(2) ?? "",
                 reason: try $0.text(3), at: $0.integer(4) ?? 0)
            }
        var result: [TodoRevision] = []
        var previous: [TodoRow] = []
        for revision in revisions {
            let rows = try handle.query("""
                SELECT i.row_key,s.title,s.app_name,s.status,p.part_uuid,s.expectation_revision_id,s.item_id
                FROM memory_todo_items i JOIN memory_todo_item_states s ON s.item_id = i.item_id
                LEFT JOIN memory_procedure_parts p ON p.part_id = s.linked_part_id
                WHERE i.task_id = ? AND s.todo_revision_id = (
                    SELECT max(s2.todo_revision_id) FROM memory_todo_item_states s2
                    WHERE s2.item_id = i.item_id AND s2.todo_revision_id <= ?)
                ORDER BY s.position,i.item_id
                """, [.integer(task), .integer(revision.id)]) { row in
                    TodoRow(id: TodoRowID(rawValue: try row.text(0) ?? ""), title: try row.text(1) ?? "",
                            app: try row.text(2), status: TodoRow.Status(rawValue: try row.text(3) ?? "") ?? .pending,
                            part: try row.text(4), expected: try TodoExpectationColumns.read(
                                itemID: row.integer(6) ?? 0, revisionID: row.integer(5), in: handle))
                }
            let changed = rows.first { row in previous.first(where: { $0.id == row.id })?.status != row.status }
            let change: TodoRevision.Change
            switch revision.kind {
            case "drafted": change = .drafted
            case "revised": change = .revised(reason: revision.reason)
            case "stopped": change = .stopped
            case "row_started":
                guard let row = rows.first(where: { $0.status == .inProgress }) else {
                    throw TodoStoreError.invalid("Missing started row.")
                }
                change = .rowStarted(row.id)
            case "row_finished":
                guard let row = changed else { throw TodoStoreError.invalid("Missing finished row.") }
                let verdict = try handle.query("""
                    SELECT s.check_verdict FROM memory_todo_item_states s JOIN memory_todo_items i USING(item_id)
                    WHERE i.task_id = ? AND i.row_key = ? AND s.todo_revision_id <= ?
                    ORDER BY s.todo_revision_id DESC LIMIT 1
                    """, [.integer(task), .text(row.id.rawValue), .integer(revision.id)]) { try $0.text(0) }.first ?? nil
                change = .rowFinished(row.id, verdict: verdict.flatMap(TodoRevision.RowVerdict.init(rawValue:)))
            default: throw TodoStoreError.invalid("Unsupported todo revision kind.")
            }
            result.append(TodoRevision(taskID: uuid, number: revision.number, change: change, rows: rows,
                                       recordedAtMS: revision.at))
            previous = rows
        }
        return result
    }

    static func attributedCalls(ofTask uuid: String, item: TodoRowID?,
                                        in handle: some SQLiteQuerying) throws -> [CallAttribution] {
        try requireAvailable(in: handle)
        return try handle.query("""
            SELECT e.event_uuid,i.row_key FROM memory_call_steps c
            JOIN memory_events e USING(event_id) JOIN memory_todo_items i USING(item_id)
            JOIN memory_tasks t ON t.task_id = i.task_id WHERE t.task_uuid = ? AND (? IS NULL OR i.row_key = ?)
            ORDER BY c.event_id
            """, [.text(uuid), item.map { .text($0.rawValue) } ?? .null, item.map { .text($0.rawValue) } ?? .null]) {
                CallAttribution(eventID: try $0.text(0) ?? "", row: TodoRowID(rawValue: try $0.text(1) ?? ""))
            }
    }

    static func record(_ evidence: TaskEndCheck, attempt: String, in tx: SQLiteTransaction) throws {
        let occurrence = try tx.query(
            "SELECT task_occurrence_id FROM memory_task_occurrences WHERE task_occurrence_uuid = ?",
            [.text(attempt)], { $0.integer(0) }).first ?? nil
        guard let occurrence else { throw TodoStoreError.invalid("Unknown task attempt.") }
        try tx.execute("""
            INSERT INTO memory_task_end_checks (task_occurrence_id,verdict,scope,goal_match) VALUES (?,?,?,?)
            """, [.integer(occurrence), .text(evidence.verdict.rawValue), .text(evidence.scope.rawValue),
                  .integer(evidence.goalMatch ? 1 : 0)])
    }

    private static func taskID(_ uuid: String, in handle: some SQLiteQuerying) throws -> Int64 {
        guard let id = try handle.query("SELECT task_id FROM memory_tasks WHERE task_uuid = ?", [.text(uuid)], { $0.integer(0) }).first ?? nil else { throw TodoStoreError.unknownTask(uuid) }
        return id
    }

    private static func scalar(_ sql: String, _ values: [SQLiteValue], in handle: some SQLiteQuerying) throws -> Int64 {
        guard let value = try handle.query(sql, values, { $0.integer(0) }).first ?? nil else {
            throw TodoStoreError.invalid("Missing stored identity.")
        }
        return value
    }

    private static func code(_ change: TodoRevision.Change) -> (String, String?) {
        switch change {
        case .drafted: ("drafted", nil)
        case .revised(let reason): ("revised", reason)
        case .rowStarted: ("row_started", nil)
        case .rowFinished: ("row_finished", nil)
        case .stopped: ("stopped", nil)
        }
    }
}
