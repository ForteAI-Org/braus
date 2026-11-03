//
//  SQLiteRecallChoices.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
import Memory

/// The rows of the experiment of the Recall by the agent's choice (schema 7, Documentation/Engine/RecallAgentChoice.md):
/// proposals and what they shortlisted, the choice that answers one, and the agent's declaration per need. The choice's
/// tracts are the delivered query's own rows (`record`), written in the same transaction as the choice.
extension SQLiteRecallRepository {

    /// CalibrationRow preserves missing channel signals as nil, never zero.
    public struct CalibrationRow: Sendable, Equatable {
        public let needPosition: Int
        public let partID: String
        public let rank: Int
        public let cosine: Double?
        public let lexical: Double?
        public let score: Double
        public let threshold: Double
        public let delivered: Bool

        public init(needPosition: Int, partID: String, rank: Int, cosine: Double?, lexical: Double?,
                    score: Double, threshold: Double, delivered: Bool) {
            self.needPosition = needPosition
            self.partID = partID
            self.rank = rank
            self.cosine = cosine
            self.lexical = lexical
            self.score = score
            self.threshold = threshold
            self.delivered = delivered
        }
    }

    /// RecordedProposal is a proposal with how its search went, as it is recorded.
    public struct RecordedProposal: Sendable {
        public let proposal: RecallChoice.Proposal
        public let generationID: Int64?
        public let channel: RecallChannel
        public let searchStatus: SearchStatus
        public let searchNote: String?
        public let candidatesConsidered: Int
        public let bytes: Int
        public let durationUS: Int64?
        public let calibration: [CalibrationRow]

        public init(proposal: RecallChoice.Proposal, generationID: Int64?, channel: RecallChannel, searchStatus: SearchStatus,
                    searchNote: String?, candidatesConsidered: Int, bytes: Int, durationUS: Int64?, calibration: [CalibrationRow] = []) {
            self.proposal             = proposal
            self.generationID         = generationID
            self.channel              = channel
            self.searchStatus         = searchStatus
            self.searchNote           = searchNote
            self.candidatesConsidered = candidatesConsidered
            self.bytes                = bytes
            self.durationUS           = durationUS
            self.calibration          = calibration
        }
    }

    /// Records a proposal with its needs and the versions it shortlisted, in one transaction.
    @discardableResult
    public func recordProposal(_ recorded: RecordedProposal) async throws -> String {
        let (saved, _) = try await recordPreparedProposal(proposedID: recorded.proposal.proposalID) { id in
            (recorded.withIdentity(id, bytes: recorded.bytes), id)
        }
        return saved.proposal.proposalID
    }

    static func recordProposal(_ recorded: RecordedProposal, in transaction: SQLiteTransaction) throws -> String {
        let id = try assignedID(transaction, table: "memory_recall_proposals", column: "proposal_id",
                                proposed: recorded.proposal.proposalID)
        try insertProposal(transaction, recorded.withIdentity(id, bytes: recorded.bytes), assignedIdentity: true)
        return id
    }

    static func insertProposal(_ transaction: SQLiteTransaction, _ recorded: RecordedProposal,
                               assignedIdentity: Bool = false) throws {
        if try SQLiteRowIdentity(transaction).usesIntegerKeys {
            if !recorded.calibration.isEmpty {
                try recordProposalSearch(recorded, in: transaction)
            }
            try recordProposal22(transaction, recorded, assignedIdentity: assignedIdentity)
            try recordCalibration(recorded.calibration, queryID: recorded.proposal.proposalID, in: transaction)
        } else {
            _ = try recordHistoricalProposal(recorded, in: transaction)
        }
    }

