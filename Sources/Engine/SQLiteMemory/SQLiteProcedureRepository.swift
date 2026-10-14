//
//  SQLiteProcedureRepository.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import Memory

/// SQLiteProcedureRepository keeps the procedures D2 builds from an attempt's facts: the candidate the
/// segmentation makes, one occurrence per started operation with its call and verifications as
/// memberships, the agent's interpretations, the versions they build over the Route tables, their parts,
/// contracts, parameters, templates and bindings, the qualification of every part and its operational
/// state. Every write is one transaction that reads the facts it decides on inside it and holds no lock
/// across a gesture or a model's turn; a write offered again over the same facts answers
/// `alreadyApplied`, and another content under a stored identity is a typed conflict that writes
/// nothing. It reads facts, never a log, and never writes one: a call, a sample, a verification and a
/// task stay as D1 recorded them.
public struct SQLiteProcedureRepository: Sendable {

    private let store: SQLiteMemoryStore

    /// The author an occurrence's assignment to its attempt names: the segmentation, not an agent.
    public static let segmentationAuthor = "braus-segmentation"

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    // MARK: Candidates

    /// Builds the candidate of an attempt from its facts now: its started operations in the order they
    /// started, one occurrence each, in blocks of one application. Nil when the attempt has no step.
    /// Built again over the same calls it is the stored candidate (`alreadyApplied`), with its
    /// occurrences brought up to date with their calls (a call that concluded since, a verification
    /// written since). `producer` limits the build to the producer's own attempts; nil is the system's
    /// own rebuild.
    public func buildCandidate(
        attemptID  : String,
        for producer: TaskProducer?,
        at nowMS   : Int64
    ) async throws -> (receipt: MemoryReceipt, candidate: ProcedureCandidate)? {
        try await store.write { transaction in
            guard let attempt = try SQLiteTaskContextRows.attempt(transaction, attemptID) else {
                throw TaskContextError.unknownAttempt(attemptID: attemptID)
            }
            if let producer { _ = try SQLiteTaskContextRows.owned(transaction, attempt.attempt.taskID, by: producer) }
            let calls = try SQLiteProcedureRows.attemptCalls(transaction, attemptID: attemptID)
            let checkpoint = try SQLiteTaskContextRows.checkpoints(transaction, of: attemptID).last?.sequence
            guard let offered = try ProcedureCandidate.of(calls, taskID: attempt.attempt.taskID, attemptID: attemptID,
                                                          checkpointSequence: checkpoint, builtAtMS: nowMS) else { return nil }
            for step in offered.steps {
                try SQLiteProcedureRows.ensureOccurrence(transaction, step: step, attemptID: attemptID)
            }
            if let stored = try SQLiteProcedureRows.candidate(transaction, offered.candidateID) {
                guard stored.hasSameStructure(as: offered) else {
                    throw SQLiteFactRows.conflict(offered.candidateID, stored: "\(stored.steps)", offered: "\(offered.steps)")
                }
                return (.alreadyApplied, stored)
            }
            try SQLiteProcedureRows.insert(transaction, offered)
            return (.committed, offered)
        }
    }

    /// A candidate by its id, or nil.
    public func candidate(_ candidateID: String) async throws -> ProcedureCandidate? {
        try await store.read { snapshot in try SQLiteProcedureRows.candidate(snapshot, candidateID) }
    }

    /// The candidates of an attempt, the first built first.
    public func candidates(ofAttempt attemptID: String) async throws -> [ProcedureCandidate] {
        try await store.read { snapshot in
            try snapshot.query(
                "SELECT candidate_id FROM memory_procedure_candidates WHERE task_occurrence_id = ? ORDER BY built_at_ms, candidate_id",
                [.text(attemptID)]
            ) { try $0.text(0) ?? "" }.compactMap { try SQLiteProcedureRows.candidate(snapshot, $0) }
        }
    }

    // MARK: Interpretations and versions

