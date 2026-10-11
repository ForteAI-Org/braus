//
//  SQLiteBrainRelationRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// SQLiteBrainRelationRepository keeps the Brain's relations between functional states: it evaluates
/// what a concluded call teaches them from the call's recorded facts (its verification, its effect, the
/// states its samples were confirmed in), and answers the relations of one state and its elements by
/// targeted queries on the keys they are indexed by, never by reading an application's whole Brain.
///
/// What a call teaches is a history of evaluations (`brain_relation_evaluations`): the first made when
/// the call is acquired; another when the evidence a recoverable exclusion lacked arrived (its sample
/// was placed in a state, the call concluded, a relation it can contradict appeared); another when a new
/// policy reads the facts again; and one a recovery makes for a call a stopped process never evaluated.
/// An evaluation that would decide what the latest one decided is not written. A relation counts the
/// evidence of each call's latest evaluation only, so a call supports or contradicts it once, however
/// often it is evaluated, retried, copied or rebuilt. Nothing is deleted: brain-relations-1's register
/// of schema 3 stays as it was written.
public struct SQLiteBrainRelationRepository: BrainRelationReading {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    // MARK: Evaluating a call

    /// What a concluded call teaches now. A call evaluated under this policy and not waiting for
    /// evidence answers its latest evaluation and changes nothing; one never evaluated is evaluated for
    /// `cause`; one waiting for evidence, or evaluated under another policy, is evaluated again.
    @discardableResult
    public func apply(callEventID: String, at nowMS: Int64,
                      cause: BrainRelationApplication.Cause = .acquisition) async throws -> BrainRelationApplication {
        try await store.write { transaction in
            try SQLiteBrainRelationRows.evaluate(transaction, callEventID: callEventID, cause: cause, at: nowMS)
        }
    }

    /// CatchUp is what one bounded pass of the recovery did.
    public struct CatchUp: Sendable, Equatable {
        /// Calls evaluated for the first time: a stopped process or a lost queue never evaluated them.
        public var recovered = 0
        /// Calls evaluated again because their evidence arrived.
        public var reconsidered = 0
        /// Calls evaluated again under this policy.
        public var reevaluated = 0
        /// Samples placed in a state on the way.
        public var associated = 0
        /// Whether the pass stopped at its limit with more left.
        public var remaining = false

        public var total: Int { recovered + reconsidered + reevaluated }

        public init() {}
    }

    /// One bounded pass of the recovery, oldest first, each call in a write of its own: the calls a
    /// recoverable exclusion left waiting whose evidence may have arrived (their samples are placed in a
    /// state first, as their acquisition would have), the calls never evaluated, and the calls evaluated
    /// under another policy. At most `limit` of each. Never repeats an action: it reads the facts.
    public func catchUp(at nowMS: Int64, limit: Int = 25,
                        associate: (CaptureSampleKey) async throws -> Void) async throws -> CatchUp {
        var report = CatchUp()
        let waiting = try await store.read { snapshot in try SQLiteBrainRelationRows.waiting(snapshot, limit: limit) }
        for (call, unplaced) in waiting {
            for key in unplaced {
                try await associate(key)
                report.associated += 1
            }
            _ = try await apply(callEventID: call, at: nowMS, cause: .evidence)
            report.reconsidered += 1
        }
        var placing = false
        let missing = try await store.read { snapshot in try SQLiteBrainRelationRows.unevaluated(snapshot, limit: limit) }
        for (call, hadFirstPolicy) in missing {
            let made = try await apply(callEventID: call, at: nowMS, cause: hadFirstPolicy ? .policy : .recovery)
            if hadFirstPolicy { report.reevaluated += 1 } else { report.recovered += 1 }
            placing = placing || made.exclusion == .awaitingState
        }
        let stale = try await store.read { snapshot in try SQLiteBrainRelationRows.stale(snapshot, limit: limit) }
        for call in stale {
            let made = try await apply(callEventID: call, at: nowMS, cause: .policy)
            report.reevaluated += 1
            placing = placing || made.exclusion == .awaitingState
        }
        // A call this pass left waiting for its samples' states gets them placed by the next pass.
        report.remaining = placing || waiting.count == limit || missing.count == limit || stale.count == limit
        return report
    }

