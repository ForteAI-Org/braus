import EngineCore
import Memory

/// Owns candidate and occurrence keys inside the caller's single write reservation.
enum DB2CProcedureCandidateRows {
    static func build(_ transaction: SQLiteTransaction, attemptID: String, producer: TaskProducer?, at nowMS: Int64)
        throws -> (receipt: MemoryReceipt, candidate: ProcedureCandidate)? {
        let read = try DB2CReadRows(transaction)
        guard let attempt = try SQLiteTaskContextRows.attempt(read, attemptID) else {
            throw TaskContextError.unknownAttempt(attemptID: attemptID)
        }
        if let producer { _ = try SQLiteTaskContextRows.owned(read, attempt.attempt.taskID, by: producer) }
        let calls = try SQLiteProcedureRows.attemptCalls(transaction, attemptID: attemptID)
        let checkpoint = try SQLiteTaskContextRows.checkpoints(read, of: attemptID).last?.sequence
        guard let offered = try ProcedureCandidate.of(calls, taskID: attempt.attempt.taskID, attemptID: attemptID,
                                                      checkpointSequence: checkpoint, builtAtMS: nowMS) else { return nil }
        let steps = try offered.steps.map { step in
            ProcedureCandidate.Step(position: step.position, stepOccurrenceID: try occurrence(transaction, step: step, attemptID: attemptID),
                callEventID: step.callEventID, blockIndex: step.blockIndex, bundleID: step.bundleID, kind: step.kind)
        }
        var canonical = offered.policyVersion
        for step in steps {
            canonical += "\n\(step.callEventID.utf8.count):" + step.callEventID
            if offered.policyVersion == ProcedureSegmentation.mixedPolicyVersion { canonical += "\u{1F}" + step.kind.rawValue }
        }
        let digest = SQLiteValue.blob(Array(Digest16.of(canonical)))
        let attemptKey = try DB2CIdentity.key(transaction, "memory_task_occurrences", attemptID)
        if let existing = try transaction.query("""
            SELECT candidate_id FROM memory_procedure_candidates WHERE task_occurrence_id=? AND structure_digest=? AND policy_version=?
            ORDER BY candidate_id
            """, [attemptKey, digest, .text(offered.policyVersion)]) { $0.integer(0) }.first ?? nil {
            guard let saved = try SQLiteProcedureRows.candidate(transaction, String(existing)), saved.steps == steps else {
                throw SQLiteProcedureRows.malformed("memory_procedure_candidates", String(existing), "structure digest collision")
            }
            try DB2CCoherence.validate(transaction)
            return (.alreadyApplied, saved)
        }
        let checkpointID = try checkpoint.flatMap { sequence in
            try transaction.query("SELECT checkpoint_id FROM memory_task_checkpoints WHERE task_occurrence_id=? AND sequence=?",
                [attemptKey, .integer(Int64(sequence))]) { $0.integer(0) }.first ?? nil
        }
        try transaction.execute("""
            INSERT INTO memory_procedure_candidates(task_id,task_occurrence_id,policy_version,structure_digest,checkpoint_sequence,
                built_at_ms,step_count,block_count,checkpoint_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [try DB2CIdentity.key(transaction, "memory_tasks", offered.taskID), attemptKey, .text(offered.policyVersion), digest,
                    checkpoint.map { .integer(Int64($0)) } ?? .null, .integer(nowMS), .integer(Int64(steps.count)),
                    .integer(Int64(offered.blocks.count)), checkpointID.map(SQLiteValue.integer) ?? .null])
        let id = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
        for step in steps {
            let app = try step.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute("""
                INSERT INTO memory_candidate_steps(candidate_id,position,step_occurrence_id,call_event_id,block_index,app_id,step_kind)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.integer(id), .integer(Int64(step.position)), Int64(step.stepOccurrenceID).map(SQLiteValue.integer) ?? .null,
                        try DB2CIdentity.key(transaction, "memory_events", step.callEventID), .integer(Int64(step.blockIndex)),
                        app.map(SQLiteValue.integer) ?? .null, .text(step.kind.rawValue)])
        }
        try DB2CCoherence.validate(transaction)
        guard let saved = try SQLiteProcedureRows.candidate(transaction, String(id)) else {
            throw SQLiteProcedureRows.malformed("memory_procedure_candidates", String(id), "missing after insert")
        }
        return (.committed, saved)
    }

    private static func occurrence(_ transaction: SQLiteTransaction, step: ProcedureCandidate.Step, attemptID: String) throws -> String {
        let call = try DB2CIdentity.key(transaction, "memory_events", step.callEventID)
        let attempt = try DB2CIdentity.key(transaction, "memory_task_occurrences", attemptID)
        guard let facts = try transaction.query("""
            SELECT a.execution_status,coalesce(a.started_at_ms,e.occurred_at_ms),a.completed_at_ms
            FROM memory_agent_actions a JOIN memory_events e USING(event_id) WHERE a.event_id=?
            """, [call], { (try $0.text(0) ?? "", $0.integer(1) ?? 0, $0.integer(2)) }).first else {
            throw ProcedureError.unknownReference("call \(step.callEventID)")
        }
        let status: TaskStatus = switch facts.0 {
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        case "interrupted": .interrupted
        default: .inProgress
        }
        let end = facts.2.flatMap { $0 >= facts.1 ? $0 : nil }.map(SQLiteValue.integer) ?? .null
        let id: Int64
        if let existing = try transaction.query("SELECT step_occurrence_id FROM memory_step_events WHERE event_id=? AND role='action'", [call], {
            $0.integer(0)
        }).first ?? nil {
            id = existing
            let owner = try transaction.query("SELECT task_occurrence_id=? FROM memory_step_occurrences WHERE step_occurrence_id=?", [attempt, .integer(id)]) {
                $0.integer(0) == 1
            }.first == true
            guard owner else { throw EventFactError.alreadyAttributed(eventID: step.callEventID) }
            try transaction.execute("UPDATE memory_step_occurrences SET ended_at_ms=?,status=? WHERE step_occurrence_id=?",
                                    [end, .text(status.rawValue), .integer(id)])
        } else {
            try transaction.execute("""
                INSERT INTO memory_step_occurrences(task_occurrence_id,started_at_ms,ended_at_ms,status,assigned_by) VALUES (?, ?, ?, ?, ?)
                """, [attempt, .integer(facts.1), end, .text(status.rawValue), .text(SQLiteProcedureRepository.segmentationAuthor)])
            id = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
            try transaction.execute("INSERT INTO memory_step_events(step_occurrence_id,event_id,position,attempt_number,role) VALUES (?, ?, 0, 1, 'action')",
                                    [.integer(id), call])
        }
        let verifications = try transaction.query("""
            SELECT v.event_id,b.step_occurrence_id FROM memory_operation_verifications v JOIN memory_verifications b USING(event_id)
            WHERE v.call_event_id=? ORDER BY v.event_id
            """, [call]) { ($0.integer(0) ?? 0, $0.integer(1)) }
        for (event, owner) in verifications {
            guard owner == nil || owner == id else { throw EventFactError.alreadyAttributed(eventID: String(event)) }
            let exists = try transaction.query("SELECT count(*) FROM memory_step_events WHERE step_occurrence_id=? AND event_id=? AND role='verification'",
                                              [.integer(id), .integer(event)]) { $0.integer(0) ?? 0 }.first ?? 0
            if exists > 0 { continue }
            if owner == nil { try transaction.execute("UPDATE memory_verifications SET step_occurrence_id=? WHERE event_id=?", [.integer(id), .integer(event)]) }
            let position = try transaction.query("SELECT coalesce(max(position),0)+1 FROM memory_step_events WHERE step_occurrence_id=?", [.integer(id)]) {
                $0.integer(0) ?? 0
            }.first ?? 0
            try transaction.execute("INSERT INTO memory_step_events(step_occurrence_id,event_id,position,attempt_number,role) VALUES (?, ?, ?, NULL, 'verification')",
                                    [.integer(id), .integer(event), .integer(position)])
        }
        return String(id)
    }
}