    /// Records an interpretation of a candidate and builds its version, with the qualification of every
    /// part, in one transaction. The candidate must be the latest of its attempt and one of the
    /// producer's tasks. The same statements again (at the revision they hold, or with no revision named)
    /// are the stored interpretation; other statements under a stored revision are a conflict; a revision
    /// that skips one is out of order. A reference the candidate or its calls do not have is refused with
    /// nothing written; a use the calls contradict is kept as a finding.
    public func interpret(_ interpretation: ProcedureInterpretation, by producer: TaskProducer,
                          at nowMS: Int64) async throws -> InterpretationOutcome {
        try await store.write { transaction in
            guard let candidate = try SQLiteProcedureRows.candidate(transaction, interpretation.candidateID) else {
                throw ProcedureError.unknownCandidate(candidateID: interpretation.candidateID)
            }
            let task = try SQLiteTaskContextRows.owned(transaction, candidate.taskID, by: producer)
            if let latest = try SQLiteProcedureRows.latestCandidateID(transaction, attemptID: candidate.attemptID),
               !latest.utf8.elementsEqual(candidate.candidateID.utf8) {
                throw ProcedureError.staleCandidate(candidateID: candidate.candidateID, current: latest)
            }
            let stored = try SQLiteProcedureRows.interpretations(transaction, candidateID: candidate.candidateID)
            let digest = interpretation.digest
            let revision: Int
            if let requested = interpretation.revision {
                if let same = stored.first(where: { $0.revision == requested }) {
                    guard same.digest.utf8.elementsEqual(digest.utf8) else {
                        throw ProcedureError.conflictingInterpretation(candidateID: candidate.candidateID, revision: requested)
                    }
                    return try SQLiteProcedureRows.outcome(transaction, candidateID: candidate.candidateID, revision: requested,
                                                           receipt: .alreadyApplied)
                }
                guard requested == stored.count + 1 else {
                    throw ProcedureError.revisionOutOfOrder(candidateID: candidate.candidateID, expected: stored.count + 1)
                }
                revision = requested
            } else {
                if let last = stored.last, last.digest.utf8.elementsEqual(digest.utf8) {
                    return try SQLiteProcedureRows.outcome(transaction, candidateID: candidate.candidateID, revision: last.revision,
                                                           receipt: .alreadyApplied)
                }
                revision = stored.count + 1
            }
            if let variant = interpretation.variantOf {
                guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_procedure_versions WHERE route_id = ?", variant) else {
                    throw ProcedureError.unknownReference("version \(variant)")
                }
            }
            guard let attempt = try SQLiteTaskContextRows.attempt(transaction, candidate.attemptID) else {
                throw TaskContextError.unknownAttempt(attemptID: candidate.attemptID)
            }
            let checkpoints = try SQLiteTaskContextRows.checkpoints(transaction, of: candidate.attemptID)
            let end = checkpoints.last { $0.kind == .end }?.declared
            let state: InterpretationState = end != nil ? .ended : attempt.status == .inProgress ? .running : .interrupted
            let inputs = try SQLiteTaskContextRows.revision(transaction, task.taskID, task.currentRevision)?.content.inputs ?? []
            let facts = try candidate.steps.map { step -> ProcedureAssembly.StepFacts in
                guard let call = try SQLiteAgentCallRows.call(transaction, eventID: step.callEventID) else {
                    throw ProcedureError.unknownReference("call \(step.callEventID)")
                }
                return ProcedureAssembly.StepFacts(position: step.position, request: call.request,
                                                   withheldArguments: try SQLiteProcedureRows.withheldArguments(transaction, step.callEventID))
            }
            let version = try ProcedureAssembly.assemble(
                candidate     : candidate,
                interpretation: interpretation,
                revision      : revision,
                steps         : facts,
                taskInputs    : inputs,
                supersedes    : try SQLiteProcedureRows.currentVersion(transaction, attemptID: candidate.attemptID),
                builtAtMS     : nowMS
            )
            // A variant's prefix is checked on the operations before anything is written: a prefix they
            // contradict is refused whole, one they cannot decide is kept as suggested.
            var prefix: VariantPrefix.Check?
            if let variant = interpretation.variantOf, let divergence = interpretation.divergencePosition {
                guard let origin = try SQLiteRouteRows.read(transaction, routeID: variant) else {
                    throw ProcedureError.unknownReference("version \(variant)")
                }
                prefix = try VariantPrefix.check(variant: version.definition, of: origin.definition, divergence: divergence,
                                                 variantDetails: version.parameterDetails,
                                                 originalDetails: try SQLiteProcedureRows.parameterDetails(transaction, routeID: variant))
            }
            var entryStates: [Int: String?] = [:]
            for step in candidate.steps {
                entryStates[step.position] = .some(try SQLiteProcedureRows.confirmedScene(transaction, eventID: step.callEventID,
                                                                                          phase: .before))
            }
            let contract = try ProcedureAssembly.contract(of: version, entryStates: entryStates)
            try SQLiteProcedureRows.insertInterpretation(transaction, version, digest: digest, producer: producer,
                                                        taskRevision: task.currentRevision, state: state, at: nowMS)
            try SQLiteRouteRows.insert(transaction, version.definition, state: RouteState(status: .draft))
            try SQLiteProcedureRows.insert(transaction, version, contract: contract)
            if let prefix {
                try transaction.execute(
                    """
                    INSERT INTO memory_variant_prefix_checks (route_id, status, compared_steps, reason, checked_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [.text(version.routeID), .text(prefix.status.rawValue), .integer(Int64(prefix.comparedSteps)),
                     prefix.reason.map { .text($0.rawValue) } ?? .null, .integer(nowMS)]
                )
            }
            try SQLiteProcedureRows.ensurePolicy(transaction, at: nowMS)
            let qualifications = try SQLiteProcedureRows.qualify(transaction, routeID: version.routeID, at: nowMS)
            return InterpretationOutcome(receipt: .committed, revision: revision, routeID: version.routeID,
                                         findings: version.findings, qualifications: qualifications)
        }
    }

    /// Evaluates every part of a version again under the policy in force, from the facts now, and
    /// appends an evaluation only for a part whose decision changed: a call that concluded since, a
    /// policy that changed. Answers the current qualification of every part.
    public func requalify(routeID: String, at nowMS: Int64) async throws -> [PartQualification] {
        try await store.write { transaction in
            guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_procedure_versions WHERE route_id = ?", routeID) else {
                throw ProcedureError.unknownReference("version \(routeID)")
            }
            try SQLiteProcedureRows.ensurePolicy(transaction, at: nowMS)
            return try SQLiteProcedureRows.qualify(transaction, routeID: routeID, at: nowMS)
        }
    }

    /// Evaluates the attempt's current version again, when it has one: the qualification after an end or
    /// a conclusion the version was built before.
    @discardableResult
    public func requalifyCurrent(attemptID: String, at nowMS: Int64) async throws -> [PartQualification] {
        try await store.write { transaction in
            guard let routeID = try SQLiteProcedureRows.currentVersion(transaction, attemptID: attemptID) else { return [] }
            try SQLiteProcedureRows.ensurePolicy(transaction, at: nowMS)
            return try SQLiteProcedureRows.qualify(transaction, routeID: routeID, at: nowMS)
        }
    }

    /// A version read back whole, or nil.
    public func version(_ routeID: String) async throws -> StoredProcedureVersion? {
        try await store.read { snapshot in try SQLiteProcedureRows.stored(snapshot, routeID: routeID) }
    }

    /// The versions built from an attempt's candidates, the first built first.
    public func versions(ofAttempt attemptID: String) async throws -> [StoredProcedureVersion] {
        try await store.read { snapshot in
            try snapshot.query(
                "SELECT route_id FROM memory_procedure_versions WHERE task_occurrence_id = ? ORDER BY built_at_ms, route_id",
                [.text(attemptID)]
            ) { try $0.text(0) ?? "" }.compactMap { try SQLiteProcedureRows.stored(snapshot, routeID: $0) }
        }
    }

    // MARK: State and policies

    /// Appends a part's operational state, with why and who: `toReevaluate` keeps the part out of the
    /// catalogue until it is evaluated and declared usable again, `retired` keeps it out for good.
    /// Nothing is deleted: the part, its version and its evidence stay.
    public func setState(_ state: PartOperationalState, of partID: String, reason: String, by author: String,
                         at nowMS: Int64) async throws -> MemoryReceipt {
        guard !reason.isEmpty, !author.isEmpty else { throw ProcedureError.invalid(.emptyText(field: "state")) }
        return try await store.write { transaction in
            guard try SQLiteFactRows.exists(transaction, "SELECT count(*) FROM memory_procedure_parts WHERE part_id = ?", partID) else {
                throw ProcedureError.unknownPart(partID: partID)
            }
            let last = try transaction.query(
                "SELECT sequence, state, reason FROM memory_part_states WHERE part_id = ? ORDER BY sequence DESC LIMIT 1",
                [.text(partID)]
            ) { (Int($0.integer(0) ?? 0), try $0.text(1) ?? "", try $0.text(2) ?? "") }.first
            if let last {
                if last.1 == PartOperationalState.retired.rawValue {
                    if state == .retired { return .alreadyApplied }
                    throw ProcedureError.retired(partID: partID)
                }
                if last.1 == state.rawValue, last.2.utf8.elementsEqual(reason.utf8) { return .alreadyApplied }
            }
            try transaction.execute(
                """
                INSERT INTO memory_part_states (part_id, sequence, state, reason, recorded_at_ms, recorded_by)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(partID), .integer(Int64((last?.0 ?? 0) + 1)), .text(state.rawValue), .text(reason), .integer(nowMS),
                 .text(author)]
            )
            return .committed
        }
    }

    /// Puts a qualification policy in quarantine: what it admitted stops being offered, with the reason,
    /// and nothing it decided is deleted. The parts it admitted can be evaluated again under another
    /// policy.
    public func quarantine(policy version: String, reason: String, at nowMS: Int64) async throws -> MemoryReceipt {
        guard !version.isEmpty, !reason.isEmpty else { throw ProcedureError.invalid(.emptyText(field: "policy")) }
        return try await store.write { transaction in
            let stored = try transaction.query(
                "SELECT status, reason, changed_at_ms FROM memory_qualification_policies WHERE policy_version = ?", [.text(version)]
            ) { (try $0.text(0) ?? "", try $0.text(1), $0.integer(2) ?? 0) }.first
            if let stored, stored.0 == "quarantined" { return .alreadyApplied }
            if let stored {
                try transaction.execute(
                    "UPDATE memory_qualification_policies SET status = 'quarantined', reason = ?, changed_at_ms = ? WHERE policy_version = ?",
                    [.text(reason), .integer(max(nowMS, stored.2)), .text(version)]
                )
            } else {
                try transaction.execute(
                    """
                    INSERT INTO memory_qualification_policies (policy_version, status, changed_at_ms, reason)
                    VALUES (?, 'quarantined', ?, ?)
                    """,
                    [.text(version), .integer(nowMS), .text(reason)]
                )
            }
            return .committed
        }
    }

    // MARK: Inspection

    /// What a developer reads of one task by its id, whatever its producer, in one snapshot
    /// (`ProcedureInspection`): a diagnosis by identity that writes nothing.
    public func inspect(taskID: String) async throws -> ProcedureInspection? {
        try await store.read { snapshot in try SQLiteProcedureRows.inspection(snapshot, taskID: taskID) }
    }

    // MARK: The catalogue

    /// The operational catalogue, a page at a time by part id: the parts of current versions whose
    /// latest qualification, under a policy in force, admits them and whose latest state, and that of
    /// every part they contain, is not `toReevaluate` or `retired`. The rows are read from the authoritative tables, so an index built
    /// from them is a derived copy that can be built again without repeating a task.
    public func catalogue(after cursor: ProcedureCatalogueCursor? = nil, limit: Int = 200) async throws -> [CataloguePart] {
        try await store.read { snapshot in
            let ids = try snapshot.query(
                SQLiteProcedureRows.offered + " AND p.part_id > ? ORDER BY p.part_id LIMIT ?",
                [.text(cursor?.afterPartID ?? ""), .integer(Int64(max(1, limit)))]
            ) { try $0.text(0) ?? "" }
            // Each version of the page is read once, whatever the number of its parts on the page.
            var versions: [String: StoredProcedureVersion?] = [:]
            return try ids.compactMap { try SQLiteProcedureRows.cataloguePart(snapshot, partID: $0, versions: &versions) }
        }
    }
}

