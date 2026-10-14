//
//  SQLiteRecallInspectionRows.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import Foundation
import Memory

/// SQLiteRecallInspectionRows reads, for the diagnosis by id, what an attempt asked the Recall and what came back, as
/// stored: the proposals with their needs, sources and choice, and the queries with their needs, tracts, requirements,
/// linked calls and use reports. Read only, inside the caller's snapshot or transaction; nothing is selected, scored or
/// changed, and the codes are the archive's words.
enum SQLiteRecallInspectionRows {

    /// The proposals the attempt was given, in the order they were recorded.
    static func proposals(_ handle: some SQLiteQuerying, attemptID: String) throws -> [ProcedureInspection.Proposal] {
        let headers = try handle.query(
            """
            SELECT proposal_id, task_revision, reason, remaining_work, channel, search_status, search_note, candidates_considered,
                   proposal_bytes, duration_us, recorded_at_ms
            FROM memory_recall_proposals WHERE task_occurrence_id = ? ORDER BY recorded_at_ms, rowid
            """,
            [.text(attemptID)]
        ) { row in
            (id: try row.text(0) ?? "", revision: Int(row.integer(1) ?? 1), reason: try row.text(2) ?? "", remaining: try row.text(3) ?? "",
             channel: try row.text(4) ?? "", status: try row.text(5) ?? "", note: try row.text(6), considered: Int(row.integer(7) ?? 0),
             bytes: Int(row.integer(8) ?? 0), duration: row.integer(9), at: row.integer(10) ?? 0)
        }
        return try headers.map { header in
            let needs = try handle.query(
                "SELECT position, text, bundle_id FROM memory_recall_proposal_needs WHERE proposal_id = ? ORDER BY position",
                [.text(header.id)]
            ) { ProcedureInspection.ProposedNeed(position: Int($0.integer(0) ?? 0), text: try $0.text(1) ?? "", bundleID: try $0.text(2)) }
            let sources = try handle.query(
                """
                SELECT need_position, position, source_key, route_id, relevance, suggested_first, suggested_last
                FROM memory_recall_proposal_sources WHERE proposal_id = ? ORDER BY need_position, position
                """,
                [.text(header.id)]
            ) {
                ProcedureInspection.ProposedSource(needPosition: Int($0.integer(0) ?? 0), position: Int($0.integer(1) ?? 0),
                                                   key: try $0.text(2) ?? "", routeID: try $0.text(3) ?? "", relevance: $0.real(4) ?? 0,
                                                   suggestedFirst: $0.integer(5).map(Int.init), suggestedLast: $0.integer(6).map(Int.init))
            }
            var choice: ProcedureInspection.Choice?
            if let chosen = try handle.query(
                "SELECT query_id, recorded_at_ms FROM memory_recall_choices WHERE proposal_id = ?", [.text(header.id)]
            ) { (query: try $0.text(0) ?? "", at: $0.integer(1) ?? 0) }.first {
                let declared = try handle.query(
                    """
                    SELECT need_position, declared, uncovered, settled_by FROM memory_recall_choice_needs WHERE query_id = ?
                    ORDER BY need_position
                    """,
                    [.text(chosen.query)]
                ) {
                    ProcedureInspection.ChosenNeed(position: Int($0.integer(0) ?? 0), declared: try $0.text(1) ?? "", uncovered: try $0.text(2),
                                                   settledBy: try $0.text(3))
                }
                choice = ProcedureInspection.Choice(queryID: chosen.query, recordedAtMS: chosen.at, needs: declared)
            }
            return ProcedureInspection.Proposal(
                proposalID: header.id, revision: header.revision, reason: header.reason, remainingWork: header.remaining,
                channel: header.channel, searchStatus: header.status, searchNote: header.note, candidatesConsidered: header.considered,
                bytes: header.bytes, durationUS: header.duration, recordedAtMS: header.at, needs: needs, sources: sources, choice: choice
            )
        }
    }