    static func recordHistoricalProposal(_ recorded: RecordedProposal, in transaction: SQLiteTransaction) throws -> String {
        let proposal = recorded.proposal
        let available = try transaction.query(
            "SELECT count(*) FROM sqlite_schema WHERE name = 'memory_recall_calibration'", []
        ) { $0.integer(0) ?? 0 }.first == 1
        let requestedID: String?
        if available, !recorded.calibration.isEmpty {
            try recordProposalSearch(recorded, in: transaction)
            requestedID = proposal.proposalID
        } else {
            requestedID = available ? nil : proposal.proposalID
        }
        let storedIDs = try transaction.query(
            """
            INSERT INTO memory_recall_proposals (proposal_id, task_id, task_occurrence_id, task_revision, source, source_stream_id,
                reason, remaining_work, generation_id, channel, search_status, search_note, candidates_considered, proposal_bytes,
                format_version, recorded_at_ms, duration_us)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING proposal_id
            """,
            [requestedID.map(SQLiteValue.text) ?? .null, .text(proposal.taskID), .text(proposal.attemptID), .integer(Int64(proposal.revision)),
             .text(proposal.producer.source.rawValue), .text(proposal.producer.streamID), .text(proposal.reason.rawValue),
             .text(proposal.remainingWork), recorded.generationID.map(SQLiteValue.integer) ?? .null, .text(recorded.channel.rawValue),
             .text(recorded.searchStatus.rawValue), recorded.searchNote.map(SQLiteValue.text) ?? .null,
             .integer(Int64(recorded.candidatesConsidered)), .integer(Int64(recorded.bytes)), .text(RecallChoice.formatVersion),
             .integer(proposal.recordedAtMS), recorded.durationUS.map(SQLiteValue.integer) ?? .null]
        ) { try $0.text(0) ?? "" }
        guard let proposalID = storedIDs.first else { throw CocoaError(.coderInvalidValue) }
        for (position, need) in proposal.needs.enumerated() {
            try transaction.execute(
                "INSERT INTO memory_recall_proposal_needs (proposal_id, position, text, bundle_id) VALUES (?, ?, ?, ?)",
                [.text(proposalID), .integer(Int64(position)), .text(need.text), need.bundleID.map(SQLiteValue.text) ?? .null]
            )
        }
        var positions: [Int: Int] = [:]
        for item in proposal.shortlisted {
            let position = positions[item.needPosition, default: 0]
            positions[item.needPosition] = position + 1
            let needColumn = available ? ", proposal_need_id" : ""
            let needValue = available ? ", (SELECT proposal_need_id FROM memory_recall_proposal_needs WHERE proposal_id = ? AND position = ?)" : ""
            let needBindings: [SQLiteValue] = available ? [.text(proposalID), .integer(Int64(item.needPosition))] : []
            try transaction.execute(
                """
                INSERT INTO memory_recall_proposal_sources (proposal_id, need_position, position, source_key, route_id, relevance,
                    suggested_first, suggested_last\(needColumn))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?\(needValue))
                """,
                [.text(proposalID), .integer(Int64(item.needPosition)), .integer(Int64(position)), .text(item.key),
                 .text(item.routeID), .real(item.relevance.isFinite ? item.relevance : 0),
                 item.suggested.map { .integer(Int64($0.lowerBound)) } ?? .null,
                 item.suggested.map { .integer(Int64($0.upperBound)) } ?? .null] + needBindings
            )
        }
        if available, !recorded.calibration.isEmpty {
            try recordCalibration(recorded.calibration, queryID: proposalID, in: transaction)
        }
        return proposalID
    }

