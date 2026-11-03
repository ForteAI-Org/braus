import Memory

extension SQLiteProcedureRows {
    static func insert22(_ transaction: SQLiteTransaction, _ version: ProcedureVersion, contract: [PartContractItem]) throws {
        let ids = try DB2CProcedureVersionKeys(transaction, version: version)
        let interpretation = try transaction.query("SELECT interpretation_id FROM memory_procedure_interpretations WHERE candidate_id=? AND revision=?",
            [Int64(version.candidateID).map(SQLiteValue.integer) ?? .null, .integer(Int64(version.revision))]) { $0.integer(0) }.first ?? nil
        guard let interpretation else { throw malformed("memory_procedure_interpretations", version.candidateID, "missing interpretation") }
        try transaction.execute(
            """
            INSERT INTO memory_procedure_versions (route_id, interpretation_id, candidate_id, task_id, task_occurrence_id,
                contract_version, variant_of_route_id, divergence_position, built_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [try DB2CIdentity.key(transaction, "memory_routes", version.routeID), .integer(interpretation), Int64(version.candidateID).map(SQLiteValue.integer) ?? .null, try DB2CIdentity.key(transaction, "memory_tasks", version.taskID),
             try DB2CIdentity.key(transaction, "memory_task_occurrences", version.attemptID), .integer(Int64(version.contractVersion)), try DB2CIdentity.key(transaction, "memory_routes", version.variantOf),
             version.divergencePosition.map { .integer(Int64($0)) } ?? .null, .integer(version.builtAtMS)]
        )
        for part in version.parts {
            let appID = try part.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute(
                """
                INSERT INTO memory_procedure_parts (part_uuid, route_id, part_kind, parent_part_id, first_position, last_position,
                    step_id, app_id, label, declared_outcome) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(part.partID), try DB2CIdentity.key(transaction, "memory_routes", part.routeID), .text(part.kind.rawValue), try DB2CIdentity.key(transaction, "memory_procedure_parts", part.parentPartID),
                 .integer(Int64(part.firstPosition)), .integer(Int64(part.lastPosition)), try ids.step(part.stepID),
                 appID.map(SQLiteValue.integer) ?? .null, part.label.map(SQLiteValue.text) ?? .null, .text(part.declaredOutcome.rawValue)]
            )
        }
        for detail in version.parameterDetails {
            try transaction.execute(
                """
                INSERT INTO memory_parameter_details (parameter_id, route_id, role, value_kind, unit, sensitivity, produced_by_part_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [try ids.parameter(detail.parameterID), try DB2CIdentity.key(transaction, "memory_routes", version.routeID), .text(detail.role), .text(detail.kind.rawValue),
                 detail.unit.map(SQLiteValue.text) ?? .null, .text(detail.sensitivity.rawValue),
                 try DB2CIdentity.key(transaction, "memory_procedure_parts", detail.producedByPartID)]
            )
        }
        for item in contract {
            let appID = try item.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute(
                """
                INSERT INTO memory_part_contract_items (part_id, position, route_id, item_kind, parameter_id, app_id, scene_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [try DB2CIdentity.key(transaction, "memory_procedure_parts", item.partID), .integer(Int64(item.position)), try DB2CIdentity.key(transaction, "memory_routes", version.routeID), .text(item.kind.rawValue),
                 try ids.parameter(item.parameterID), appID.map(SQLiteValue.integer) ?? .null,
                 try DB2CIdentity.key(transaction, "brain_scenes", item.sceneID)]
            )
        }
        for binding in version.bindings {
            let (content, text): (String, SQLiteValue) = switch binding.content {
                case .text(let value): ("text", .text(value))
                case .missing: ("missing", .null)
                case .withheld: ("withheld", .null)
            }
            try transaction.execute(
                """
                INSERT INTO memory_parameter_bindings (parameter_id, route_id, task_occurrence_id, content, text_value, source,
                    source_ref, source_version, value_digest) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [try ids.parameter(binding.parameterID), try DB2CIdentity.key(transaction, "memory_routes", version.routeID), try DB2CIdentity.key(transaction, "memory_task_occurrences", binding.attemptID), .text(content), text,
                 .text(binding.source.rawValue), binding.sourceRef.map(SQLiteValue.text) ?? .null,
                 binding.sourceVersion.map(SQLiteValue.text) ?? .null, { if case .text(let value) = binding.content { return .blob(Array(Digest16.of(value))) }; return .null }()]
            )
        }
        for occurrence in version.stepOccurrences {
            try transaction.execute(
                "INSERT INTO memory_procedure_step_occurrences (route_id, step_id, step_occurrence_id) VALUES (?, ?, ?)",
                [try DB2CIdentity.key(transaction, "memory_routes", version.routeID), try ids.step(occurrence.stepID), Int64(occurrence.stepOccurrenceID).map(SQLiteValue.integer) ?? .null]
            )
        }
    }

}

/// Resolves definition-local identifiers from the definition's stable positions and exact parameter names.
struct DB2CProcedureVersionKeys {
    private let parameters: [[UInt8]: SQLiteValue]
    private let steps: [[UInt8]: SQLiteValue]

    init(_ handle: some SQLiteQuerying, version: ProcedureVersion) throws {
        let route = try DB2CIdentity.key(handle, "memory_routes", version.routeID)
        let names = Dictionary(uniqueKeysWithValues: try handle.query("SELECT name,parameter_id FROM memory_route_parameters WHERE route_id=?", [route]) {
            (Array((try $0.text(0) ?? "").utf8), SQLiteValue.integer($0.integer(1) ?? 0))
        })
        var parameters: [[UInt8]: SQLiteValue] = [:]
        for parameter in version.definition.parameters {
            guard let key = names[Array(parameter.name.utf8)] else { throw ProcedureError.unknownReference(parameter.parameterID) }
            parameters[Array(parameter.parameterID.utf8)] = key
        }
        self.parameters = parameters
        let positions = Dictionary(uniqueKeysWithValues: try handle.query("SELECT position,step_id FROM memory_route_steps WHERE route_id=?", [route]) {
            (Int($0.integer(0) ?? -1), SQLiteValue.integer($0.integer(1) ?? 0))
        })
        var steps: [[UInt8]: SQLiteValue] = [:]
        for step in version.definition.steps {
            guard let key = positions[step.position] else { throw ProcedureError.unknownReference(step.stepID) }
            steps[Array(step.stepID.utf8)] = key
        }
        self.steps = steps
    }

    func parameter(_ id: String?) throws -> SQLiteValue {
        guard let id else { return .null }
        guard let key = parameters[Array(id.utf8)] else { throw ProcedureError.unknownReference(id) }
        return key
    }

    func step(_ id: String?) throws -> SQLiteValue {
        guard let id else { return .null }
        guard let key = steps[Array(id.utf8)] else { throw ProcedureError.unknownReference(id) }
        return key
    }
}

extension SQLiteProcedureRows {
    static func insertInterpretation22(_ transaction: SQLiteTransaction, _ version: ProcedureVersion, digest: String,
                                      producer: TaskProducer, taskRevision: Int, state: InterpretationState, at nowMS: Int64) throws {
        guard digest.utf8.count == 32 else { throw malformed("memory_procedure_interpretations", version.candidateID, "digest length") }
        let bytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8? in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return UInt8(digest[start..<digest.index(start, offsetBy: 2)], radix: 16)
        }
        guard bytes.allSatisfy({ $0 != nil }) else { throw malformed("memory_procedure_interpretations", version.candidateID, "digest bytes") }
        try transaction.execute("""
            INSERT INTO memory_procedure_interpretations(candidate_id,revision,contract_version,payload_digest,source,source_stream_id,
                task_revision,attempt_state,recorded_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [Int64(version.candidateID).map(SQLiteValue.integer) ?? .null, .integer(Int64(version.revision)),
                    .integer(Int64(version.contractVersion)), .blob(bytes.compactMap { $0 }), .text(producer.source.rawValue),
                    .text(producer.streamID), .integer(Int64(taskRevision)), .text(state.rawValue), .integer(nowMS)])
        let id = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
        for (position, finding) in version.findings.enumerated() {
            try transaction.execute("""
                INSERT INTO memory_interpretation_findings(interpretation_id,position,finding,step_position,argument_name,argument_position)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.integer(id), .integer(Int64(position)), .text(finding.kind.rawValue), .integer(Int64(finding.stepPosition)),
                        .text(finding.argumentName), .integer(Int64(finding.argumentPosition))])
        }
    }

    static func insertQualification22(_ transaction: SQLiteTransaction, _ evaluation: PartQualification, at nowMS: Int64) throws {
        let part = try DB2CIdentity.key(transaction, "memory_procedure_parts", evaluation.partID)
        let next = (try transaction.query("SELECT coalesce(max(sequence),0) FROM memory_part_qualifications WHERE part_id=?", [part]) {
            $0.integer(0) ?? 0
        }.first ?? 0) + 1
        let policy = try transaction.query("SELECT policy_id FROM memory_qualification_policies WHERE policy_version=?", [.text(evaluation.policyVersion)]) {
            $0.integer(0)
        }.first ?? nil
        guard let policy else { throw malformed("memory_qualification_policies", evaluation.policyVersion, "missing policy") }
        try transaction.execute("""
            INSERT INTO memory_part_qualifications(part_id,sequence,policy_id,verdict,evaluated_at_ms,complete) VALUES (?, ?, ?, ?, ?, 0)
            """, [part, .integer(next), .integer(policy), .text(evaluation.verdict.rawValue), .integer(nowMS)])
        let id = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
        for (position, finding) in evaluation.findings.enumerated() {
            try transaction.execute("""
                INSERT INTO memory_part_qualification_reasons(part_id,sequence,position,reason,step_position,call_event_id,qualification_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [part, .integer(next), .integer(Int64(position)), .text(finding.reason.rawValue),
                        finding.stepPosition.map { .integer(Int64($0)) } ?? .null,
                        try DB2CIdentity.key(transaction, "memory_events", finding.callEventID), .integer(id)])
        }
        for item in evaluation.evidence {
            try transaction.execute("""
                INSERT INTO memory_part_qualification_evidence(part_id,sequence,step_position,call_event_id,verification_event_id,origin,qualification_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [part, .integer(next), .integer(Int64(item.stepPosition)), try DB2CIdentity.key(transaction, "memory_events", item.callEventID),
                        try DB2CIdentity.key(transaction, "memory_events", item.verificationEventID), .text(item.isInherited ? "inherited" : "own"), .integer(id)])
        }
        try transaction.execute("UPDATE memory_part_qualifications SET complete=1 WHERE qualification_id=?", [.integer(id)])
        try DB2CCoherence.validate(transaction)
    }
}

extension SQLiteProcedureRows {
    static func setState22(_ transaction: SQLiteTransaction, state: PartOperationalState, partID: String,
                           reason: String, author: String, at nowMS: Int64) throws -> MemoryReceipt {
        let part = try DB2CIdentity.key(transaction, "memory_procedure_parts", partID)
        guard try transaction.query("SELECT count(*) FROM memory_procedure_parts WHERE part_id=?", [part], { $0.integer(0) ?? 0 }).first == 1 else {
            throw ProcedureError.unknownPart(partID: partID)
        }
        let codes: Set<String> = ["qualified", "requalified", "policy_quarantined", "superseded", "judged_wrong", "retired_by_person",
            "retired_by_curation", "forgotten_by_person", "merged_same_screen", "split_distinct_surfaces", "imported", "migrated"]
        let code = (author == "braus-cli" || author == "person") && state == .retired ? "retired_by_person" : codes.contains(reason) ? reason : "migrated"
        let last = try transaction.query("SELECT sequence,state,reason_code FROM memory_part_states WHERE part_id=? ORDER BY sequence DESC LIMIT 1", [part]) {
            ($0.integer(0) ?? 0, try $0.text(1) ?? "", try $0.text(2) ?? "")
        }.first
        if let last {
            if last.1 == PartOperationalState.retired.rawValue {
                if state == .retired { return .alreadyApplied }
                throw ProcedureError.retired(partID: partID)
            }
            if last.1 == state.rawValue && last.2 == code { return .alreadyApplied }
        }
        try transaction.execute("""
            INSERT INTO memory_part_states(part_id,sequence,state,reason_code,recorded_at_ms,recorded_by) VALUES (?, ?, ?, ?, ?, ?)
            """, [part, .integer((last?.0 ?? 0) + 1), .text(state.rawValue), .text(code), .integer(nowMS),
                    .text(author == "braus-cli" || author == "person" ? "person" : "braus")])
        try DB2CCoherence.validate(transaction)
        return .committed
    }
}

extension SQLiteProcedureRows {
    static func recordResult22(_ transaction: SQLiteTransaction, expectation: TaskResultCheck.Expectation,
        read: TaskResultCheck.Expectation?, reading: TaskResultCheck.Reading, asGuard: Bool, attemptID: String,
        eventID: String, producer: TaskProducer, at nowMS: Int64
    ) throws -> TaskResultCheck {
        let snapshot = try DB2CReadRows(transaction)
        guard let attempt = try SQLiteTaskContextRows.attempt(snapshot, attemptID) else {
            throw TaskContextError.unknownAttempt(attemptID: attemptID)
        }
        let judged = TaskResultCheck.judge(read ?? expectation, attemptID: attemptID, openedAtMS: attempt.attempt.openedAtMS, reading: reading)
        let check = TaskResultCheck(attemptID: attemptID, expectation: expectation, verdict: judged.verdict, observed: judged.observed)
        let event = MemoryEventRecord(eventID: eventID, source: producer.source, streamID: producer.streamID,
                                     kind: .verification, occurredAtMS: nowMS, captureStatus: .notApplicable)
        try event.validate()
        if let saved = try SQLiteEventRows.read(snapshot, eventID: eventID) {
            guard saved.hasSameImmutableContent(as: event) else {
                throw SQLiteFactRows.conflict(eventID, stored: saved.contentDigest, offered: event.contentDigest)
            }
        } else {
            try transaction.execute("""
                INSERT INTO memory_events(event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
                VALUES (?, ?, ?, 'verification', ?, 'not_applicable')
                """, [.text(eventID), .text(producer.source.rawValue), .text(producer.streamID), .integer(nowMS)])
        }
        let eventKey = try DB2CIdentity.key(transaction, "memory_events", eventID)
        let attemptKey = try DB2CIdentity.key(transaction, "memory_task_occurrences", attemptID)
        try transaction.execute("INSERT INTO memory_verifications(event_id,scope,method,verdict,expected_text,observed_text) VALUES (?, ?, ?, ?, ?, ?)",
            [eventKey, .text(VerificationScope.task.rawValue), .text((asGuard ? VerificationMethod.guardCheck : expectation.method).rawValue),
             .text(check.verdict.rawValue), .text(expectation.stored), .text(check.observed)])
        let position = try transaction.query("SELECT coalesce(max(position)+1,0) FROM memory_task_events WHERE task_occurrence_id=?", [attemptKey]) {
            $0.integer(0) ?? 0
        }.first ?? 0
        try transaction.execute("INSERT INTO memory_task_events(task_occurrence_id,event_id,position,role) VALUES (?, ?, ?, 'verification')",
                                [attemptKey, eventKey, .integer(position)])
        if let route = try currentVersion(transaction, attemptID: attemptID) {
            try ensurePolicy(transaction, at: nowMS)
            _ = try qualify(transaction, routeID: route, at: nowMS)
        }
        try DB2CCoherence.validate(transaction)
        return check
    }
}
