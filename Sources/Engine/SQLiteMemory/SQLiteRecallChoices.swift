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

        public init(proposal: RecallChoice.Proposal, generationID: Int64?, channel: RecallChannel, searchStatus: SearchStatus,
                    searchNote: String?, candidatesConsidered: Int, bytes: Int, durationUS: Int64?) {
            self.proposal             = proposal
            self.generationID         = generationID
            self.channel              = channel
            self.searchStatus         = searchStatus
            self.searchNote           = searchNote
            self.candidatesConsidered = candidatesConsidered
            self.bytes                = bytes
            self.durationUS           = durationUS
        }
    }

    /// Records a proposal with its needs and the versions it shortlisted, in one transaction.
    public func recordProposal(_ recorded: RecordedProposal) async throws {
        try await store.write { transaction in
            let proposal = recorded.proposal
            try transaction.execute(
                """
                INSERT INTO memory_recall_proposals (proposal_id, task_id, task_occurrence_id, task_revision, source, source_stream_id,
                    reason, remaining_work, generation_id, channel, search_status, search_note, candidates_considered, proposal_bytes,
                    format_version, recorded_at_ms, duration_us)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(proposal.proposalID), .text(proposal.taskID), .text(proposal.attemptID), .integer(Int64(proposal.revision)),
                 .text(proposal.producer.source.rawValue), .text(proposal.producer.streamID), .text(proposal.reason.rawValue),
                 .text(proposal.remainingWork), recorded.generationID.map(SQLiteValue.integer) ?? .null, .text(recorded.channel.rawValue),
                 .text(recorded.searchStatus.rawValue), recorded.searchNote.map(SQLiteValue.text) ?? .null,
                 .integer(Int64(recorded.candidatesConsidered)), .integer(Int64(recorded.bytes)), .text(RecallChoice.formatVersion),
                 .integer(proposal.recordedAtMS), recorded.durationUS.map(SQLiteValue.integer) ?? .null]
            )
            for (position, need) in proposal.needs.enumerated() {
                try transaction.execute(
                    "INSERT INTO memory_recall_proposal_needs (proposal_id, position, text, bundle_id) VALUES (?, ?, ?, ?)",
                    [.text(proposal.proposalID), .integer(Int64(position)), .text(need.text), need.bundleID.map(SQLiteValue.text) ?? .null]
                )
            }
            var positions: [Int: Int] = [:]
            for item in proposal.shortlisted {
                let position = positions[item.needPosition, default: 0]
                positions[item.needPosition] = position + 1
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_proposal_sources (proposal_id, need_position, position, source_key, route_id, relevance,
                        suggested_first, suggested_last)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(proposal.proposalID), .integer(Int64(item.needPosition)), .integer(Int64(position)), .text(item.key),
                     .text(item.routeID), .real(item.relevance.isFinite ? item.relevance : 0),
                     item.suggested.map { .integer(Int64($0.lowerBound)) } ?? .null,
                     item.suggested.map { .integer(Int64($0.upperBound)) } ?? .null]
                )
            }
        }
    }

    /// The proposal with this id, as recorded with its search; nil when there is none.
    public func proposal(_ proposalID: String) async throws -> RecordedProposal? {
        try await store.read { snapshot in
            let header = try snapshot.query(
                """
                SELECT task_id, task_occurrence_id, task_revision, source, source_stream_id, reason, remaining_work, recorded_at_ms,
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
                SELECT need_position, source_key, route_id, relevance, suggested_first, suggested_last
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
                    [.text(route)]
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
            "SELECT DISTINCT route_id, source_key FROM memory_recall_proposal_sources WHERE proposal_id = ?", [.text(proposalID)]
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
            SELECT need_position, role, route_id, first_position, last_position FROM memory_recall_selections
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
            try SQLiteRecallRows.record(transaction, query, at: nowMS)
            try transaction.execute("INSERT INTO memory_recall_choices (query_id, proposal_id, recorded_at_ms) VALUES (?, ?, ?)",
                                    [.text(query.queryID), .text(proposalID), .integer(nowMS)])
            for chosen in declarations {
                try transaction.execute(
                    "INSERT INTO memory_recall_choice_needs (query_id, need_position, declared, uncovered, settled_by) VALUES (?, ?, ?, ?, ?)",
                    [.text(query.queryID), .integer(Int64(chosen.outcome.position)), .text(chosen.declared.rawValue),
                     chosen.uncovered.map(SQLiteValue.text) ?? .null, chosen.settledBy.map(SQLiteValue.text) ?? .null]
                )
            }
            return nil
        }
    }
}
