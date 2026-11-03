import EngineCore
import Memory

/// SQLiteMigration22Outcomes converts historical gesture results before destination history guards are installed.
/// Source SQL is deliberately independent of repositories, which will subsequently write schema 22.
enum SQLiteMigration22Outcomes {
    struct Columns {
        let outcome: Outcome
        let origin: String
        let learnable: Bool

        var bindings: [SQLiteValue] {
            let effect: String
            let reason: SQLiteValue
            switch outcome.effect {
            case .confirmed: (effect, reason) = ("confirmed", .null)
            case .absent: (effect, reason) = ("absent", .null)
            case .unknown(let unknown): (effect, reason) = ("unknown", .text(unknown.rawValue))
            case .notApplicable: (effect, reason) = ("unknown", .text("not_applicable"))
            }
            let recovery: String
            let recoveryReason: SQLiteValue
            if case .changeTarget(let blocked) = outcome.recovery {
                (recovery, recoveryReason) = ("change_target", .text(blocked.rawValue))
            } else {
                (recovery, recoveryReason) = (outcome.recovery.text, .null)
            }
            return [.text(outcome.gesture.rawValue), .text(effect), reason, .text(recovery), recoveryReason,
                    .text(origin), .integer(learnable ? 1 : 0)]
        }
    }

    struct Report: Equatable {
        var converted = 0
        var partiallyConverted = 0
    }

    /// Applies R-E-40 using only saved evidence. An absent effect or verdict never manufactures a complete check.
    static func columns(
        kind: ActOutcomeKind,
        tool: AgentTool,
        verb: String?,
        hasEffect: Bool,
        check: OperationCheck?,
        notSent: NotSentCause?,
        sceneAttached: Bool
    ) -> Columns {
        let complete = hasEffect && check != nil
        let noop: NoopKind?
        if kind == .actedNoop, tool == .act, verb == "set_toggle" { noop = .statePresent }
        else if kind == .actedNoop, tool == .menu { noop = .listing }
        else { noop = nil }
        let historicalCause: NotSentCause?
        switch notSent {
        case .needsConsent, .destructiveUnverifiable, .disabled: historicalCause = nil
        default: historicalCause = notSent
        }
        let outcome = Outcome.converting(kind, check: complete ? check : nil, notSent: historicalCause,
                                         noop: noop, sceneAttached: sceneAttached)
        return Columns(outcome: outcome, origin: complete ? "converted" : "converted_partial",
                       learnable: complete && outcome.effect == .confirmed)
    }

    /// Converts actions already copied with event_id = source local_order, preserving every action row.
    /// The caller holds the source read transaction and destination write transaction, before triggers.
    static func convert(from source: SQLiteConnection, into target: SQLiteConnection) throws -> Report {
        var report = Report()
        let actions = try source.prepare("""
            SELECT a.event_id,a.tool_kind,a.result_kind,e.local_order FROM memory_agent_actions a
            JOIN memory_events e ON e.event_id=a.event_id ORDER BY e.local_order
            """)
        defer { actions.finalize() }
        while try actions.step() {
            try Task.checkCancellation()
            let row = actions.row
            guard let tool = AgentTool(rawValue: try row.text(1) ?? ""),
                  tool.isOperation || tool == .batch,
                  let kind = ActOutcomeKind(rawValue: try row.text(2) ?? ""), kind != .dryRun else { continue }
            guard let event = try row.text(0), let localOrder = row.integer(3) else {
                throw SQLiteMigration22.Refusal.verificationFailed(["outcome source identity"])
            }
            let effect = try source.query(
                "SELECT performed,not_sent_reason FROM memory_call_effects WHERE event_id=?", [.text(event)]
            ) { (performed: try $0.text(0) ?? "", cause: try $0.text(1)) }.first
            let check: OperationCheck?
            if let effect {
                guard let performed = OperationCheck.Performed(rawValue: effect.performed) else {
                    throw SQLiteMigration22.Refusal.verificationFailed(["historical performed code"])
                }
                check = try Self.check(in: source, event: event, performed: performed)
            } else {
                check = nil
            }
            let verb = try source.query("""
                SELECT text_value FROM memory_operation_arguments
                WHERE event_id=? AND argument_name='verb' AND position=0 AND value_kind='text'
                """, [.text(event)]) { try $0.text(0) }.first ?? nil
            let sceneAttached = try source.query("""
                SELECT EXISTS(SELECT 1 FROM memory_event_scenes WHERE event_id=? AND phase='after')
                """, [.text(event)]) { $0.integer(0) }.first == 1
            let values = columns(kind: kind, tool: tool, verb: verb, hasEffect: effect != nil, check: check,
                                 notSent: effect?.cause.flatMap(NotSentCause.init(rawValue:)), sceneAttached: sceneAttached)
            let changed = try target.run("""
                UPDATE memory_agent_actions SET result_kind=NULL,gesture=?,effect=?,effect_reason=?,recovery=?,
                    recovery_reason=?,outcome_origin=?,learnable=?
                WHERE event_id=? AND event_id=(SELECT event_id FROM memory_events WHERE event_uuid=?)
                """, values.bindings + [.integer(localOrder), .text(event)])
            guard changed == 1 else {
                throw SQLiteMigration22.Refusal.verificationFailed(["outcome destination for \(event)"])
            }
            if values.origin == "converted" { report.converted += 1 }
            else { report.partiallyConverted += 1 }
        }
        return report
    }

    private static func check(
        in source: SQLiteConnection,
        event: String,
        performed: OperationCheck.Performed
    ) throws -> OperationCheck? {
        // Preserve the historical reader's first-verification order when a call has several conditions.
        let saved = try source.query("""
            SELECT o.event_id,o.condition_kind,o.method_version,v.method,v.verdict,v.expected_text,v.observed_text
            FROM memory_operation_verifications o JOIN memory_verifications v ON v.event_id=o.event_id
            WHERE o.call_event_id=? ORDER BY o.event_id LIMIT 1
            """, [.text(event)]) {
                (event: try $0.text(0) ?? "", condition: try $0.text(1) ?? "", version: try $0.text(2) ?? "",
                 method: try $0.text(3) ?? "", verdict: try $0.text(4) ?? "", expected: try $0.text(5), observed: try $0.text(6))
            }.first
        guard let saved else { return nil }
        guard let condition = OperationCheck.Condition(rawValue: saved.condition),
              let method = VerificationMethod(rawValue: saved.method)?.oracleMethod,
              let verdict = OperationCheck.Verdict(rawValue: saved.verdict) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["historical verification codes"])
        }
        let limits = try source.query("""
            SELECT limit_kind FROM memory_operation_verification_limits WHERE event_id=? ORDER BY position
            """, [.text(saved.event)]) { row -> OperationCheck.Limit in
                guard let limit = OperationCheck.Limit(rawValue: try row.text(0) ?? "") else {
                    throw SQLiteMigration22.Refusal.verificationFailed(["historical verification limit"])
                }
                return limit
            }
        return OperationCheck(condition: condition, method: method, methodVersion: saved.version, verdict: verdict,
                              expected: saved.expected, observed: saved.observed, limits: limits, performed: performed)
    }
}