    /// Evaluates every operation no evaluation reads yet, oldest first, and answers how many: the part of
    /// the recovery that rebuilds the relations from the facts after a migration or a lost queue, alone.
    @discardableResult
    public func applyPending(at nowMS: Int64, limit: Int = 10_000) async throws -> Int {
        let missing = try await store.read { snapshot in try SQLiteBrainRelationRows.unevaluated(snapshot, limit: limit) }
        for (call, hadFirstPolicy) in missing {
            _ = try await apply(callEventID: call, at: nowMS, cause: hadFirstPolicy ? .policy : .recovery)
        }
        return missing.count
    }

    /// The latest evaluation of a call, or nil when it was never evaluated.
    public func application(of callEventID: String) async throws -> BrainRelationApplication? {
        try await store.read { snapshot in try SQLiteBrainRelationRows.latest(snapshot, callEventID: callEventID) }
    }

    /// Every evaluation of a call, the first first.
    public func evaluations(of callEventID: String) async throws -> [BrainRelationApplication] {
        try await store.read { snapshot in try SQLiteBrainRelationRows.evaluations(snapshot, callEventID: callEventID) }
    }

    // MARK: Reading

    public func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? {
        guard isComplete else { return nil }
        return try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return nil }
            let known = try SQLiteSceneRows.scenes(snapshot, appID: appID, bundleID: bundleID, roleKey: skeleton.roleKey)
            let same = known.filter {
                SceneStructureMatcher.compare(observed: skeleton, isComplete: true, known: $0.skeleton) == .same
            }
            let uncertain = known.contains {
                if case .uncertain = SceneStructureMatcher.compare(observed: skeleton, isComplete: true, known: $0.skeleton) { true }
                else { false }
            }
            return same.count == 1 && !uncertain ? same.first?.id : nil
        }
    }

    public func state(of sample: CaptureSampleKey) async throws -> String? {
        try await store.read { snapshot in
            try SQLiteProcedureRows.confirmedScene(snapshot, eventID: sample.eventID, phase: sample.phase)
        }
    }

    public func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                          includingContext: Bool) async throws -> [BrainRelation] {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return [] }
            return try SQLiteBrainRelationRows.relations(snapshot, appID: appID, bundleID: bundleID, from: sceneID,
                                                         elementKeys: elementKeys, includingContext: includingContext)
        }
    }

    /// Every relation of an application with its evidence counted, for diagnosis: never read on the path
    /// of an action.
    public func relations(of bundleID: String) async throws -> [BrainRelation] {
        try await store.read { snapshot in
            guard let appID = try SQLiteIdentityRows.appID(snapshot, bundleID: bundleID) else { return [] }
            return try SQLiteBrainRelationRows.relations(snapshot, appID: appID, bundleID: bundleID, from: nil, elementKeys: [],
                                                         includingContext: true)
        }
    }

    /// The calls whose latest evaluation supports or contradicts a relation, with how.
    public func proofs(of relationID: String) async throws -> [(callEventID: String, relation: EvidenceRelation, verificationEventID: String)] {
        try await store.read { snapshot in
            try snapshot.query(
                """
                SELECT e.call_event_id, e.relation, e.verification_event_id FROM brain_relation_evidence e
                WHERE e.relation_id = ? AND e.sequence = (SELECT max(v.sequence) FROM brain_relation_evaluations v
                                                          WHERE v.call_event_id = e.call_event_id)
                ORDER BY e.assessed_at_ms, e.call_event_id
                """,
                [.text(relationID)]
            ) { row in
                (callEventID: try row.text(0) ?? "", relation: EvidenceRelation(rawValue: try row.text(1) ?? "") ?? .supports,
                 verificationEventID: try row.text(2) ?? "")
            }
        }
    }
}

/// SQLiteBrainRelationRows is the codec of relations, their evidence and the evaluations.
enum SQLiteBrainRelationRows {

    static func malformed(_ table: String, _ id: String, _ problem: String) -> ProcedureError {
        .malformedRow(table: table, id: id, problem: problem)
    }

    /// The operations a relation may be evaluated for.
    static let operations = "('act', 'select', 'type_text', 'insert_text', 'press_key', 'scroll', 'drag', 'context_menu', 'menu', 'press')"

    // MARK: Evaluating

