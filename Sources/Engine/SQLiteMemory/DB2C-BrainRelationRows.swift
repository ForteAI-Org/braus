import EngineCore
import Memory

/// Evaluates live relations without mutating the historical register.
enum DB2CBrainRelationRows {
    static func evaluate(_ transaction: SQLiteTransaction, callEventID: String, cause requested: BrainRelationApplication.Cause,
                         at nowMS: Int64) throws -> BrainRelationApplication {
        let read = try DB2CReadRows(transaction)
        let latest = try SQLiteBrainRelationRows.latest(read, callEventID: callEventID)
        if let latest, !latest.isRecoverable, latest.policyVersion == BrainRelationPolicy.version { return latest }
        let cause: BrainRelationApplication.Cause = switch latest {
            case nil: requested
            case let latest? where latest.policyVersion != BrainRelationPolicy.version: .policy
            case _?: .evidence
        }
        let facts = try facts(transaction, callEventID: callEventID)
        let origin = try transaction.query("SELECT outcome_origin FROM memory_agent_actions WHERE event_id=?",
            [try DB2CIdentity.key(transaction, "memory_events", callEventID)]) { try $0.text(0) }.first ?? nil
        // Partial conversions supply no proof; recorded failures still evaluate contradictions.
        let decision: BrainRelationPolicy.Decision = origin == "converted_partial" && facts.status == .completed
            ? .excluded(.notLearnable) : BrainRelationPolicy.decide(facts)
        let appID = try facts.bundleID.flatMap { try SQLiteIdentityRows.appID(transaction, bundleID: $0) }
        let sequence = (latest?.sequence ?? 0) + 1
        func evaluation(_ outcome: BrainRelationApplication.Outcome, _ exclusion: BrainRelationPolicy.Exclusion?,
                        _ relations: [String]) -> BrainRelationApplication {
            BrainRelationApplication(callEventID: callEventID, sequence: sequence, policyVersion: BrainRelationPolicy.version,
                                     cause: cause, outcome: outcome, exclusion: exclusion, relationIDs: relations)
        }
        var made: BrainRelationApplication
        var evidence: [(relation: String, kind: EvidenceRelation)] = []
        var group: (key: String, effectKind: String?)?
        var created: BrainRelationKey?
        switch decision {
            case .supports(let key):
                guard let appID else { throw AgentCallError.missingCall(eventID: callEventID) }
                let (relationID, isNew) = try ensure(transaction, key, appID: appID, at: nowMS)
                if isNew { created = key }
                evidence = [(relationID, .supports)]
                made = evaluation(.supported, nil, [relationID])
            case .contradicts(let contradicted, let outcome, let effectKind):
                guard let appID else { throw AgentCallError.missingCall(eventID: callEventID) }
                let targets = try SQLiteBrainRelationRows.relations(read, appID: appID, group: contradicted, outcome: outcome, effectKind: effectKind)
                if targets.isEmpty {
                    group = (SQLiteBrainRelationRows.groupKey(contradicted, outcome: outcome), effectKind)
                    made = evaluation(.excluded, .nothingToContradict, [])
                } else {
                    evidence = targets.map { ($0, .contradicts) }
                    made = evaluation(.contradicted, nil, targets)
                }
            case .excluded(let why):
                made = evaluation(.excluded, why, [])
        }
        if let latest, latest.decidesAsWell(made) { return latest }
        let evaluationID = try insert(transaction, made, appID: appID, group: group, at: nowMS)
        if !evidence.isEmpty, facts.verification == nil { throw AgentCallError.missingCall(eventID: callEventID) }
        for (relationID, kind) in evidence {
            guard let verification = facts.verification else { break }
            try transaction.execute(
                """
                INSERT INTO brain_relation_evidence (relation_id, call_event_id, sequence, relation, verification_event_id,
                    policy_version, assessed_at_ms, evaluation_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [try DB2CIdentity.key(transaction, "brain_relations", relationID), try DB2CIdentity.key(transaction, "memory_events", callEventID), .integer(Int64(sequence)), .text(kind.rawValue), try DB2CIdentity.key(transaction, "memory_events", verification.eventID),
                 .text(BrainRelationPolicy.version), .integer(nowMS), .integer(evaluationID)]
            )
            try transaction.execute(
                "UPDATE brain_relations SET last_seen_ms = max(last_seen_ms, ?) WHERE relation_id = ?", [.integer(nowMS), try DB2CIdentity.key(transaction, "brain_relations", relationID)]
            )
        }
        if let created {
            // A failure that came before the relation it contradicts contradicts it now: the order the
            // calls were evaluated in never changes what the facts prove.
            for waiting in try SQLiteBrainRelationRows.waitingContradictions(read, of: created) where waiting != callEventID {
                _ = try evaluate(transaction, callEventID: waiting, cause: .evidence, at: nowMS)
            }
        }
        try DB2CCoherence.validate(transaction)
        return made
    }

    static func facts(_ transaction: SQLiteTransaction, callEventID: String) throws -> BrainRelationPolicy.Facts {
        let handle = try DB2CReadRows(transaction)
        guard let call = try DB2CProcedureCallRows.read(transaction, eventID: callEventID),
              let event = try SQLiteEventRows.read(handle, eventID: callEventID) else { throw AgentCallError.missingCall(eventID: callEventID) }
        let id = callEventID
        let context = try handle.query("SELECT context_id FROM memory_events WHERE event_id = ?", [.text(id)]) { $0.integer(0) }.first ?? nil
        let gaps = try SQLiteOperationFactRows.recordingGaps(handle, id)
        let withheldKinds: Set<String> = ["target_label", "target_element", "target_section", "observed_effect"]
        // A withheld nonparameter could combine distinct choices into one relation key.
        // Such a call teaches nothing, as for a withheld target.
        let parameters = Set(BrainRelationPolicy.verbAndArguments(of: call.request)
            .flatMap { BrainRelationPolicy.argumentRoles[$0.verb] }?
            .filter { $0.role == .parameter }.map(\.argument) ?? [])
        let withheld = try handle.query(
            "SELECT location_kind, argument_name FROM memory_value_redactions WHERE event_id = ?", [.text(id)]
        ) { (kind: try $0.text(0) ?? "", argument: try $0.text(1)) }.contains { redaction in
            withheldKinds.contains(redaction.kind)
                || (redaction.kind == "argument" && !parameters.contains(redaction.argument ?? ""))
        }
        let verificationIDs = try handle.query(
            "SELECT event_id FROM memory_operation_verifications WHERE call_event_id = ? ORDER BY event_id", [.text(id)]
        ) { try $0.text(0) ?? "" }
        let verification = try verificationIDs.first.flatMap { try SQLiteOperationFactRows.verification(handle, $0) }
        let effectKind = try handle.query(
            "SELECT observed_effect_kind FROM memory_agent_actions WHERE event_id = ?", [.text(id)]
        ) { try $0.text(0) }.first ?? nil
        let effect = try SQLiteOperationFactRows.effect(handle, id)
        let target = verification?.check.target ?? effect?.target
        let before = try SQLiteObservationRows.sample(handle, key: CaptureSampleKey(eventID: id, phase: .before))
        let from = try SQLiteProcedureRows.confirmedScene(handle, eventID: id, phase: .before)
        var to = try SQLiteProcedureRows.confirmedScene(handle, eventID: id, phase: .after)
        if verification?.check.condition == .requestedStateAlreadyPresent { to = from }
        return BrainRelationPolicy.Facts(
            callEventID       : id,
            bundleID          : event.app?.bundleID,
            contextID         : context,
            request           : call.request,
            status            : call.status,
            hasRecordingGap   : !gaps.isEmpty,
            hasWithheldTarget : withheld,
            verification      : verification.map {
                QualificationPolicy.VerificationFact(eventID: $0.event.eventID, condition: $0.check.condition,
                                                     verdict: $0.check.verdict, performed: $0.check.performed,
                                                     limits: $0.check.limits)
            },
            expected          : verification?.check.expected,
            observed          : verification?.check.observed,
            observedEffectKind: effectKind,
            targetRole        : target?.role,
            targetLabel       : target?.label,
            fromSceneID       : from,
            toSceneID         : to,
            beforeAwaitsState : from == nil ? try SQLiteBrainRelationRows.awaitsState(handle, CaptureSampleKey(eventID: id, phase: .before)) : false,
            afterAwaitsState  : to == nil ? try SQLiteBrainRelationRows.awaitsState(handle, CaptureSampleKey(eventID: id, phase: .after)) : false,
            beforeElements    : before?.elements ?? []
        )
    }

}

extension DB2CBrainRelationRows {
    private static func insert(_ transaction: SQLiteTransaction, _ made: BrainRelationApplication, appID: Int64?,
                               group: (key: String, effectKind: String?)?, at nowMS: Int64) throws -> Int64 {
        try transaction.execute("""
            INSERT INTO brain_relation_evaluations(call_event_id,sequence,app_id,policy_version,cause,outcome,reason,recoverable,
                group_key,expected_effect_kind,evaluated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [try DB2CIdentity.key(transaction, "memory_events", made.callEventID), .integer(Int64(made.sequence)),
                    appID.map(SQLiteValue.integer) ?? .null, .text(made.policyVersion), .text(made.cause.rawValue), .text(made.outcome.rawValue),
                    made.exclusion.map { .text($0.rawValue) } ?? .null, .integer(made.isRecoverable ? 1 : 0),
                    group.map { .text($0.key) } ?? .null, group?.effectKind.map(SQLiteValue.text) ?? .null, .integer(nowMS)])
        return try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
    }

    private static func ensure(_ transaction: SQLiteTransaction, _ key: BrainRelationKey, appID: Int64, at nowMS: Int64) throws -> (String, Bool) {
        let id = key.relationID
        if let saved = try SQLiteBrainRelationRows.relation(try DB2CReadRows(transaction), relationID: id) {
            guard saved == key else { throw SQLiteFactRows.conflict(id, stored: "\(saved)", offered: "\(key)") }
            return (id, false)
        }
        let scene = try DB2CIdentity.key(transaction, "brain_scenes", key.fromSceneID)
        let element = try key.elementKey.flatMap { text in
            try transaction.query("SELECT scene_element_id FROM brain_scene_elements WHERE scene_id=? AND element_key=?", [scene, .text(text)]) {
                $0.integer(0)
            }.first ?? nil
        }
        var elementKey: SQLiteValue = .null
        if let text = key.elementKey {
            let digest = Array(Digest16.of(text))
            if let existing = try transaction.query("SELECT element_key_id,key_text FROM brain_element_keys WHERE app_id=? AND digest=? AND replaced_by_id IS NULL",
                [.integer(appID), .blob(digest)], { ($0.integer(0) ?? 0, try $0.text(1) ?? "") }).first {
                guard existing.1.utf8.elementsEqual(text.utf8) else { throw SQLiteBrainRelationRows.malformed("brain_element_keys", text, "digest collision") }
                elementKey = .integer(existing.0)
            } else {
                try transaction.execute("INSERT INTO brain_element_keys(app_id,key_text,digest,first_seen_ms) VALUES (?, ?, ?, ?)",
                                        [.integer(appID), .text(text), .blob(digest), .integer(nowMS)])
                elementKey = .integer(try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0)
            }
        }
        try transaction.execute("""
            INSERT INTO brain_relations(relation_uuid,app_id,context_id,from_scene_id,element_key_id,scene_element_id,verb,arguments_key,
                to_scene_id,outcome,effect_kind,first_seen_ms,last_seen_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), .integer(appID), key.contextID.map(SQLiteValue.integer) ?? .null, scene, elementKey,
                    element.map(SQLiteValue.integer) ?? .null, .text(key.verb.rawValue), .text(key.argumentsKey),
                    try DB2CIdentity.key(transaction, "brain_scenes", key.toSceneID), .text(key.outcome.rawValue),
                    key.effectKind.map(SQLiteValue.text) ?? .null, .integer(nowMS), .integer(nowMS)])
        return (id, true)
    }
}