    /// The queries made for the attempt, in the order they were recorded, with the proposal each answered when it did.
    static func queries(_ handle: some SQLiteQuerying, attemptID: String) throws -> [ProcedureInspection.Query] {
        let headers = try handle.query(
            """
            SELECT q.query_id, q.task_revision, q.reason, q.remaining_work, q.channel, q.search_status, q.search_note, q.candidate_limit,
                   q.candidates_considered, q.coverage, q.delivery, q.delivery_bytes, q.selector_version, q.recorded_at_ms, q.duration_us,
                   (SELECT c.proposal_id FROM memory_recall_choices c WHERE c.query_id = q.query_id)
            FROM memory_recall_queries q WHERE q.task_occurrence_id = ? ORDER BY q.recorded_at_ms, q.rowid
            """,
            [.text(attemptID)]
        ) { row in
            (id: try row.text(0) ?? "", revision: Int(row.integer(1) ?? 1), reason: try row.text(2) ?? "", remaining: try row.text(3) ?? "",
             channel: try row.text(4) ?? "", status: try row.text(5) ?? "", note: try row.text(6), limit: Int(row.integer(7) ?? 0),
             considered: Int(row.integer(8) ?? 0), coverage: try row.text(9) ?? "", delivery: try row.text(10) ?? "",
             bytes: row.integer(11).map(Int.init), selector: try row.text(12) ?? "", at: row.integer(13) ?? 0, duration: row.integer(14),
             proposal: try row.text(15))
        }
        return try headers.map { header in
            let needs = try handle.query(
                "SELECT position, text, bundle_id, coverage, reason FROM memory_recall_needs WHERE query_id = ? ORDER BY position",
                [.text(header.id)]
            ) {
                (position: Int($0.integer(0) ?? 0), text: try $0.text(1) ?? "", bundle: try $0.text(2), coverage: try $0.text(3) ?? "",
                 reason: try $0.text(4))
            }
            let queried = try needs.map { need in
                let selections = try handle.query(
                    """
                    SELECT position, role, route_id, first_position, last_position, whole_part_id, relevance, preparations
                    FROM memory_recall_selections WHERE query_id = ? AND need_position = ? ORDER BY position
                    """,
                    [.text(header.id), .integer(Int64(need.position))]
                ) {
                    (position: Int($0.integer(0) ?? 0), role: try $0.text(1) ?? "", route: try $0.text(2) ?? "", first: Int($0.integer(3) ?? 0),
                     last: Int($0.integer(4) ?? 0), whole: try $0.text(5), relevance: $0.real(6) ?? 0, preparations: Int($0.integer(7) ?? 0))
                }
                let tracts = try selections.map { selection in
                    let requirements = try handle.query(
                        """
                        SELECT kind, count(*) FROM memory_recall_requirements
                        WHERE query_id = ? AND need_position = ? AND selection_position = ? GROUP BY kind
                        """,
                        [.text(header.id), .integer(Int64(need.position)), .integer(Int64(selection.position))]
                    ) { (try $0.text(0) ?? "", Int($0.integer(1) ?? 0)) }
                    return ProcedureInspection.Selection(
                        position: selection.position, role: selection.role, routeID: selection.route, firstPosition: selection.first,
                        lastPosition: selection.last, wholePartID: selection.whole, relevance: selection.relevance,
                        preparations: selection.preparations, requirements: Dictionary(requirements, uniquingKeysWith: { first, _ in first })
                    )
                }
                // A choice's calls are linked to the tract they carried out; the selector's to the need alone.
                let links = try handle.query(
                    """
                    SELECT call_event_id, NULL, step_position, confirmed, undetermined, linked_at_ms FROM memory_recall_links
                    WHERE query_id = ? AND need_position = ?
                    UNION ALL
                    SELECT call_event_id, selection_position, step_position, confirmed, undetermined, linked_at_ms
                    FROM memory_recall_choice_links WHERE query_id = ? AND need_position = ?
                    ORDER BY 6, 1
                    """,
                    [.text(header.id), .integer(Int64(need.position)), .text(header.id), .integer(Int64(need.position))]
                ) {
                    ProcedureInspection.Link(callEventID: try $0.text(0) ?? "", selectionPosition: $0.integer(1).map(Int.init),
                                             stepPosition: $0.integer(2).map(Int.init), confirmed: ($0.integer(3) ?? 0) == 1,
                                             undetermined: ($0.integer(4) ?? 0) == 1)
                }
                let reports = try handle.query(
                    """
                    SELECT sequence, declared, cause, note FROM memory_recall_reports WHERE query_id = ? AND need_position = ?
                    ORDER BY sequence
                    """,
                    [.text(header.id), .integer(Int64(need.position))]
                ) {
                    ProcedureInspection.Use(sequence: Int($0.integer(0) ?? 0), declared: try $0.text(1) ?? "", cause: try $0.text(2),
                                            note: try $0.text(3))
                }
                return ProcedureInspection.QueriedNeed(position: need.position, text: need.text, bundleID: need.bundle,
                                                       coverage: need.coverage, reason: need.reason, selections: tracts, links: links,
                                                       reports: reports)
            }
            return ProcedureInspection.Query(
                queryID: header.id, revision: header.revision, reason: header.reason, remainingWork: header.remaining,
                channel: header.channel, searchStatus: header.status, searchNote: header.note, candidateLimit: header.limit,
                candidatesConsidered: header.considered, coverage: header.coverage, delivery: header.delivery,
                deliveryBytes: header.bytes, selectorVersion: header.selector, recordedAtMS: header.at, durationUS: header.duration,
                proposalID: header.proposal, needs: queried
            )
        }
    }
}