    /// Evaluates a call inside the caller's transaction, as `apply` says, and answers its latest
    /// evaluation: a new one when it decides otherwise than the latest, or the latest itself.
    static func evaluate(_ transaction: SQLiteTransaction, callEventID: String, cause requested: BrainRelationApplication.Cause,
                         at nowMS: Int64) throws -> BrainRelationApplication {
        let latest = try latest(transaction, callEventID: callEventID)
        if let latest, !latest.isRecoverable, latest.policyVersion == BrainRelationPolicy.version { return latest }
        let cause: BrainRelationApplication.Cause = switch latest {
            case nil: requested
            case let latest? where latest.policyVersion != BrainRelationPolicy.version: .policy
            case _?: .evidence
        }
        guard let call = try SQLiteAgentCallRows.call(transaction, eventID: callEventID) else {
            throw AgentCallError.missingCall(eventID: callEventID)
        }
        let facts = try facts(transaction, call: call)
        let decision = BrainRelationPolicy.decide(facts)
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
                let targets = try relations(transaction, appID: appID, group: contradicted, outcome: outcome, effectKind: effectKind)
                if targets.isEmpty {
                    group = (groupKey(contradicted, outcome: outcome), effectKind)
                    made = evaluation(.excluded, .nothingToContradict, [])
                } else {
                    evidence = targets.map { ($0, .contradicts) }
                    made = evaluation(.contradicted, nil, targets)
                }
            case .excluded(let why):
                made = evaluation(.excluded, why, [])
        }
        if let latest, latest.decidesAsWell(made) { return latest }
        try insert(transaction, made, appID: appID, group: group, at: nowMS)
        if !evidence.isEmpty, facts.verification == nil { throw AgentCallError.missingCall(eventID: callEventID) }
        for (relationID, kind) in evidence {
            guard let verification = facts.verification else { break }
            try transaction.execute(
                """
                INSERT INTO brain_relation_evidence (relation_id, call_event_id, sequence, relation, verification_event_id,
                    policy_version, assessed_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(relationID), .text(callEventID), .integer(Int64(sequence)), .text(kind.rawValue), .text(verification.eventID),
                 .text(BrainRelationPolicy.version), .integer(nowMS)]
            )
            try transaction.execute(
                "UPDATE brain_relations SET last_seen_ms = max(last_seen_ms, ?) WHERE relation_id = ?", [.integer(nowMS), .text(relationID)]
            )
        }
        if let created {
            // A failure that came before the relation it contradicts contradicts it now: the order the
            // calls were evaluated in never changes what the facts prove.
            for waiting in try waitingContradictions(transaction, of: created) where waiting != callEventID {
                _ = try evaluate(transaction, callEventID: waiting, cause: .evidence, at: nowMS)
            }
        }
        return made
    }

    private static func insert(_ transaction: SQLiteTransaction, _ made: BrainRelationApplication, appID: Int64?,
                               group: (key: String, effectKind: String?)?, at nowMS: Int64) throws {
        try transaction.execute(
            """
            INSERT INTO brain_relation_evaluations (call_event_id, sequence, app_id, policy_version, cause, outcome, reason,
                recoverable, group_key, expected_effect_kind, evaluated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(made.callEventID), .integer(Int64(made.sequence)), appID.map(SQLiteValue.integer) ?? .null,
             .text(made.policyVersion), .text(made.cause.rawValue), .text(made.outcome.rawValue),
             made.exclusion.map { .text($0.rawValue) } ?? .null, .integer(made.isRecoverable ? 1 : 0),
             group.map { .text($0.key) } ?? .null, group?.effectKind.map(SQLiteValue.text) ?? .null, .integer(nowMS)]
        )
    }

    /// The key of a group and an outcome a failed verification waits for, in an evaluation.
    static func groupKey(_ group: BrainRelationKey.Group, outcome: BrainRelationOutcome) -> String {
        group.key(outcome: outcome)
    }

    /// The calls whose latest evaluation waits for a relation of this one's group to contradict.
    private static func waitingContradictions(_ handle: some SQLiteQuerying, of key: BrainRelationKey) throws -> [String] {
        try handle.query(
            """
            SELECT v.call_event_id FROM brain_relation_evaluations v
            WHERE v.group_key = ? AND (v.expected_effect_kind IS NULL OR v.expected_effect_kind IS ?)
              AND v.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = v.call_event_id)
            ORDER BY v.call_event_id
            """,
            [.text(groupKey(key.group, outcome: key.outcome)), key.effectKind.map(SQLiteValue.text) ?? .null]
        ) { try $0.text(0) ?? "" }
    }

    // MARK: The recovery's work