/// SQLiteProcedureRows is the codec of candidates, interpretations, versions, parts and qualifications,
/// inside the caller's transaction or snapshot.
enum SQLiteProcedureRows {

    static func malformed(_ table: String, _ id: String, _ problem: String) -> ProcedureError {
        .malformedRow(table: table, id: id, problem: problem)
    }

    // MARK: Facts

    /// The calls attributed to an attempt as actions, in the order they started, as the segmentation
    /// reads them, with the kind of outcome each concluded with (a menu listing is told by it). A batch
    /// is attributed as context and never appears here; its started steps do.
    static func attemptCalls(_ handle: some SQLiteQuerying, attemptID: String) throws -> [ProcedureSegmentation.Call] {
        try handle.query(
            """
            SELECT e.event_id, a.tool_kind, a.execution_status, b.bundle_id, a.result_kind
            FROM memory_task_events e
            JOIN memory_agent_actions a ON a.event_id = e.event_id
            LEFT JOIN brain_apps b ON b.app_id = a.app_id
            WHERE e.task_occurrence_id = ? AND e.role = 'action'
            ORDER BY e.position
            """,
            [.text(attemptID)]
        ) { row in
            let id = try row.text(0) ?? "", toolCode = try row.text(1) ?? "", statusCode = try row.text(2) ?? ""
            guard let tool = AgentTool(rawValue: toolCode), let status = AgentCallStatus(rawValue: statusCode) else {
                throw malformed("memory_agent_actions", id, "tool or status")
            }
            return ProcedureSegmentation.Call(callEventID: id, tool: tool, status: status, bundleID: try row.text(3),
                                              resultKind: try row.text(4).flatMap(ActOutcomeKind.init(rawValue:)))
        }
    }

    /// The arguments withheld from a call's record, as `name#position`.
    static func withheldArguments(_ handle: some SQLiteQuerying, _ callEventID: String) throws -> Set<String> {
        Set(try handle.query(
            """
            SELECT argument_name, argument_position FROM memory_value_redactions
            WHERE event_id = ? AND location_kind = 'argument'
            """,
            [.text(callEventID)]
        ) { "\(try $0.text(0) ?? "")#\($0.integer(1) ?? 0)" })
    }

    /// The structural scene a call's sample of `phase` was confirmed in, or nil.
    static func confirmedScene(_ handle: some SQLiteQuerying, eventID: String, phase: CapturePhase) throws -> String? {
        try handle.query(
            """
            SELECT scene_id FROM memory_event_scenes
            WHERE event_id = ? AND phase = ? AND sample_ordinal = 0 AND match_status = 'confirmed'
            """,
            [.text(eventID), .text(phase.rawValue)]
        ) { try $0.text(0) }.first ?? nil
    }

    // MARK: Occurrences