    /// Records the search that offered these parts, without a choice or selected steps.
    /// The query and proposal share an archive-assigned identity for calibration; a later choice has its own query.
    static func recordProposalSearch(_ recorded: RecordedProposal, in transaction: SQLiteTransaction) throws {
        let proposal = recorded.proposal
        let unknown = recorded.searchStatus == .failed || recorded.searchStatus == .unavailable
        let coverage = unknown ? "unknown" : "ambiguous"
        let rows = try transaction.query("""
            INSERT INTO memory_recall_queries
                (query_id, task_id, task_occurrence_id, task_revision, source, source_stream_id, reason,
                 remaining_work, generation_id, channel, search_status, search_note, candidate_limit,
                 candidates_considered, coverage, delivery, delivery_bytes, selector_version, recorded_at_ms, duration_us)
            VALUES (?,
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING query_id
            """, [.text(proposal.proposalID), try DB2CIdentity.key(transaction, "memory_tasks", proposal.taskID),
                try DB2CIdentity.key(transaction, "memory_task_occurrences", proposal.attemptID), .integer(Int64(proposal.revision)),
                .text(proposal.producer.source.rawValue), .text(proposal.producer.streamID), .text(proposal.reason.rawValue),
                .text(RecallQueryMasking.masked(proposal.remainingWork, values: [])), recorded.generationID.map(SQLiteValue.integer) ?? .null,
                .text(recorded.channel.rawValue), .text(recorded.searchStatus.rawValue),
                recorded.searchNote.map(SQLiteValue.text) ?? .null, .integer(Int64(RecallContract.candidateLimit)),
                .integer(Int64(recorded.candidatesConsidered)), .text(coverage), .text(unknown ? "nothing" : "delivered"),
                .integer(Int64(recorded.bytes)), .text(RecallChoice.formatVersion), .integer(proposal.recordedAtMS),
                recorded.durationUS.map(SQLiteValue.integer) ?? .null]) { try $0.text(0) ?? "" }
        guard let queryID = rows.first else { throw CocoaError(.coderInvalidValue) }
        for (position, need) in proposal.needs.enumerated() {
            try transaction.execute("""
                INSERT INTO memory_recall_needs (query_id, position, text, bundle_id, coverage, reason)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(queryID), .integer(Int64(position)), .text(need.text),
                    need.bundleID.map(SQLiteValue.text) ?? .null, .text(coverage), unknown ? .null : .text("alternatives")])
        }
    }

    static func recordCalibration(_ rows: [CalibrationRow], queryID: String, in transaction: SQLiteTransaction) throws {
        for row in rows {
            try transaction.execute("""
                INSERT INTO memory_recall_calibration
                    (query_id, need_position, part_id, rank, cosine, lexical, score, threshold, delivered, used)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """, [.text(queryID), .integer(Int64(row.needPosition)), try DB2CIdentity.key(transaction, "memory_procedure_parts", row.partID), .integer(Int64(row.rank)),
                    row.cosine.map(SQLiteValue.real) ?? .null, row.lexical.map(SQLiteValue.real) ?? .null,
                    .real(row.score), .real(row.threshold), .integer(row.delivered ? 1 : 0)])
        }
    }

    /// Finalizes each calibration once; an adapted declaration counts as reuse.
    public func markUsed(queryID: String, used: [String: Bool]) async throws {
        try await store.write { try Self.markUsed(queryID: queryID, used: used, in: $0) }
    }

    static func markUsed(queryID: String, used: [String: Bool], in transaction: SQLiteTransaction) throws {
        for (partID, wasUsed) in used {
            try transaction.execute("""
                UPDATE memory_recall_calibration SET used = ? WHERE query_id = ? AND part_id = ? AND used IS NULL
                """, [.integer(wasUsed ? 1 : 0), .text(queryID), try DB2CIdentity.key(transaction, "memory_procedure_parts", partID)])
        }
    }

    /// Finishes delivered offers, including proposals that the model never chose.
    public func finishCalibration(attemptID: String) async throws {
        let queries = try await store.read { try Self.calibrationUses(attemptID: attemptID, in: $0) }
        for (query, parts) in queries { try await markUsed(queryID: query, used: parts) }
    }

    static func calibrationUses(attemptID: String, in handle: some SQLiteQuerying) throws -> [(String, [String: Bool])] {
        let available = try handle.query(
            "SELECT count(*) FROM sqlite_schema WHERE name = 'memory_recall_calibration'", []
        ) { $0.integer(0) ?? 0 }.first == 1
        guard available else { return [] }
        let rows = try handle.query("""
            SELECT c.query_id, \(try DB2CIdentity.publicReference(handle, "memory_procedure_parts", "c.part_id")), EXISTS (
                SELECT 1 FROM memory_recall_choices ch
                JOIN memory_recall_selections s ON s.query_id = ch.query_id AND s.role = 'selected'
                JOIN memory_procedure_parts part ON part.part_id = c.part_id AND part.route_id = s.route_id
                    AND part.first_position >= s.first_position AND part.last_position <= s.last_position
                WHERE ch.proposal_id = p.proposal_id AND (
                    EXISTS (SELECT 1 FROM memory_recall_reports r WHERE r.query_id = ch.query_id
                        AND r.need_position = s.need_position AND r.declared IN ('followed', 'adapted'))
                    OR EXISTS (SELECT 1 FROM memory_recall_links l WHERE l.query_id = ch.query_id
                        AND l.need_position = s.need_position AND l.step_position BETWEEN part.first_position AND part.last_position)))
            FROM memory_recall_calibration c JOIN memory_recall_proposals p ON p.proposal_id = c.query_id
            WHERE p.task_occurrence_id = ? AND c.delivered = 1 AND c.used IS NULL
            """, [try DB2CIdentity.key(handle, "memory_task_occurrences", attemptID)]) { (try $0.text(0) ?? "", try $0.text(1) ?? "", $0.integer(2) == 1) }
        var queries: [String: [String: Bool]] = [:]
        for (query, part, used) in rows { queries[query, default: [:]][part] = used }
        return queries.map { ($0.key, $0.value) }
    }

    /// The proposal with this id, as recorded with its search; nil when there is none.
    public func proposal(_ proposalID: String) async throws -> RecordedProposal? {
        try await store.read { snapshot in
            let header = try snapshot.query(
                """
                SELECT \(try DB2CIdentity.publicReference(snapshot, "memory_tasks", "memory_recall_proposals.task_id")), \(try DB2CIdentity.publicReference(snapshot, "memory_task_occurrences", "memory_recall_proposals.task_occurrence_id")), task_revision, source, source_stream_id, reason, remaining_work, recorded_at_ms,
                       generation_id, channel, search_status, search_note, candidates_considered, proposal_bytes, duration_us
                FROM memory_recall_proposals WHERE proposal_id = ?
                """,
                [.text(proposalID)]
            ) { row in
                (task: try row.text(0) ?? "", attempt: try row.text(1) ?? "", revision: Int(row.integer(2) ?? 1), source: try row.text(3) ?? "",
                 stream: try row.text(4) ?? "", reason: try row.text(5) ?? "", remaining: try row.text(6) ?? "", at: row.integer(7) ?? 0,
                 generation: row.integer(8), channel: try row.text(9) ?? "", status: try row.text(10) ?? "", note: try row.text(11),
                 considered: Int(row.integer(12) ?? 0), bytes: Int(row.integer(13) ?? 0), duration: row.integer(14))
            }.first
            guard let header, let source = MemoryEventSource(rawValue: header.source), let reason = RecallReason(rawValue: header.reason),
                  let channel = RecallChannel(rawValue: header.channel), let status = SearchStatus(rawValue: header.status) else {
                return nil
            }
            let needs = try snapshot.query(
                "SELECT text, bundle_id FROM memory_recall_proposal_needs WHERE proposal_id = ? ORDER BY position", [.text(proposalID)]
            ) { row in try RecallNeed(text: try row.text(0) ?? "", bundleID: try row.text(1)) }
            let shortlisted = try snapshot.query(
                """
                SELECT need_position, source_key, \(try DB2CIdentity.publicReference(snapshot, "memory_routes", "memory_recall_proposal_sources.route_id")), relevance, suggested_first, suggested_last
                FROM memory_recall_proposal_sources WHERE proposal_id = ? ORDER BY need_position, position
                """,
                [.text(proposalID)]
            ) { row -> RecallChoice.Shortlisted in
                let first = row.integer(4).map(Int.init), last = row.integer(5).map(Int.init)
                return RecallChoice.Shortlisted(needPosition: Int(row.integer(0) ?? 0), key: try row.text(1) ?? "", routeID: try row.text(2) ?? "",
                                                relevance: row.real(3) ?? 0,
                                                suggested: first.flatMap { first in last.map { first...$0 } })
            }
            let proposal = RecallChoice.Proposal(proposalID: proposalID, taskID: header.task, attemptID: header.attempt,
                                                 revision: header.revision, producer: try TaskProducer(source: source, streamID: header.stream),
                                                 reason: reason, remainingWork: header.remaining, needs: needs, shortlisted: shortlisted,
                                                 recordedAtMS: header.at)
            return RecordedProposal(proposal: proposal, generationID: header.generation, channel: channel, searchStatus: status,
                                    searchNote: header.note, candidatesConsidered: header.considered, bytes: header.bytes,
                                    durationUS: header.duration)
        }
    }

    /// Of the versions named, those a later version supersedes.
    public func superseded(_ routeIDs: [String]) async throws -> Set<String> {
        guard !routeIDs.isEmpty else { return [] }
        return try await store.read { snapshot in
            Set(try routeIDs.filter { route in
                try snapshot.query(
                    """
                    SELECT count(*) FROM memory_routes r JOIN memory_procedure_versions v ON v.route_id = r.route_id
                    WHERE r.supersedes_route_id = ?
                    """,
                    [try DB2CIdentity.key(snapshot, "memory_routes", route)]
                ) { $0.integer(0) ?? 0 }.first ?? 0 > 0
            })
        }
    }

    /// A recorded query's facts as lines of text: its needs with their coverage, its selections with their versions and
    /// intervals, and their requirements with the task values they took by name. Two queries with equal lines delivered
    /// the same; `facts(of:)` reads a query about to be recorded the same way.
    public func facts(ofQuery queryID: String) async throws -> [String] {
        try await store.read { snapshot in try SQLiteRecallRows.facts(snapshot, queryID: queryID) }
    }

    /// The lines `facts(ofQuery:)` reads, for a query not yet recorded.
    public static func facts(of query: RecordedQuery) -> [String] { SQLiteRecallRows.facts(of: query) }

    /// The choice recorded for a proposal: its query and the plan it recorded, read back from its rows.
    public func choice(ofProposal proposalID: String) async throws -> (queryID: String, plan: RecallChoice.Plan)? {
        try await store.read { snapshot in try Self.choice(snapshot, proposalID: proposalID) }
    }

    static func choice(_ handle: some SQLiteQuerying, proposalID: String) throws -> (queryID: String, plan: RecallChoice.Plan)? {
        guard let query = try handle.query("SELECT query_id FROM memory_recall_choices WHERE proposal_id = ?", [.text(proposalID)], {
            try $0.text(0) ?? ""
        }).first else { return nil }
        let keys = Dictionary(try handle.query(
            "SELECT DISTINCT \(try DB2CIdentity.publicReference(handle, "memory_routes", "memory_recall_proposal_sources.route_id")), source_key FROM memory_recall_proposal_sources WHERE proposal_id = ?", [.text(proposalID)]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }, uniquingKeysWith: { first, _ in first })
        let declarations = try handle.query(
            """
            SELECT need_position, declared, uncovered, settled_by FROM memory_recall_choice_needs WHERE query_id = ?
            ORDER BY need_position
            """,
            [.text(query)]
        ) { (position: Int($0.integer(0) ?? 0), declared: try $0.text(1) ?? "", uncovered: try $0.text(2), settledBy: try $0.text(3)) }
        let selections = try handle.query(
            """
            SELECT need_position, role, \(try DB2CIdentity.publicReference(handle, "memory_routes", "memory_recall_selections.route_id")), first_position, last_position FROM memory_recall_selections
            WHERE query_id = ? AND role IN ('selected', 'alternative') ORDER BY need_position, position
            """,
            [.text(query)]
        ) { (need: Int($0.integer(0) ?? 0), role: try $0.text(1) ?? "", route: try $0.text(2) ?? "", first: Int($0.integer(3) ?? 0),
             last: Int($0.integer(4) ?? 0)) }
        func tracts(_ position: Int, _ role: String) -> [RecallChoice.Tract] {
            selections.filter { $0.need == position && $0.role == role }.map { RecallChoice.Tract(key: keys[$0.route] ?? $0.route, first: $0.first, last: $0.last) }
        }
        let needs = declarations.map { row in
            RecallChoice.PlannedNeed(position: row.position, tracts: tracts(row.position, "selected"),
                                     declared: RecallChoice.Declared(rawValue: row.declared) ?? .none, uncovered: row.uncovered,
                                     alternatives: tracts(row.position, "alternative"), settledBy: row.settledBy)
        }
        return (query, RecallChoice.Plan(proposalID: proposalID, needs: needs))
    }

    /// Records the query that delivers an admitted choice, the choice and the agent's declarations, in one transaction.
    /// When the proposal was already chosen, nothing is written and the earlier choice is answered: the caller compares
    /// the plans, so a retried call returns the same answer and another plan is refused.
    public func recordChoice(_ query: RecordedQuery, proposalID: String, declarations: [RecallChoice.Chosen],
                             at nowMS: Int64) async throws -> (queryID: String, plan: RecallChoice.Plan)? {
        try await store.write { transaction in
            if let earlier = try Self.choice(transaction, proposalID: proposalID) { return earlier }
            let assigned = try Self.assignedID(transaction, table: "memory_recall_queries", column: "query_id", proposed: query.queryID)
            let saved = query.withIdentity(assigned, deliveryBytes: query.deliveryBytes)
            try SQLiteRecallRows.record(transaction, saved, at: nowMS, assignedIdentity: true)
            try Self.insertChoice(transaction, queryID: assigned, proposalID: proposalID, declarations: declarations, at: nowMS)
            return nil
        }
    }
}