    /// Calls whose latest evaluation waits for evidence that may have arrived, oldest first, with their
    /// samples still waiting to be placed in a state: an exclusion awaiting a state, and a call not
    /// concluded when it was evaluated that has concluded since.
    static func waiting(_ handle: some SQLiteQuerying, limit: Int) throws -> [(String, [CaptureSampleKey])] {
        let calls = try handle.query(
            """
            SELECT v.call_event_id, v.reason FROM brain_relation_evaluations v
            JOIN memory_events e ON e.event_id = v.call_event_id JOIN memory_agent_actions a ON a.event_id = v.call_event_id
            WHERE v.recoverable = 1
              AND v.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = v.call_event_id)
              AND (v.reason = 'awaiting_state'
                   OR (v.reason = 'not_concluded' AND a.execution_status IN ('completed', 'failed', 'cancelled', 'interrupted')))
            ORDER BY e.local_order LIMIT ?
            """,
            [.integer(Int64(max(1, limit)))]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }
        return try calls.map { call, reason in
            guard reason == "awaiting_state" else { return (call, []) }
            let unplaced = try [CapturePhase.before, .after].compactMap { phase -> CaptureSampleKey? in
                let key = CaptureSampleKey(eventID: call, phase: phase)
                return try awaitsState(handle, key) ? key : nil
            }
            return (call, unplaced)
        }
    }

    /// Operations concluded (or still started) that no evaluation reads, oldest first, and whether the
    /// first policy applied them (schema 3's register): those are evaluated again, the others recovered.
    static func unevaluated(_ handle: some SQLiteQuerying, limit: Int) throws -> [(String, Bool)] {
        try handle.query(
            """
            SELECT a.event_id, EXISTS (SELECT 1 FROM brain_relation_applications r WHERE r.call_event_id = a.event_id)
            FROM memory_agent_actions a JOIN memory_events e ON e.event_id = a.event_id
            WHERE a.tool_kind IN \(operations)
              AND a.execution_status IN ('started', 'completed', 'failed', 'cancelled', 'interrupted')
              AND NOT EXISTS (SELECT 1 FROM brain_relation_evaluations v WHERE v.call_event_id = a.event_id)
            ORDER BY e.local_order LIMIT ?
            """,
            [.integer(Int64(max(1, limit)))]
        ) { (try $0.text(0) ?? "", ($0.integer(1) ?? 0) == 1) }
    }

    /// Calls whose latest evaluation was made under another policy, oldest first.
    static func stale(_ handle: some SQLiteQuerying, limit: Int) throws -> [String] {
        try handle.query(
            """
            SELECT v.call_event_id FROM brain_relation_evaluations v JOIN memory_events e ON e.event_id = v.call_event_id
            WHERE v.policy_version <> ?
              AND v.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = v.call_event_id)
            ORDER BY e.local_order LIMIT ?
            """,
            [.text(BrainRelationPolicy.version), .integer(Int64(max(1, limit)))]
        ) { try $0.text(0) ?? "" }
    }

    /// Whether a sample is complete, placeable on a structural surface and not associated yet: its state
    /// may still come. A sample missing, incomplete, of a menu or a pop-up, or already associated
    /// (confirmed or only as candidates) waits for nothing.
    static func awaitsState(_ handle: some SQLiteQuerying, _ key: CaptureSampleKey) throws -> Bool {
        guard let sample = try SQLiteObservationRows.sample(handle, key: key), sample.quality.isComplete,
              try SQLiteSceneRows.associations(handle, key: key).isEmpty else { return false }
        if case .none(_) = SceneStructureMatcher.decide(observed: SceneSkeleton(sample: sample), isComplete: true, phase: key.phase, among: []) {
            return false
        }
        return true
    }

    // MARK: Facts