    /// The occurrence of a step's call, written once and kept in step with the call: assigned to the
    /// attempt by the segmentation, the call as its action, and every verification of the call
    /// attributed to it with its membership. Its instants are the call's; an end the calendar placed
    /// before the start is left unknown rather than moved.
    static func ensureOccurrence(_ transaction: SQLiteTransaction, step: ProcedureCandidate.Step, attemptID: String) throws {
        guard let call = try SQLiteAgentCallRows.call(transaction, eventID: step.callEventID) else {
            throw ProcedureError.unknownReference("call \(step.callEventID)")
        }
        let status: TaskStatus = switch call.progress.status {
            case .completed  : .completed
            case .failed     : .failed
            case .cancelled  : .cancelled
            case .interrupted: .interrupted
            default          : .inProgress
        }
        let start = call.startedAtMS ?? call.event.occurredAtMS
        let end   = call.progress.endedAtMS.flatMap { $0 >= start ? $0 : nil }
        let record = try StepOccurrenceRecord(stepOccurrenceID: step.stepOccurrenceID, startedAtMS: start, endedAtMS: end,
                                              status: status)
        if let stored = try SQLiteStepRows.occurrence(transaction, id: step.stepOccurrenceID) {
            if !stored.record.isExactly(record) {
                try transaction.execute(
                    "UPDATE memory_step_occurrences SET ended_at_ms = ?, status = ? WHERE step_occurrence_id = ?",
                    [end.map(SQLiteValue.integer) ?? .null, .text(status.rawValue), .text(step.stepOccurrenceID)]
                )
            }
        } else {
            try transaction.execute(
                """
                INSERT INTO memory_step_occurrences (step_occurrence_id, task_occurrence_id, started_at_ms, ended_at_ms, status,
                    assigned_by) VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(step.stepOccurrenceID), .text(attemptID), .integer(start), end.map(SQLiteValue.integer) ?? .null,
                 .text(status.rawValue), .text(SQLiteProcedureRepository.segmentationAuthor)]
            )
            _ = try SQLiteStepRows.record(transaction, try StepMembership(
                stepOccurrenceID: step.stepOccurrenceID, eventID: step.callEventID, position: 0, role: .action
            ))
        }
        let verifications = try transaction.query(
            "SELECT event_id FROM memory_operation_verifications WHERE call_event_id = ? ORDER BY event_id",
            [.text(step.callEventID)]
        ) { try $0.text(0) ?? "" }
        let members = try SQLiteStepRows.memberships(transaction, of: step.stepOccurrenceID)
        var next = Int64((members.map(\.position).max() ?? 0) + 1)
        for verification in verifications where !members.contains(where: { $0.eventID.utf8.elementsEqual(verification.utf8) }) {
            let attributed = try transaction.query(
                "SELECT step_occurrence_id FROM memory_verifications WHERE event_id = ?", [.text(verification)]
            ) { try $0.text(0) }.first ?? nil
            if let attributed, !attributed.utf8.elementsEqual(step.stepOccurrenceID.utf8) {
                throw EventFactError.alreadyAttributed(eventID: verification)
            }
            if attributed == nil {
                try transaction.execute("UPDATE memory_verifications SET step_occurrence_id = ? WHERE event_id = ?",
                                        [.text(step.stepOccurrenceID), .text(verification)])
            }
            _ = try SQLiteStepRows.record(transaction, try StepMembership(
                stepOccurrenceID: step.stepOccurrenceID, eventID: verification, position: next, role: .verification
            ))
            next += 1
        }
    }

    // MARK: Candidates

    static func insert(_ transaction: SQLiteTransaction, _ candidate: ProcedureCandidate) throws {
        try transaction.execute(
            """
            INSERT INTO memory_procedure_candidates (candidate_id, task_id, task_occurrence_id, policy_version, structure_digest,
                checkpoint_sequence, built_at_ms, step_count, block_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(candidate.candidateID), .text(candidate.taskID), .text(candidate.attemptID), .text(candidate.policyVersion),
             .text(candidate.structureDigest), candidate.checkpointSequence.map { .integer(Int64($0)) } ?? .null,
             .integer(candidate.builtAtMS), .integer(Int64(candidate.steps.count)), .integer(Int64(candidate.blocks.count))]
        )
        for step in candidate.steps {
            let appID = try step.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute(
                """
                INSERT INTO memory_candidate_steps (candidate_id, position, step_occurrence_id, call_event_id, block_index, app_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(candidate.candidateID), .integer(Int64(step.position)), .text(step.stepOccurrenceID), .text(step.callEventID),
                 .integer(Int64(step.blockIndex)), appID.map(SQLiteValue.integer) ?? .null]
            )
        }
    }

    static func candidate(_ handle: some SQLiteQuerying, _ candidateID: String) throws -> ProcedureCandidate? {
        guard let head = try handle.query(
            """
            SELECT task_id, task_occurrence_id, policy_version, structure_digest, checkpoint_sequence, built_at_ms, step_count
            FROM memory_procedure_candidates WHERE candidate_id = ?
            """,
            [.text(candidateID)],
            { (task: try $0.text(0) ?? "", attempt: try $0.text(1) ?? "", policy: try $0.text(2) ?? "", digest: try $0.text(3) ?? "",
               checkpoint: $0.integer(4), built: $0.integer(5) ?? 0, count: $0.integer(6) ?? 0) }
        ).first else { return nil }
        let steps = try handle.query(
            """
            SELECT s.position, s.step_occurrence_id, s.call_event_id, s.block_index, b.bundle_id
            FROM memory_candidate_steps s LEFT JOIN brain_apps b ON b.app_id = s.app_id
            WHERE s.candidate_id = ? ORDER BY s.position
            """,
            [.text(candidateID)]
        ) { row in
            ProcedureCandidate.Step(position: Int(row.integer(0) ?? -1), stepOccurrenceID: try row.text(1) ?? "",
                                    callEventID: try row.text(2) ?? "", blockIndex: Int(row.integer(3) ?? -1),
                                    bundleID: try row.text(4))
        }
        guard Int64(steps.count) == head.count else { throw malformed("memory_candidate_steps", candidateID, "step count") }
        do {
            return try ProcedureCandidate(candidateID: candidateID, taskID: head.task, attemptID: head.attempt,
                                          policyVersion: head.policy, structureDigest: head.digest,
                                          checkpointSequence: head.checkpoint.map { Int($0) }, builtAtMS: head.built, steps: steps)
        } catch let error as ProcedureError {
            throw malformed("memory_procedure_candidates", candidateID, "\(error)")
        }
    }

    static func latestCandidateID(_ handle: some SQLiteQuerying, attemptID: String) throws -> String? {
        try handle.query(
            """
            SELECT candidate_id FROM memory_procedure_candidates WHERE task_occurrence_id = ?
            ORDER BY built_at_ms DESC, rowid DESC LIMIT 1
            """,
            [.text(attemptID)]
        ) { try $0.text(0) }.first ?? nil
    }

    // MARK: Interpretations

    struct StoredInterpretation {
        let id: String
        let revision: Int
        let digest: String
        let state: InterpretationState
    }

    static func interpretations(_ handle: some SQLiteQuerying, candidateID: String) throws -> [StoredInterpretation] {
        try handle.query(
            """
            SELECT interpretation_id, revision, payload_digest, attempt_state FROM memory_procedure_interpretations
            WHERE candidate_id = ? ORDER BY revision
            """,
            [.text(candidateID)]
        ) { row in
            let id = try row.text(0) ?? ""
            guard let state = InterpretationState(rawValue: try row.text(3) ?? "") else {
                throw malformed("memory_procedure_interpretations", id, "attempt_state")
            }
            return StoredInterpretation(id: id, revision: Int(row.integer(1) ?? 0), digest: try row.text(2) ?? "", state: state)
        }
    }

    static func insertInterpretation(_ transaction: SQLiteTransaction, _ version: ProcedureVersion, digest: String,
                                     producer: TaskProducer, taskRevision: Int, state: InterpretationState, at nowMS: Int64) throws {
        try transaction.execute(
            """
            INSERT INTO memory_procedure_interpretations (interpretation_id, candidate_id, revision, contract_version, payload_digest,
                source, source_stream_id, task_revision, attempt_state, recorded_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(version.interpretationID), .text(version.candidateID), .integer(Int64(version.revision)),
             .integer(Int64(version.contractVersion)), .text(digest), .text(producer.source.rawValue), .text(producer.streamID),
             .integer(Int64(taskRevision)), .text(state.rawValue), .integer(nowMS)]
        )
        for (position, finding) in version.findings.enumerated() {
            try transaction.execute(
                """
                INSERT INTO memory_interpretation_findings (interpretation_id, position, finding, step_position, argument_name,
                    argument_position) VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(version.interpretationID), .integer(Int64(position)), .text(finding.kind.rawValue),
                 .integer(Int64(finding.stepPosition)), .text(finding.argumentName), .integer(Int64(finding.argumentPosition))]
            )
        }
    }

    /// The outcome of a stored interpretation, read back for a repeated offer.
    static func outcome(_ handle: some SQLiteQuerying, candidateID: String, revision: Int,
                        receipt: MemoryReceipt) throws -> InterpretationOutcome {
        let routeID = ProcedureAssembly.routeID(candidateID: candidateID, revision: revision)
        guard let stored = try stored(handle, routeID: routeID) else {
            throw malformed("memory_procedure_versions", routeID, "an interpretation without its version")
        }
        let qualifications = stored.version.parts.compactMap { stored.qualifications[$0.partID] }
        return InterpretationOutcome(receipt: receipt, revision: revision, routeID: routeID, findings: stored.version.findings,
                                     qualifications: qualifications)
    }

    // MARK: Versions

    /// The version of an attempt no other version supersedes, or nil when it has none.
    static func currentVersion(_ handle: some SQLiteQuerying, attemptID: String) throws -> String? {
        try handle.query(
            """
            SELECT v.route_id FROM memory_procedure_versions v
            WHERE v.task_occurrence_id = ? AND NOT EXISTS (SELECT 1 FROM memory_routes r WHERE r.supersedes_route_id = v.route_id)
            ORDER BY v.built_at_ms DESC, v.route_id DESC LIMIT 1
            """,
            [.text(attemptID)]
        ) { try $0.text(0) }.first ?? nil
    }

    static func insert(_ transaction: SQLiteTransaction, _ version: ProcedureVersion, contract: [PartContractItem]) throws {
        try transaction.execute(
            """
            INSERT INTO memory_procedure_versions (route_id, interpretation_id, candidate_id, task_id, task_occurrence_id,
                contract_version, variant_of_route_id, divergence_position, built_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(version.routeID), .text(version.interpretationID), .text(version.candidateID), .text(version.taskID),
             .text(version.attemptID), .integer(Int64(version.contractVersion)), version.variantOf.map(SQLiteValue.text) ?? .null,
             version.divergencePosition.map { .integer(Int64($0)) } ?? .null, .integer(version.builtAtMS)]
        )
        for part in version.parts {
            let appID = try part.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute(
                """
                INSERT INTO memory_procedure_parts (part_id, route_id, part_kind, parent_part_id, first_position, last_position,
                    step_id, app_id, label, declared_outcome) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(part.partID), .text(part.routeID), .text(part.kind.rawValue), part.parentPartID.map(SQLiteValue.text) ?? .null,
                 .integer(Int64(part.firstPosition)), .integer(Int64(part.lastPosition)), part.stepID.map(SQLiteValue.text) ?? .null,
                 appID.map(SQLiteValue.integer) ?? .null, part.label.map(SQLiteValue.text) ?? .null, .text(part.declaredOutcome.rawValue)]
            )
        }
        for detail in version.parameterDetails {
            try transaction.execute(
                """
                INSERT INTO memory_parameter_details (parameter_id, route_id, role, value_kind, unit, sensitivity, produced_by_part_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(detail.parameterID), .text(version.routeID), .text(detail.role), .text(detail.kind.rawValue),
                 detail.unit.map(SQLiteValue.text) ?? .null, .text(detail.sensitivity.rawValue),
                 detail.producedByPartID.map(SQLiteValue.text) ?? .null]
            )
        }
        for item in contract {
            let appID = try item.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            try transaction.execute(
                """
                INSERT INTO memory_part_contract_items (part_id, position, route_id, item_kind, parameter_id, app_id, scene_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(item.partID), .integer(Int64(item.position)), .text(version.routeID), .text(item.kind.rawValue),
                 item.parameterID.map(SQLiteValue.text) ?? .null, appID.map(SQLiteValue.integer) ?? .null,
                 item.sceneID.map(SQLiteValue.text) ?? .null]
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
                    source_ref, source_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(binding.parameterID), .text(version.routeID), .text(binding.attemptID), .text(content), text,
                 .text(binding.source.rawValue), binding.sourceRef.map(SQLiteValue.text) ?? .null,
                 binding.sourceVersion.map(SQLiteValue.text) ?? .null]
            )
        }
        for mapping in version.stepOccurrences {
            try transaction.execute(
                "INSERT INTO memory_procedure_step_occurrences (route_id, step_id, step_occurrence_id) VALUES (?, ?, ?)",
                [.text(version.routeID), .text(mapping.stepID), .text(mapping.stepOccurrenceID)]
            )
        }
    }

    /// The details of a version's parameters: role, kind, unit, sensitivity and producing part.
    static func parameterDetails(_ handle: some SQLiteQuerying, routeID: String) throws -> [ParameterDetail] {
        try handle.query(
            """
            SELECT parameter_id, role, value_kind, unit, sensitivity, produced_by_part_id FROM memory_parameter_details
            WHERE route_id = ? ORDER BY parameter_id
            """,
            [.text(routeID)]
        ) { row -> ParameterDetail in
            let id = try row.text(0) ?? ""
            guard let kind = TaskValueKind(rawValue: try row.text(2) ?? ""),
                  let sensitivity = TaskValueSensitivity(rawValue: try row.text(4) ?? "") else {
                throw malformed("memory_parameter_details", id, "value_kind or sensitivity")
            }
            return ParameterDetail(parameterID: id, role: try row.text(1) ?? "", kind: kind, unit: try row.text(3),
                                   sensitivity: sensitivity, producedByPartID: try row.text(5))
        }
    }

    static func stored(_ handle: some SQLiteQuerying, routeID: String) throws -> StoredProcedureVersion? {
        guard let head = try handle.query(
            """
            SELECT v.interpretation_id, v.candidate_id, v.task_id, v.task_occurrence_id, v.contract_version, v.variant_of_route_id,
                   v.divergence_position, v.built_at_ms, i.revision, i.attempt_state
            FROM memory_procedure_versions v JOIN memory_procedure_interpretations i ON i.interpretation_id = v.interpretation_id
            WHERE v.route_id = ?
            """,
            [.text(routeID)],
            { (interpretation: try $0.text(0) ?? "", candidate: try $0.text(1) ?? "", task: try $0.text(2) ?? "",
               attempt: try $0.text(3) ?? "", contract: Int($0.integer(4) ?? 0), variant: try $0.text(5),
               divergence: $0.integer(6).map { Int($0) }, built: $0.integer(7) ?? 0, revision: Int($0.integer(8) ?? 0),
               state: try $0.text(9) ?? "") }
        ).first else { return nil }
        guard let state = InterpretationState(rawValue: head.state) else {
            throw malformed("memory_procedure_interpretations", head.interpretation, "attempt_state")
        }
        guard let route = try SQLiteRouteRows.read(handle, routeID: routeID) else {
            throw malformed("memory_procedure_versions", routeID, "a version without its Route")
        }
        let parts = try self.parts(handle, routeID: routeID)
        let details = try parameterDetails(handle, routeID: routeID)
        let bindings = try handle.query(
            """
            SELECT parameter_id, task_occurrence_id, content, text_value, source, source_ref, source_version
            FROM memory_parameter_bindings WHERE route_id = ? ORDER BY parameter_id
            """,
            [.text(routeID)]
        ) { row -> ParameterBinding in
            let id = try row.text(0) ?? ""
            let content: TaskValue.Content = switch try row.text(2) ?? "" {
                case "text": .text(try row.text(3) ?? "")
                case "withheld": .withheld
                default: .missing
            }
            guard let source = TaskValueSource(rawValue: try row.text(4) ?? "") else {
                throw malformed("memory_parameter_bindings", id, "source")
            }
            return ParameterBinding(parameterID: id, attemptID: try row.text(1) ?? "", content: content, source: source,
                                    sourceRef: try row.text(5), sourceVersion: try row.text(6))
        }
        let findings = try self.findings(handle, interpretationID: head.interpretation)
        let occurrences = try handle.query(
            """
            SELECT o.step_id, o.step_occurrence_id FROM memory_procedure_step_occurrences o
            JOIN memory_route_steps s ON s.step_id = o.step_id WHERE o.route_id = ? ORDER BY s.position
            """,
            [.text(routeID)]
        ) { (stepID: try $0.text(0) ?? "", stepOccurrenceID: try $0.text(1) ?? "") }
        var withheld: Set<Int> = []
        for step in route.definition.steps {
            guard let call = try handle.query(
                "SELECT call_event_id FROM memory_candidate_steps WHERE candidate_id = ? AND position = ?",
                [.text(head.candidate), .integer(Int64(step.position))],
                { try $0.text(0) }
            ).first ?? nil else { continue }
            let keys = try withheldArguments(handle, call)
            for operation in step.operations {
                for argument in operation.arguments {
                    if case .literal = argument.value, keys.contains("\(argument.name)#\(argument.position)") { withheld.insert(step.position) }
                }
            }
        }
        let version = ProcedureVersion(
            routeID: routeID, interpretationID: head.interpretation, revision: head.revision, candidateID: head.candidate,
            taskID: head.task, attemptID: head.attempt, contractVersion: head.contract, variantOf: head.variant,
            divergencePosition: head.divergence, builtAtMS: head.built, definition: route.definition, parts: parts,
            parameterDetails: details, bindings: bindings, findings: findings, stepOccurrences: occurrences,
            withheldLiteralSteps: withheld
        )
        var qualifications: [String: PartQualification] = [:]
        var states: [String: PartOperationalState] = [:]
        for part in parts {
            if let latest = try latestQualification(handle, partID: part.partID) { qualifications[part.partID] = latest }
            if let state = try latestState(handle, partID: part.partID) { states[part.partID] = state }
        }
        let isCurrent = !(try SQLiteFactRows.exists(handle, "SELECT count(*) FROM memory_routes WHERE supersedes_route_id = ?", routeID))
        let contract = try contract(handle, routeID: routeID)
        // An entry state stated unknown is read again from its step's sample: an association that came
        // after the build is said beside the contract, which stays as it was built.
        var lateEntryStates: [String: String] = [:]
        for item in contract where item.kind == .entryState && item.sceneID == nil {
            guard let part = version.parts.first(where: { $0.partID == item.partID }),
                  version.definition.steps.indices.contains(part.firstPosition) else { continue }
            let stepID = version.definition.steps[part.firstPosition].stepID
            guard let occurrence = version.stepOccurrences.first(where: { $0.stepID == stepID })?.stepOccurrenceID,
                  let call = try handle.query(
                      "SELECT event_id FROM memory_step_events WHERE step_occurrence_id = ? AND role = 'action'", [.text(occurrence)],
                      { try $0.text(0) }
                  ).first ?? nil else { continue }
            if let scene = try confirmedScene(handle, eventID: call, phase: .before) { lateEntryStates[item.partID] = scene }
        }
        let prefix = try handle.query(
            "SELECT status, compared_steps, reason FROM memory_variant_prefix_checks WHERE route_id = ?", [.text(routeID)]
        ) { row -> VariantPrefix.Check in
            guard let status = VariantPrefix.Status(rawValue: try row.text(0) ?? "") else {
                throw malformed("memory_variant_prefix_checks", routeID, "status")
            }
            let reason = try row.text(2).map { code -> VariantPrefix.Unproven in
                guard let known = VariantPrefix.Unproven(rawValue: code) else { throw malformed("memory_variant_prefix_checks", routeID, "reason") }
                return known
            }
            return VariantPrefix.Check(status: status, comparedSteps: Int(row.integer(1) ?? 0), reason: reason)
        }.first
        return StoredProcedureVersion(version: version, interpretationState: state, contract: contract,
                                      qualifications: qualifications, states: states, isCurrent: isCurrent,
                                      variantPrefix: prefix, lateEntryStates: lateEntryStates)
    }

    static func parts(_ handle: some SQLiteQuerying, routeID: String) throws -> [ProcedurePart] {
        try handle.query(
            """
            SELECT p.part_id, p.part_kind, p.parent_part_id, p.first_position, p.last_position, p.step_id, b.bundle_id, p.label,
                   p.declared_outcome
            FROM memory_procedure_parts p LEFT JOIN brain_apps b ON b.app_id = p.app_id
            WHERE p.route_id = ?
            ORDER BY CASE p.part_kind WHEN 'procedure' THEN 0 WHEN 'subprocedure' THEN 1 ELSE 2 END, p.first_position
            """,
            [.text(routeID)]
        ) { row in
            let id = try row.text(0) ?? ""
            guard let kind = PartKind(rawValue: try row.text(1) ?? ""),
                  let outcome = DeclaredPartOutcome(rawValue: try row.text(8) ?? "") else {
                throw malformed("memory_procedure_parts", id, "part_kind or declared_outcome")
            }
            return try ProcedurePart(partID: id, routeID: routeID, kind: kind, parentPartID: try row.text(2),
                                     firstPosition: Int(row.integer(3) ?? -1), lastPosition: Int(row.integer(4) ?? -1),
                                     stepID: try row.text(5), bundleID: try row.text(6), label: try row.text(7),
                                     declaredOutcome: outcome)
        }
    }

    static func findings(_ handle: some SQLiteQuerying, interpretationID: String) throws -> [InterpretationFinding] {
        try handle.query(
            """
            SELECT finding, step_position, argument_name, argument_position FROM memory_interpretation_findings
            WHERE interpretation_id = ? ORDER BY position
            """,
            [.text(interpretationID)]
        ) { row in
            guard let kind = InterpretationFinding.Kind(rawValue: try row.text(0) ?? "") else {
                throw malformed("memory_interpretation_findings", interpretationID, "finding")
            }
            return InterpretationFinding(kind: kind, stepPosition: Int(row.integer(1) ?? 0), argumentName: try row.text(2) ?? "",
                                         argumentPosition: Int(row.integer(3) ?? 0))
        }
    }

    static func contract(_ handle: some SQLiteQuerying, routeID: String) throws -> [PartContractItem] {
        try handle.query(
            """
            SELECT c.part_id, c.position, c.item_kind, c.parameter_id, b.bundle_id, c.scene_id
            FROM memory_part_contract_items c LEFT JOIN brain_apps b ON b.app_id = c.app_id
            WHERE c.route_id = ? ORDER BY c.part_id, c.position
            """,
            [.text(routeID)]
        ) { row in
            let id = try row.text(0) ?? ""
            guard let kind = PartContractItem.Kind(rawValue: try row.text(2) ?? "") else {
                throw malformed("memory_part_contract_items", id, "item_kind")
            }
            return try PartContractItem(partID: id, position: Int(row.integer(1) ?? 0), kind: kind, parameterID: try row.text(3),
                                        bundleID: try row.text(4), sceneID: try row.text(5))
        }
    }

    // MARK: Qualification

    /// The policy in force is recorded once, active, before it decides anything.
    static func ensurePolicy(_ transaction: SQLiteTransaction, at nowMS: Int64) throws {
        try transaction.execute(
            """
            INSERT INTO memory_qualification_policies (policy_version, status, changed_at_ms, reason)
            VALUES (?, 'active', ?, NULL) ON CONFLICT (policy_version) DO NOTHING
            """,
            [.text(QualificationPolicy.version), .integer(nowMS)]
        )
    }

    /// Evaluates every part of a version from the facts in the transaction and appends an evaluation for
    /// a part whose latest one under this policy decides otherwise; answers the current evaluations.
    static func qualify(_ transaction: SQLiteTransaction, routeID: String, at nowMS: Int64) throws -> [PartQualification] {
        guard let stored = try stored(transaction, routeID: routeID) else {
            throw ProcedureError.unknownReference("version \(routeID)")
        }
        let version  = stored.version
        let attempt  = try SQLiteTaskContextRows.checkpoints(transaction, of: version.attemptID).last { $0.kind == .end }?.declared
        let missing  = Set(version.bindings.filter { if case .missing = $0.content { true } else { false } }.map(\.parameterID))
        var steps: [Int: QualificationPolicy.StepFacts] = [:]
        for (position, mapping) in version.stepOccurrences.enumerated() {
            guard let call = try transaction.query(
                "SELECT event_id FROM memory_step_events WHERE step_occurrence_id = ? AND role = 'action'",
                [.text(mapping.stepOccurrenceID)],
                { try $0.text(0) }
            ).first ?? nil, let stored = try SQLiteAgentCallRows.call(transaction, eventID: call) else {
                throw malformed("memory_procedure_step_occurrences", mapping.stepOccurrenceID, "an occurrence without its call")
            }
            let gaps = try SQLiteOperationFactRows.recordingGaps(transaction, call)
            let ids = try transaction.query(
                "SELECT event_id FROM memory_operation_verifications WHERE call_event_id = ? ORDER BY event_id", [.text(call)]
            ) { try $0.text(0) ?? "" }
            let verifications = try ids.compactMap { try SQLiteOperationFactRows.verification(transaction, $0) }.map {
                QualificationPolicy.VerificationFact(eventID: $0.event.eventID, condition: $0.check.condition, verdict: $0.check.verdict,
                                                     performed: $0.check.performed, limits: $0.check.limits)
            }
            var reads: [String] = []
            for operation in version.definition.steps[position].operations {
                for argument in operation.arguments {
                    switch argument.value {
                        case .parameter(let id): reads.append(id)
                        case .template(let segments): for case .parameter(let id) in segments { reads.append(id) }
                        default: break
                    }
                }
            }
            steps[position] = QualificationPolicy.StepFacts(
                position            : position,
                callEventID         : call,
                status              : stored.progress.status,
                hasRecordingGap     : !gaps.isEmpty,
                verifications       : verifications,
                findings            : version.findings.filter { $0.stepPosition == position }.map(\.kind),
                keepsWithheldLiteral: version.withheldLiteralSteps.contains(position),
                missingInputs       : reads.filter(missing.contains)
            )
        }
        var current: [PartQualification] = []
        // Parts come coarser first, so a part's parent has its effective outcome before the part is read.
        var outcomes: [String: DeclaredPartOutcome] = [:]
        for part in version.parts {
            let parent = part.parentPartID.flatMap { outcomes[$0] }
            outcomes[part.partID] = QualificationPolicy.effectiveOutcome(of: part, parent: parent, attemptEnd: attempt)
            let facts = QualificationPolicy.PartFacts(
                part               : part,
                attemptEnd         : attempt,
                interpretationState: stored.interpretationState,
                parentOutcome      : parent,
                steps              : (part.firstPosition...part.lastPosition).compactMap { steps[$0] }
            )
            let evaluation = QualificationPolicy.evaluate(facts)
            if let latest = try latestQualification(transaction, partID: part.partID),
               latest.policyVersion == evaluation.policyVersion, latest.decidesSame(as: evaluation) {
                current.append(latest)
                continue
            }
            try insert(transaction, evaluation, at: nowMS)
            current.append(evaluation)
        }
        return current
    }

    static func insert(_ transaction: SQLiteTransaction, _ evaluation: PartQualification, at nowMS: Int64) throws {
        let sequence = (try transaction.query(
            "SELECT ifnull(max(sequence), 0) FROM memory_part_qualifications WHERE part_id = ?", [.text(evaluation.partID)]
        ) { $0.integer(0) ?? 0 }.first ?? 0) + 1
        try transaction.execute(
            """
            INSERT INTO memory_part_qualifications (part_id, sequence, policy_version, verdict, evaluated_at_ms)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(evaluation.partID), .integer(sequence), .text(evaluation.policyVersion), .text(evaluation.verdict.rawValue),
             .integer(nowMS)]
        )
        for (position, finding) in evaluation.findings.enumerated() {
            try transaction.execute(
                """
                INSERT INTO memory_part_qualification_reasons (part_id, sequence, position, reason, step_position, call_event_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(evaluation.partID), .integer(sequence), .integer(Int64(position)), .text(finding.reason.rawValue),
                 finding.stepPosition.map { .integer(Int64($0)) } ?? .null, finding.callEventID.map(SQLiteValue.text) ?? .null]
            )
        }
        for item in evaluation.evidence {
            try transaction.execute(
                """
                INSERT INTO memory_part_qualification_evidence (part_id, sequence, step_position, call_event_id, verification_event_id)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.text(evaluation.partID), .integer(sequence), .integer(Int64(item.stepPosition)), .text(item.callEventID),
                 .text(item.verificationEventID)]
            )
        }
    }

    static func latestQualification(_ handle: some SQLiteQuerying, partID: String) throws -> PartQualification? {
        guard let head = try handle.query(
            """
            SELECT sequence, policy_version FROM memory_part_qualifications WHERE part_id = ?
            ORDER BY sequence DESC LIMIT 1
            """,
            [.text(partID)],
            { ($0.integer(0) ?? 0, try $0.text(1) ?? "") }
        ).first else { return nil }
        let findings = try handle.query(
            """
            SELECT reason, step_position, call_event_id FROM memory_part_qualification_reasons
            WHERE part_id = ? AND sequence = ? ORDER BY position
            """,
            [.text(partID), .integer(head.0)]
        ) { row -> PartQualification.Finding in
            guard let reason = PartQualification.Reason(rawValue: try row.text(0) ?? "") else {
                throw malformed("memory_part_qualification_reasons", partID, "reason")
            }
            return PartQualification.Finding(reason: reason, stepPosition: row.integer(1).map { Int($0) }, callEventID: try row.text(2))
        }
        let evidence = try handle.query(
            """
            SELECT step_position, call_event_id, verification_event_id FROM memory_part_qualification_evidence
            WHERE part_id = ? AND sequence = ? ORDER BY step_position
            """,
            [.text(partID), .integer(head.0)]
        ) { PartQualification.Evidence(stepPosition: Int($0.integer(0) ?? 0), callEventID: try $0.text(1) ?? "",
                                       verificationEventID: try $0.text(2) ?? "") }
        return PartQualification(partID: partID, policyVersion: head.1, findings: findings, evidence: evidence)
    }

    static func latestState(_ handle: some SQLiteQuerying, partID: String) throws -> PartOperationalState? {
        try handle.query(
            "SELECT state FROM memory_part_states WHERE part_id = ? ORDER BY sequence DESC LIMIT 1", [.text(partID)]
        ) { row -> PartOperationalState in
            guard let state = PartOperationalState(rawValue: try row.text(0) ?? "") else {
                throw malformed("memory_part_states", partID, "state")
            }
            return state
        }.first
    }

    // MARK: Inspection

    static func inspection(_ handle: some SQLiteQuerying, taskID: String) throws -> ProcedureInspection? {
        guard let task = try SQLiteTaskContextRows.task(handle, taskID) else { return nil }
        let goal = try SQLiteTaskContextRows.revision(handle, taskID, task.currentRevision)?.content.goal ?? ""
        var attempts: [ProcedureInspection.Attempt] = []
        var calls: [String] = []
        for attempt in try SQLiteTaskContextRows.attempts(handle, of: taskID) {
            let rows = try handle.query(
                """
                SELECT m.event_id, m.position, a.tool_kind, a.execution_status, b.bundle_id, e.parent_event_id, a.result_kind
                FROM memory_task_events m JOIN memory_agent_actions a ON a.event_id = m.event_id
                JOIN memory_events e ON e.event_id = m.event_id LEFT JOIN brain_apps b ON b.app_id = a.app_id
                WHERE m.task_occurrence_id = ? AND m.role IN ('action', 'context') ORDER BY m.position
                """,
                [.text(attempt.attempt.attemptID)]
            ) { (id: try $0.text(0) ?? "", position: Int($0.integer(1) ?? 0), tool: try $0.text(2) ?? "", status: try $0.text(3) ?? "",
                 bundle: try $0.text(4), parent: try $0.text(5), result: try $0.text(6)) }
            var listed: [ProcedureInspection.Call] = []
            func call(_ id: String, position: Int, tool code: String, status statusCode: String, bundle: String?,
                      parent: String?, result: String?) throws -> ProcedureInspection.Call {
                guard let tool = AgentTool(rawValue: code), let status = AgentCallStatus(rawValue: statusCode) else {
                    throw malformed("memory_agent_actions", id, "tool or status")
                }
                let role: ProcedureInspection.CallRole
                if tool == .batch { role = .container }
                else if tool.isOperation, status == .planned || status == .skipped { role = .skipped }
                else if ProcedureSegmentation.isListing(tool: tool, resultKind: result.flatMap(ActOutcomeKind.init(rawValue:))) {
                    role = .context
                }
                else if tool.isOperation { role = .step }
                else { role = .context }
                let occurrence = try handle.query(
                    "SELECT step_occurrence_id FROM memory_step_events WHERE event_id = ? AND role = 'action'", [.text(id)]
                ) { try $0.text(0) }.first ?? nil
                let check = try handle.query(
                    """
                    SELECT v.condition_kind || ' ' || b.verdict FROM memory_operation_verifications v
                    JOIN memory_verifications b ON b.event_id = v.event_id WHERE v.call_event_id = ? ORDER BY v.event_id
                    """,
                    [.text(id)]
                ) { try $0.text(0) }.first ?? nil
                // The latest evaluation; a call only brain-relations-1 applied says so until it is evaluated again.
                let brain = try handle.query(
                    """
                    SELECT outcome || ifnull(':' || reason, '') || ' (' || cause || ', ' || sequence || ')' FROM brain_relation_evaluations
                    WHERE call_event_id = ? ORDER BY sequence DESC LIMIT 1
                    """,
                    [.text(id)]
                ) { try $0.text(0) }.first ?? (try handle.query(
                    "SELECT 'brain-relations-1 ' || outcome || ifnull(':' || reason, '') FROM brain_relation_applications WHERE call_event_id = ?",
                    [.text(id)]
                ) { try $0.text(0) }.first ?? nil)
                return ProcedureInspection.Call(callEventID: id, position: position, tool: tool, status: status, bundleID: bundle,
                                                parentEventID: parent, role: role, stepOccurrenceID: occurrence, check: check,
                                                brain: brain)
            }
            for row in rows {
                listed.append(try call(row.id, position: row.position, tool: row.tool, status: row.status, bundle: row.bundle,
                                       parent: row.parent, result: row.result))
                guard row.tool == AgentTool.batch.rawValue else { continue }
                // A batch's steps that never started were never attributed: they are read through their parent.
                let unrun = try handle.query(
                    """
                    SELECT e.event_id, a.tool_kind, a.execution_status, b.bundle_id FROM memory_events e
                    JOIN memory_agent_actions a ON a.event_id = e.event_id LEFT JOIN brain_apps b ON b.app_id = a.app_id
                    WHERE e.parent_event_id = ? AND a.execution_status IN ('planned', 'skipped')
                      AND NOT EXISTS (SELECT 1 FROM memory_task_events t WHERE t.event_id = e.event_id AND t.task_occurrence_id = ?)
                    ORDER BY e.parent_position
                    """,
                    [.text(row.id), .text(attempt.attempt.attemptID)]
                ) { (id: try $0.text(0) ?? "", tool: try $0.text(1) ?? "", status: try $0.text(2) ?? "", bundle: try $0.text(3)) }
                for child in unrun {
                    listed.append(try call(child.id, position: row.position, tool: child.tool, status: child.status,
                                           bundle: child.bundle, parent: row.id, result: nil))
                }
            }
            calls += listed.map(\.callEventID)
            let candidates = try handle.query(
                "SELECT candidate_id FROM memory_procedure_candidates WHERE task_occurrence_id = ? ORDER BY built_at_ms, rowid",
                [.text(attempt.attempt.attemptID)]
            ) { try $0.text(0) ?? "" }.compactMap { try candidate(handle, $0) }
            let versions = try handle.query(
                "SELECT route_id FROM memory_procedure_versions WHERE task_occurrence_id = ? ORDER BY built_at_ms, route_id",
                [.text(attempt.attempt.attemptID)]
            ) { try $0.text(0) ?? "" }.compactMap { try stored(handle, routeID: $0) }
            attempts.append(ProcedureInspection.Attempt(attempt: attempt, calls: listed, candidates: candidates, versions: versions))
        }
        var relations: [BrainRelation] = []
        var seen: Set<String> = []
        for call in calls {
            let ids = try handle.query(
                """
                SELECT relation_id FROM brain_relation_evidence e WHERE call_event_id = ?
                  AND sequence = (SELECT max(v.sequence) FROM brain_relation_evaluations v WHERE v.call_event_id = e.call_event_id)
                ORDER BY relation_id
                """,
                [.text(call)]
            ) { try $0.text(0) ?? "" }
            for id in ids where seen.insert(id).inserted {
                guard let appID = try handle.query("SELECT app_id FROM brain_relations WHERE relation_id = ?", [.text(id)],
                                                   { $0.integer(0) }).first ?? nil,
                      let key = try SQLiteBrainRelationRows.relation(handle, relationID: id) else { continue }
                if let found = try SQLiteBrainRelationRows.relations(handle, appID: appID, bundleID: key.bundleID, from: key.fromSceneID,
                                                                    elementKeys: key.elementKey.map { [$0] } ?? [],
                                                                    includingContext: key.elementKey == nil)
                    .first(where: { $0.relationID == id }) {
                    relations.append(found)
                }
            }
        }
        let all = attempts.flatMap(\.calls)
        let parts = attempts.flatMap(\.versions).flatMap { stored in stored.version.parts.compactMap { stored.qualifications[$0.partID] } }
        var offered: Set<String> = []
        for routeID in attempts.flatMap(\.versions).map(\.version.routeID) {
            offered.formUnion(try handle.query(SQLiteProcedureRows.offered + " AND p.route_id = ?", [.text(routeID)]) { try $0.text(0) ?? "" })
        }
        let legacy = try handle.query(
            "SELECT count(*) FROM memory_routes r WHERE NOT EXISTS (SELECT 1 FROM memory_procedure_versions v WHERE v.route_id = r.route_id)",
            []
        ) { Int($0.integer(0) ?? 0) }.first ?? 0
        let counts = ProcedureInspection.Counts(
            operationalSteps: all.filter { $0.role == .step }.count, containers: all.filter { $0.role == .container }.count,
            skipped: all.filter { $0.role == .skipped }.count, contextCalls: all.filter { $0.role == .context }.count,
            candidates: attempts.map(\.candidates.count).reduce(0, +), versions: attempts.map(\.versions.count).reduce(0, +),
            admittedParts: parts.filter { $0.verdict == .admitted }.count, refusedParts: parts.filter { $0.verdict == .refused }.count,
            offeredParts: offered.count, legacyRoutes: legacy
        )
        return ProcedureInspection(task: task, goal: goal, attempts: attempts, relations: relations, offeredPartIDs: offered,
                                   counts: counts)
    }

    // MARK: Catalogue

    /// The parts the catalogue offers: admitted by their latest evaluation under a policy still active,
    /// usable by their latest state, of a version no later one supersedes, and containing no part whose
    /// latest state takes it out of use, so a retired step never comes back through its parent.
    /// Conditions may follow with `AND`.
    static let offered = """
        SELECT p.part_id FROM memory_procedure_parts p
        JOIN memory_part_qualifications q ON q.part_id = p.part_id
            AND q.sequence = (SELECT max(sequence) FROM memory_part_qualifications WHERE part_id = p.part_id)
        JOIN memory_qualification_policies c ON c.policy_version = q.policy_version AND c.status = 'active'
        WHERE q.verdict = 'admitted'
          AND NOT EXISTS (SELECT 1 FROM memory_routes r WHERE r.supersedes_route_id = p.route_id)
          AND NOT EXISTS (
              SELECT 1 FROM memory_procedure_parts d
              WHERE d.route_id = p.route_id AND d.first_position >= p.first_position AND d.last_position <= p.last_position
                AND (d.part_id = p.part_id
                     OR CASE d.part_kind WHEN 'procedure' THEN 0 WHEN 'subprocedure' THEN 1 ELSE 2 END
                        > CASE p.part_kind WHEN 'procedure' THEN 0 WHEN 'subprocedure' THEN 1 ELSE 2 END)
                AND ifnull((SELECT s.state FROM memory_part_states s WHERE s.part_id = d.part_id
                            ORDER BY s.sequence DESC LIMIT 1), 'usable') <> 'usable')
        """

    static func cataloguePart(_ handle: some SQLiteQuerying, partID: String,
                              versions: inout [String: StoredProcedureVersion?]) throws -> CataloguePart? {
        guard let routeID = try handle.query(
            "SELECT route_id FROM memory_procedure_parts WHERE part_id = ?", [.text(partID)],
            { try $0.text(0) }
        ).first ?? nil else { return nil }
        if versions[routeID] == nil { versions[routeID] = .some(try stored(handle, routeID: routeID)) }
        guard let stored = versions[routeID] ?? nil,
              let part = stored.version.parts.first(where: { $0.partID == partID }),
              let qualification = stored.qualifications[partID] else { return nil }
        let contract = stored.contract.filter { $0.partID == partID }
        let used = Set(contract.compactMap(\.parameterID))
        let details = Dictionary(uniqueKeysWithValues: stored.version.parameterDetails.map { ($0.parameterID, $0) })
        let parameters = stored.version.definition.parameters.compactMap { parameter -> CataloguePart.Parameter? in
            guard used.contains(parameter.parameterID), let detail = details[parameter.parameterID] else { return nil }
            return CataloguePart.Parameter(parameter: parameter, detail: detail)
        }
        return CataloguePart(part: part, procedureLabel: stored.version.definition.name, candidateID: stored.version.candidateID,
                             taskID: stored.version.taskID, attemptID: stored.version.attemptID, revision: stored.version.revision,
                             contract: contract, parameters: parameters, qualification: qualification,
                             state: stored.states[partID], lateEntryState: stored.lateEntryStates[partID])
    }
}
