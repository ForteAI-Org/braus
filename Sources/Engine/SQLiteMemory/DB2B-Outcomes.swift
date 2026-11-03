import EngineCore
import Memory

/// DB2BOutcomes stores ES1 delivery, effect and recovery using the producer's concluded evidence.
enum DB2BOutcomes {
    /// Reads the historical result vocabulary from typed outcomes for retained call consumers.
    static func legacyKindSQL(_ handle: some SQLiteQuerying, alias: String) throws -> String {
        let column = "\(alias).result_kind"
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return column }
        return """
            coalesce(\(column), CASE
                WHEN \(alias).gesture IS NULL THEN NULL
                WHEN \(alias).gesture <> 'not_sent' THEN
                    CASE WHEN \(alias).effect = 'confirmed' OR \(alias).recovery = 'continue'
                         THEN 'found_acted' ELSE 'acted_unverified' END
                WHEN \(alias).recovery = 'change_target' AND \(alias).recovery_reason = 'not_found' THEN 'honest_miss'
                WHEN \(alias).recovery = 'change_target' AND \(alias).recovery_reason = 'ambiguous' THEN 'ambiguous'
                WHEN \(alias).recovery = 'continue' THEN 'acted_noop'
                ELSE 'refused' END)
            """
    }

    static func columns(
        _ handle: some SQLiteQuerying,
        eventID: String,
        progress: AgentCallProgress,
        conclusion: OperationConclusion?
    ) throws -> [SQLiteValue]? {
        // A dry run has no distinct ES1 row; preserve its existing result identity.
        guard case .outcome(let kind, _)? = progress.result, kind != .dryRun else { return nil }
        let isToggle =
            try handle.query(
                "SELECT text_value FROM memory_operation_arguments WHERE event_id=? AND argument_name='verb' AND position=0",
                [SQLiteRowIdentity(handle).key(.event, eventID)]
            ) { try $0.text(0) }.first == "set_toggle"
        let noop: NoopKind? = kind == .actedNoop && isToggle ? .statePresent : nil
        // A synthesized no-oracle check declares missing evidence, not a different producer result.
        let check = conclusion?.verifications.first { $0.check.condition != .none }?.check
        let cause = conclusion?.effect?.notSentReason.flatMap(NotSentCause.init(rawValue:))
        let attached = conclusion?.samples.contains { $0.key.phase == .after } ?? false
        let outcome = Outcome.converting(kind, check: check, notSent: cause, noop: noop, sceneAttached: attached)
        return SQLiteMigration22Outcomes.Columns(
            outcome: outcome,
            origin: "recorded",
            learnable: check?.verdict == .passed && outcome.effect == .confirmed
        ).bindings
    }

    static func kind(_ row: SQLiteStatement.Row, eventID: String) throws -> ActOutcomeKind? {
        guard let gesture = try row.text(19) else { return nil }
        guard let effect = try row.text(20), let recovery = try row.text(22) else {
            throw AgentCallError.malformedCall(eventID: eventID, malformation: .resultShape("outcome"))
        }
        let reason = try row.text(21)
        let effectText =
            reason == "not_applicable"
            ? "not_applicable"
            : effect == "unknown" ? "unknown(\(reason ?? ""))" : effect
        let recoveryText = recovery == "change_target" ? "change_target(\(try row.text(23) ?? ""))" : recovery
        guard let outcome = Outcome.parse("\(gesture) · \(effectText) · \(recoveryText)") else {
            throw AgentCallError.malformedCall(eventID: eventID, malformation: .resultShape("outcome"))
        }
        return outcome.legacyKind
    }
}