    /// What the policy reads of a call, from its rows: the event's application and context, the recording
    /// gaps, the withheld target and effect, its verification, the effect it observed, the element it
    /// resolved, the states its samples were confirmed in, whether a sample not placed yet may still be,
    /// and the elements of its sample before acting.
    static func facts(_ handle: some SQLiteQuerying, call: AgentCall) throws -> BrainRelationPolicy.Facts {
        let id = call.event.eventID
        let context = try handle.query("SELECT context_id FROM memory_events WHERE event_id = ?", [.text(id)]) { $0.integer(0) }.first ?? nil
        let gaps = try SQLiteOperationFactRows.recordingGaps(handle, id)
        let withheldKinds: Set<String> = ["target_label", "target_element", "target_section", "observed_effect"]
        // A withheld argument other than a parameter of its family would put a placeholder in the relation's
        // key (an item, a menu path, a button's title), merging what the call chose with any other withheld
        // choice: the call teaches nothing, as for a withheld target.
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
            bundleID          : call.event.app?.bundleID,
            contextID         : context,
            request           : call.request,
            status            : call.progress.status,
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
            beforeAwaitsState : from == nil ? try awaitsState(handle, CaptureSampleKey(eventID: id, phase: .before)) : false,
            afterAwaitsState  : to == nil ? try awaitsState(handle, CaptureSampleKey(eventID: id, phase: .after)) : false,
            beforeElements    : before?.elements ?? []
        )
    }

    // MARK: Relations

    /// The relation of a key, written once, and whether this call wrote it: an id that names other
    /// columns is a conflict.
    static func ensure(_ transaction: SQLiteTransaction, _ key: BrainRelationKey, appID: Int64, at nowMS: Int64) throws -> (String, Bool) {
        let id = key.relationID
        if let stored = try relation(transaction, relationID: id) {
            guard stored == key else { throw SQLiteFactRows.conflict(id, stored: "\(stored)", offered: "\(key)") }
            return (id, false)
        }
        let sceneElement = try key.elementKey.flatMap { elementKey in
            try transaction.query(
                "SELECT scene_element_id FROM brain_scene_elements WHERE scene_id = ? AND element_key = ?",
                [.text(key.fromSceneID), .text(elementKey)]
            ) { try $0.text(0) }.first ?? nil
        }
        try transaction.execute(
            """
            INSERT INTO brain_relations (relation_id, app_id, context_id, from_scene_id, element_key, scene_element_id, verb,
                arguments_key, to_scene_id, outcome, effect_kind, first_seen_ms, last_seen_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(id), .integer(appID), key.contextID.map(SQLiteValue.integer) ?? .null, .text(key.fromSceneID),
             key.elementKey.map(SQLiteValue.text) ?? .null, sceneElement.map(SQLiteValue.text) ?? .null, .text(key.verb.rawValue),
             .text(key.argumentsKey), key.toSceneID.map(SQLiteValue.text) ?? .null, .text(key.outcome.rawValue),
             key.effectKind.map(SQLiteValue.text) ?? .null, .integer(nowMS), .integer(nowMS)]
        )
        return (id, true)
    }

    /// The relations of a group with the given outcome (and family, when given).
    static func relations(_ handle: some SQLiteQuerying, appID: Int64, group: BrainRelationKey.Group, outcome: BrainRelationOutcome,
                          effectKind: String?) throws -> [String] {
        try handle.query(
            """
            SELECT relation_id FROM brain_relations
            WHERE app_id = ? AND from_scene_id = ? AND element_key IS ? AND verb = ? AND arguments_key = ? AND context_id IS ?
              AND outcome = ? AND (? IS NULL OR effect_kind = ?)
            ORDER BY relation_id
            """,
            [.integer(appID), .text(group.fromSceneID), group.elementKey.map(SQLiteValue.text) ?? .null, .text(group.verb.rawValue),
             .text(group.argumentsKey), group.contextID.map(SQLiteValue.integer) ?? .null, .text(outcome.rawValue),
             effectKind.map(SQLiteValue.text) ?? .null, effectKind.map(SQLiteValue.text) ?? .null]
        ) { try $0.text(0) ?? "" }
    }

    static func relation(_ handle: some SQLiteQuerying, relationID: String) throws -> BrainRelationKey? {
        try handle.query(
            """
            SELECT b.bundle_id, r.context_id, r.from_scene_id, r.element_key, r.verb, r.arguments_key, r.to_scene_id, r.outcome,
                   r.effect_kind
            FROM brain_relations r JOIN brain_apps b ON b.app_id = r.app_id WHERE r.relation_id = ?
            """,
            [.text(relationID)]
        ) { try key(of: $0, id: relationID, from: 0) }.first
    }

    private static func key(of row: SQLiteStatement.Row, id: String, from column: Int) throws -> BrainRelationKey {
        guard let verb = BrainVerb(rawValue: try row.text(column + 4) ?? ""),
              let outcome = BrainRelationOutcome(rawValue: try row.text(column + 7) ?? "") else {
            throw malformed("brain_relations", id, "verb or outcome")
        }
        return BrainRelationKey(bundleID: try row.text(column) ?? "", contextID: row.integer(column + 1),
                                fromSceneID: try row.text(column + 2) ?? "", elementKey: try row.text(column + 3), verb: verb,
                                argumentsKey: try row.text(column + 5) ?? "", toSceneID: try row.text(column + 6),
                                outcome: outcome, effectKind: try row.text(column + 8))
    }

    /// The evidence of each call's latest evaluation for a relation, of one kind: what a relation counts.
    private static func current(_ kind: EvidenceRelation) -> String {
        """
        (SELECT count(*) FROM brain_relation_evidence p WHERE p.relation_id = r.relation_id AND p.relation = '\(kind.rawValue)'
           AND p.sequence = (SELECT max(v.sequence) FROM brain_relation_evaluations v WHERE v.call_event_id = p.call_event_id))
        """
    }

    /// The relations of an application, from one state for the given element keys (and those with no
    /// element) or every one when `from` is nil, with their current evidence counted, by the state index.
    static func relations(_ handle: some SQLiteQuerying, appID: Int64, bundleID: String, from sceneID: String?,
                          elementKeys: [String], includingContext: Bool) throws -> [BrainRelation] {
        var conditions = ["r.app_id = ?"]
        var values: [SQLiteValue] = [.integer(appID)]
        if let sceneID {
            conditions.append("r.from_scene_id = ?")
            values.append(.text(sceneID))
            var elements: [String] = []
            if !elementKeys.isEmpty {
                elements.append("r.element_key IN (\(Array(repeating: "?", count: elementKeys.count).joined(separator: ", ")))")
                values += elementKeys.map(SQLiteValue.text)
            }
            if includingContext { elements.append("r.element_key IS NULL") }
            guard !elements.isEmpty else { return [] }
            conditions.append("(\(elements.joined(separator: " OR ")))")
        }
        return try handle.query(
            """
            SELECT r.relation_id, b.bundle_id, r.context_id, r.from_scene_id, r.element_key, r.verb, r.arguments_key, r.to_scene_id,
                   r.outcome, r.effect_kind, r.first_seen_ms, r.last_seen_ms, \(current(.supports)), \(current(.contradicts))
            FROM brain_relations r JOIN brain_apps b ON b.app_id = r.app_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY r.from_scene_id, r.element_key, r.verb, r.arguments_key, r.relation_id
            """,
            values
        ) { row in
            let id = try row.text(0) ?? ""
            return BrainRelation(relationID: id, key: try key(of: row, id: id, from: 1), firstSeenMS: row.integer(10) ?? 0,
                                 lastSeenMS: row.integer(11) ?? 0, supports: Int(row.integer(12) ?? 0),
                                 contradictions: Int(row.integer(13) ?? 0))
        }
    }

    // MARK: Evaluations

    static func latest(_ handle: some SQLiteQuerying, callEventID: String) throws -> BrainRelationApplication? {
        try evaluations(handle, callEventID: callEventID, latestOnly: true).last
    }

    static func evaluations(_ handle: some SQLiteQuerying, callEventID: String, latestOnly: Bool = false) throws -> [BrainRelationApplication] {
        let rows = try handle.query(
            """
            SELECT sequence, policy_version, cause, outcome, reason FROM brain_relation_evaluations
            WHERE call_event_id = ?\(latestOnly ? " ORDER BY sequence DESC LIMIT 1" : " ORDER BY sequence")
            """,
            [.text(callEventID)]
        ) { (Int($0.integer(0) ?? 0), try $0.text(1) ?? "", try $0.text(2) ?? "", try $0.text(3) ?? "", try $0.text(4)) }
        return try rows.map { sequence, policy, causeCode, outcomeCode, reason in
            guard let cause = BrainRelationApplication.Cause(rawValue: causeCode),
                  let outcome = BrainRelationApplication.Outcome(rawValue: outcomeCode) else {
                throw malformed("brain_relation_evaluations", callEventID, "cause or outcome")
            }
            let exclusion = try reason.map { code -> BrainRelationPolicy.Exclusion in
                guard let known = BrainRelationPolicy.Exclusion(rawValue: code) else {
                    throw malformed("brain_relation_evaluations", callEventID, "reason")
                }
                return known
            }
            let relations = try handle.query(
                "SELECT relation_id FROM brain_relation_evidence WHERE call_event_id = ? AND sequence = ? ORDER BY relation_id",
                [.text(callEventID), .integer(Int64(sequence))]
            ) { try $0.text(0) ?? "" }
            return BrainRelationApplication(callEventID: callEventID, sequence: sequence, policyVersion: policy, cause: cause,
                                            outcome: outcome, exclusion: exclusion, relationIDs: relations)
        }
    }
}
