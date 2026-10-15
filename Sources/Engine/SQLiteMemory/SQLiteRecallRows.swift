//
//  SQLiteRecallRows.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation
import Memory

/// SQLiteRecallRows is the codec of the Recall's rows, inside the caller's transaction or snapshot.
enum SQLiteRecallRows {

    static func malformed(_ table: String, _ id: String, _ problem: String) -> ProcedureError {
        .malformedRow(table: table, id: id, problem: problem)
    }

    // MARK: Generations

    static func generations(_ handle: some SQLiteQuerying, where condition: String) throws -> [SQLiteRecallRepository.Generation] {
        try handle.query(
            """
            SELECT generation_id, document_format, space_id, status, cursor_route_id, enumerated, revision, started_at_ms, ready_at_ms, reason
            FROM memory_recall_generations WHERE \(condition) ORDER BY CASE status WHEN 'ready' THEN 0 ELSE 1 END, generation_id
            """,
            []
        ) { row in
            let id = row.integer(0) ?? 0
            guard let format = RecallDocument.Format(rawValue: try row.text(1) ?? ""),
                  let status = SQLiteRecallRepository.Generation.Status(rawValue: try row.text(3) ?? "") else {
                throw malformed("memory_recall_generations", "\(id)", "format or status")
            }
            return SQLiteRecallRepository.Generation(generationID: id, format: format, spaceID: try row.text(2), status: status,
                                                     cursorRouteID: try row.text(4), isEnumerated: row.integer(5) == 1,
                                                     revision: row.integer(6) ?? 0, startedAtMS: row.integer(7) ?? 0,
                                                     readyAtMS: row.integer(8), reason: try row.text(9))
        }
    }

    /// How many documents of a generation lack a vector in its space; zero for a lexical generation.
    static func vectorBacklog(_ handle: some SQLiteQuerying, _ generation: SQLiteRecallRepository.Generation) throws -> Int {
        guard let space = generation.spaceID else { return 0 }
        return Int(try handle.query(
            """
            SELECT count(DISTINCT e.document_digest) FROM memory_recall_entries e WHERE e.generation_id = ?
              AND NOT EXISTS (SELECT 1 FROM memory_recall_vectors v WHERE v.space_id = ? AND v.document_digest = e.document_digest)
            """,
            [.integer(generation.generationID), .text(space)]
        ) { $0.integer(0) ?? 0 }.first ?? 0)
    }

    static func floats(_ bytes: [UInt8]) -> [Float] {
        var values = [Float](repeating: 0, count: bytes.count / 4)
        for index in values.indices {
            let bits = UInt32(bytes[index * 4]) | UInt32(bytes[index * 4 + 1]) << 8 | UInt32(bytes[index * 4 + 2]) << 16
                | UInt32(bytes[index * 4 + 3]) << 24
            values[index] = Float(bitPattern: bits)
        }
        return values
    }

    // MARK: The catalogue

    /// The parts among `partIDs` the catalogue offers now, by its own predicate.
    static func offered(_ handle: some SQLiteQuerying, _ partIDs: [String]) throws -> Set<String> {
        var offered: Set<String> = []
        for chunk in stride(from: 0, to: partIDs.count, by: 400).map({ Array(partIDs[$0..<min($0 + 400, partIDs.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            offered.formUnion(try handle.query(SQLiteProcedureRows.offered + " AND p.part_id IN (\(marks))", chunk.map(SQLiteValue.text)) {
                try $0.text(0) ?? ""
            })
        }
        return offered
    }

    /// The parts of a version the catalogue offers now.
    static func offered(_ handle: some SQLiteQuerying, routeID: String) throws -> Set<String> {
        Set(try handle.query(SQLiteProcedureRows.offered + " AND p.route_id = ?", [.text(routeID)]) { try $0.text(0) ?? "" })
    }

    // MARK: Entries

    /// Brings one version's entries in each generation in line with the catalogue now (see `sync(routeID:)`).
    static func sync(_ transaction: SQLiteTransaction, routeID: String, generations: [SQLiteRecallRepository.Generation],
                     at nowMS: Int64) throws -> SQLiteRecallRepository.SyncReport {
        var report = SQLiteRecallRepository.SyncReport()
        let offered = try offered(transaction, routeID: routeID)
        let stored = offered.isEmpty ? nil : try SQLiteProcedureRows.stored(transaction, routeID: routeID)
        for generation in generations where generation.status == .building || generation.status == .ready {
            let documents = stored.map { RecallDocument.documents(of: $0, offered: offered, format: generation.format) } ?? []
            let wanted = Dictionary(uniqueKeysWithValues: documents.map { ($0.partID, $0) })
            let existing = try transaction.query(
                """
                SELECT part_id, document_digest, qualification_sequence, state_sequence FROM memory_recall_entries
                WHERE generation_id = ? AND route_id = ?
                """,
                [.integer(generation.generationID), .text(routeID)]
            ) { (part: try $0.text(0) ?? "", digest: try $0.text(1) ?? "", qualification: $0.integer(2) ?? 0, state: $0.integer(3) ?? 0) }
            var kept: Set<String> = []
            for entry in existing {
                guard let document = wanted[entry.part] else {
                    try remove(transaction, generation: generation.generationID, part: entry.part)
                    report.removed += 1
                    continue
                }
                let digest = SQLiteRecallRepository.digest(format: generation.format, text: document.text)
                let (qualification, state) = try sequences(transaction, part: entry.part)
                if digest == entry.digest, qualification == entry.qualification, state == entry.state {
                    kept.insert(entry.part)
                    report.kept += 1
                } else {
                    try remove(transaction, generation: generation.generationID, part: entry.part)
                }
            }
            for document in documents where !kept.contains(document.partID) {
                let digest = SQLiteRecallRepository.digest(format: generation.format, text: document.text)
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_documents (document_digest, document_format, text, recorded_at_ms) VALUES (?, ?, ?, ?)
                    ON CONFLICT (document_digest) DO NOTHING
                    """,
                    [.text(digest), .text(generation.format.rawValue), .text(document.text), .integer(nowMS)]
                )
                let (qualification, state) = try sequences(transaction, part: document.partID)
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_entries (generation_id, part_id, route_id, part_kind, document_digest, qualification_sequence,
                        state_sequence, entered_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(generation.generationID), .text(document.partID), .text(routeID), .text(document.kind.rawValue), .text(digest),
                     .integer(qualification), .integer(state), .integer(nowMS)]
                )
                report.entered += 1
            }
        }
        return report
    }

    private static func remove(_ transaction: SQLiteTransaction, generation: Int64, part: String) throws {
        try transaction.execute("DELETE FROM memory_recall_entries WHERE generation_id = ? AND part_id = ?", [.integer(generation), .text(part)])
    }

    /// The sequence of a part's latest evaluation and latest state (0 when it has none).
    private static func sequences(_ handle: some SQLiteQuerying, part: String) throws -> (Int64, Int64) {
        let qualification = try handle.query("SELECT ifnull(max(sequence), 0) FROM memory_part_qualifications WHERE part_id = ?",
                                             [.text(part)]) { $0.integer(0) ?? 0 }.first ?? 0
        let state = try handle.query("SELECT ifnull(max(sequence), 0) FROM memory_part_states WHERE part_id = ?", [.text(part)]) {
            $0.integer(0) ?? 0
        }.first ?? 0
        return (qualification, state)
    }

    // MARK: Sources

    /// One version as the selector reads it, from the authoritative tables now.
    static func source(_ handle: some SQLiteQuerying, routeID: String) throws -> RecallSource? {
        guard let stored = try SQLiteProcedureRows.stored(handle, routeID: routeID) else { return nil }
        let version = stored.version
        let offered = try offered(handle, routeID: routeID)
        func entry(of part: ProcedurePart) -> RecallSource.Entry {
            let item = stored.contract.first { $0.partID == part.partID && $0.kind == .entryState }
            if let scene = item?.sceneID ?? stored.lateEntryStates[part.partID] { return .state(scene) }
            return .unknown
        }
        let stepParts = Dictionary(uniqueKeysWithValues: version.parts.filter { $0.kind == .step }.map { ($0.firstPosition, $0) })
        // The state each step's call left the window in: the structural scene its sample after acting was placed in.
        let exits = Dictionary(try handle.query(
            """
            SELECT o.step_id, s.scene_id FROM memory_procedure_step_occurrences o
            JOIN memory_step_events m ON m.step_occurrence_id = o.step_occurrence_id AND m.role = 'action'
            JOIN memory_event_scenes s ON s.event_id = m.event_id AND s.phase = 'after' AND s.sample_ordinal = 0
                AND s.match_status = 'confirmed'
            WHERE o.route_id = ?
            """,
            [.text(routeID)]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }, uniquingKeysWith: { first, _ in first })
        // The functional identity of the element each step's call acted on, as the Brain's relations key it.
        let keys = Dictionary(try handle.query(
            """
            SELECT o.step_id, r.element_key FROM memory_procedure_step_occurrences o
            JOIN memory_step_events m ON m.step_occurrence_id = o.step_occurrence_id AND m.role = 'action'
            JOIN brain_relation_evidence v ON v.call_event_id = m.event_id AND v.relation = 'supports'
            JOIN brain_relations r ON r.relation_id = v.relation_id AND r.element_key IS NOT NULL
            WHERE o.route_id = ? ORDER BY v.sequence DESC
            """,
            [.text(routeID)]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }, uniquingKeysWith: { first, _ in first })
        // A step is offered on its own admission or as a step of an offered procedure or subprocedure: since qualification B
        // a method admitted on its verified result is reused whole, its steps whose own check stayed unknown included
        // (14 October 2026: the choice of a run's whole method was refused for four such steps).
        let offeredMethods = version.parts.filter { $0.kind != .step && offered.contains($0.partID) }
        func isOffered(_ part: ProcedurePart) -> Bool {
            offered.contains(part.partID)
                || offeredMethods.contains { $0.firstPosition <= part.firstPosition && part.lastPosition <= $0.lastPosition }
        }
        let steps = version.definition.steps.compactMap { step -> RecallSource.Step? in
            guard let part = stepParts[step.position], let operation = step.operations.first else { return nil }
            return RecallSource.Step(position: step.position, partID: part.partID, label: part.label, bundleID: step.bundleID,
                                     tool: operation.tool, arguments: operation.arguments, entry: entry(of: part),
                                     exit: exits[step.stepID].map(RecallSource.Entry.state) ?? .unknown,
                                     isOffered: isOffered(part), elementKey: keys[step.stepID])
        }
        let parts = version.parts.map {
            RecallSource.Part(partID: $0.partID, kind: $0.kind, firstPosition: $0.firstPosition, lastPosition: $0.lastPosition,
                              label: $0.label, bundleID: $0.bundleID, isOffered: offered.contains($0.partID))
        }
        let details = Dictionary(uniqueKeysWithValues: version.parameterDetails.map { ($0.parameterID, $0) })
        // The task of each attempt that bound a parameter: what a reference to an output of that task names.
        let tasks = Dictionary(try handle.query(
            """
            SELECT DISTINCT b.task_occurrence_id, a.task_id FROM memory_parameter_bindings b
            JOIN memory_task_attempts a ON a.task_occurrence_id = b.task_occurrence_id
            WHERE b.route_id = ?
            """,
            [.text(routeID)]
        ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }, uniquingKeysWith: { first, _ in first })
        let parameters = version.definition.parameters.map { parameter -> RecallSource.Parameter in
            let detail = details[parameter.parameterID]
            let bindings = version.bindings.filter { $0.parameterID == parameter.parameterID }
            let observed = bindings.compactMap { binding -> String? in
                if case .text(let text) = binding.content { return text } else { return nil }
            }
            let origins = bindings.compactMap { binding -> RecallSource.Origin? in
                guard let task = tasks[binding.attemptID] else { return nil }
                let value: String? = if case .text(let text) = binding.content { text } else { nil }
                return RecallSource.Origin(source: binding.source, reference: binding.sourceRef, referenceVersion: binding.sourceVersion,
                                           attemptID: binding.attemptID, taskID: task, value: value)
            }
            return RecallSource.Parameter(parameterID: parameter.parameterID, name: parameter.name, role: detail?.role ?? parameter.name,
                                          kind: detail?.kind ?? .text, direction: parameter.direction, unit: detail?.unit,
                                          observedValues: observed, producedBy: detail?.producedByPartID, origins: origins)
        }
        let uses = try handle.query(
            """
            SELECT count(*) FROM memory_recall_selections s
            WHERE s.route_id = ? AND s.role = 'selected'
              AND NOT EXISTS (
                  SELECT 1 FROM memory_procedure_parts p WHERE p.route_id = s.route_id AND p.part_kind = 'step'
                    AND p.first_position BETWEEN s.first_position AND s.last_position
                    AND NOT EXISTS (SELECT 1 FROM memory_recall_links l WHERE l.query_id = s.query_id AND l.need_position = s.need_position
                                    AND l.step_position = p.first_position AND l.confirmed = 1)
                    AND NOT EXISTS (SELECT 1 FROM memory_recall_choice_links c WHERE c.query_id = s.query_id
                                    AND c.need_position = s.need_position AND c.selection_position = s.position
                                    AND c.step_position = p.first_position AND c.confirmed = 1))
            """,
            [.text(routeID)]
        ) { Int($0.integer(0) ?? 0) }.first ?? 0
        var source = RecallSource(routeID: routeID, procedureLabel: version.definition.name, steps: steps, parts: parts, parameters: parameters,
                                  confirmedUses: uses)
        // The attempt's result checks, as templates over the values this version bound: how a reuse checks its result.
        let results = try SQLiteProcedureRows.results(handle, attemptID: version.attemptID)
        let values = parameters.flatMap { parameter in parameter.observedValues.map { (name: parameter.name, value: $0) } }
        // When each check was made: after the last step of the version whose call came before it.
        let calls = try SQLiteProcedureRows.callPositions(handle, version: version)
        let last = version.definition.steps.indices.last
        source.results = results.compactMap { row -> RecallSource.Result? in
            // `none` proves nothing, and a folder's guard is Braus's own, added again at every end: neither is for a reuse to give.
            guard let expectation = row.expectation, !row.isGuard else { return nil }
            switch expectation {
                case .nothing, .noOtherFiles: return nil
                default: break
            }
            let after = calls.filter { $0.value < row.position }.max { $0.value < $1.value }?.key
            return RecallSource.Result(expectation: expectation.template(over: values), afterStep: after, atEnd: after == nil || after == last)
        }
        source.resultVerdict = TaskResultCheck.combined(results.filter { row in
            if row.isGuard { return false }
            if case .nothing? = row.expectation { return false }
            return true
        }.map(\.verdict))
        return source
    }

    // MARK: Facts

    static func record(_ transaction: SQLiteTransaction, _ query: SQLiteRecallRepository.RecordedQuery, at nowMS: Int64) throws {
        let request = query.request
        try transaction.execute(
            """
            INSERT INTO memory_recall_queries (query_id, task_id, task_occurrence_id, task_revision, source, source_stream_id, reason,
                remaining_work, generation_id, channel, search_status, search_note, candidate_limit, candidates_considered, coverage,
                delivery, delivery_bytes, selector_version, recorded_at_ms, duration_us)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(query.queryID), .text(request.taskID), .text(request.attemptID), .integer(Int64(request.revision)),
             .text(query.producer.source.rawValue), .text(query.producer.streamID), .text(request.reason.rawValue), .text(request.remainingWork),
             query.generationID.map(SQLiteValue.integer) ?? .null, .text(query.channel.rawValue), .text(query.searchStatus.rawValue),
             query.searchNote.map(SQLiteValue.text) ?? .null, .integer(Int64(RecallContract.candidateLimit)),
             .integer(Int64(query.candidatesConsidered)), .text(query.coverage.rawValue), .text(query.delivery),
             query.deliveryBytes.map { .integer(Int64($0)) } ?? .null, .text(query.selectorVersion), .integer(nowMS),
             query.durationUS.map(SQLiteValue.integer) ?? .null]
        )
        for need in query.needs {
            try transaction.execute(
                "INSERT INTO memory_recall_needs (query_id, position, text, bundle_id, coverage, reason) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(query.queryID), .integer(Int64(need.position)), .text(need.need.text), need.need.bundleID.map(SQLiteValue.text) ?? .null,
                 .text(need.coverage.rawValue), need.reason.map { .text($0.rawValue) } ?? .null]
            )
            let selections = need.delivered + need.alternatives + need.excluded
            for (position, selection) in selections.enumerated() {
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_selections (query_id, need_position, position, role, route_id, first_position, last_position,
                        whole_part_id, relevance, preparations) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(query.queryID), .integer(Int64(need.position)), .integer(Int64(position)), .text(selection.role.rawValue),
                     .text(selection.routeID), .integer(Int64(selection.firstPosition)), .integer(Int64(selection.lastPosition)),
                     selection.wholePartID.map(SQLiteValue.text) ?? .null, .real(selection.relevance), .integer(Int64(selection.preparations))]
                )
                for (index, requirement) in selection.requirements.enumerated() {
                    try transaction.execute(
                        """
                        INSERT INTO memory_recall_requirements (query_id, need_position, selection_position, position, kind, step_position,
                            parameter_id, scene_id, bundle_id, task_value_name, binding_match, constraint_position)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.text(query.queryID), .integer(Int64(need.position)), .integer(Int64(position)), .integer(Int64(index)),
                         .text(requirement.kind.rawValue), requirement.stepPosition.map { .integer(Int64($0)) } ?? .null,
                         requirement.parameterID.map(SQLiteValue.text) ?? .null, requirement.sceneID.map(SQLiteValue.text) ?? .null,
                         requirement.bundleID.map(SQLiteValue.text) ?? .null, requirement.taskValueName.map(SQLiteValue.text) ?? .null,
                         requirement.bindingMatch.map { .text($0.rawValue) } ?? .null,
                         requirement.constraintPosition.map { .integer(Int64($0)) } ?? .null]
                    )
                }
            }
        }
    }

    /// A query's facts as lines, from the rows `record` writes: needs, selections and requirements, without the relevance (a
    /// real number) or the query's own identity and instant.
    static func facts(of query: SQLiteRecallRepository.RecordedQuery) -> [String] {
        var lines: [String] = []
        for need in query.needs {
            lines.append(needLine(need.position, need.coverage.rawValue, need.reason?.rawValue))
            for (position, selection) in (need.delivered + need.alternatives + need.excluded).enumerated() {
                lines.append(selectionLine(need.position, position, selection.role.rawValue, selection.routeID, selection.firstPosition,
                                           selection.lastPosition, selection.wholePartID, selection.preparations))
                for (index, requirement) in selection.requirements.enumerated() {
                    lines.append(requirementLine(need.position, position, index, requirement.kind.rawValue, requirement.stepPosition,
                                                 requirement.parameterID, requirement.sceneID, requirement.bundleID, requirement.taskValueName,
                                                 requirement.bindingMatch?.rawValue, requirement.constraintPosition))
                }
            }
        }
        return lines.sorted()
    }

    static func facts(_ handle: some SQLiteQuerying, queryID: String) throws -> [String] {
        let id: [SQLiteValue] = [.text(queryID)]
        let needs = try handle.query("SELECT position, coverage, reason FROM memory_recall_needs WHERE query_id = ?", id) {
            needLine(Int($0.integer(0) ?? 0), try $0.text(1) ?? "", try $0.text(2))
        }
        let selections = try handle.query(
            """
            SELECT need_position, position, role, route_id, first_position, last_position, whole_part_id, preparations
            FROM memory_recall_selections WHERE query_id = ?
            """, id
        ) { selectionLine(Int($0.integer(0) ?? 0), Int($0.integer(1) ?? 0), try $0.text(2) ?? "", try $0.text(3) ?? "",
                          Int($0.integer(4) ?? 0), Int($0.integer(5) ?? 0), try $0.text(6), Int($0.integer(7) ?? 0)) }
        let requirements = try handle.query(
            """
            SELECT need_position, selection_position, position, kind, step_position, parameter_id, scene_id, bundle_id, task_value_name,
                   binding_match, constraint_position
            FROM memory_recall_requirements WHERE query_id = ?
            """, id
        ) { requirementLine(Int($0.integer(0) ?? 0), Int($0.integer(1) ?? 0), Int($0.integer(2) ?? 0), try $0.text(3) ?? "",
                            $0.integer(4).map { Int($0) }, try $0.text(5), try $0.text(6), try $0.text(7), try $0.text(8), try $0.text(9),
                            $0.integer(10).map { Int($0) }) }
        return (needs + selections + requirements).sorted()
    }

    private static func needLine(_ position: Int, _ coverage: String, _ reason: String?) -> String {
        "need \(position) \(coverage) \(reason ?? "-")"
    }

    private static func selectionLine(_ need: Int, _ position: Int, _ role: String, _ route: String, _ first: Int, _ last: Int,
                                      _ whole: String?, _ preparations: Int) -> String {
        "selection \(need).\(position) \(role) \(route) \(first)-\(last) \(whole ?? "-") \(preparations)"
    }

    private static func requirementLine(_ need: Int, _ selection: Int, _ position: Int, _ kind: String, _ step: Int?, _ parameter: String?,
                                        _ scene: String?, _ bundle: String?, _ value: String?, _ match: String?, _ constraint: Int?) -> String {
        ["requirement \(need).\(selection).\(position)", kind, step.map(String.init) ?? "-", parameter ?? "-", scene ?? "-", bundle ?? "-",
         value ?? "-", match ?? "-", constraint.map(String.init) ?? "-"].joined(separator: " ")
    }

    static func selections(_ handle: some SQLiteQuerying, attemptID: String) throws -> [SQLiteRecallRepository.StoredSelection] {
        let rows = try handle.query(
            """
            SELECT s.query_id, s.need_position, q.recorded_at_ms, s.route_id, s.first_position, s.last_position, q.task_revision,
                   s.position, (SELECT count(*) FROM memory_recall_choices c WHERE c.query_id = s.query_id)
            FROM memory_recall_selections s JOIN memory_recall_queries q ON q.query_id = s.query_id
            WHERE q.task_occurrence_id = ? AND s.role = 'selected' AND q.delivery = 'delivered'
            ORDER BY q.recorded_at_ms, q.rowid, s.need_position, s.position
            """,
            [.text(attemptID)]
        ) { (query: try $0.text(0) ?? "", need: Int($0.integer(1) ?? 0), at: $0.integer(2) ?? 0, route: try $0.text(3) ?? "",
             first: Int($0.integer(4) ?? 0), last: Int($0.integer(5) ?? 0), revision: Int($0.integer(6) ?? 1),
             position: Int($0.integer(7) ?? 0), choice: ($0.integer(8) ?? 0) > 0) }
        return try rows.map { row in
            let bindings = try handle.query(
                """
                SELECT parameter_id, task_value_name FROM memory_recall_requirements
                WHERE query_id = ? AND need_position = ? AND selection_position = ? AND kind = 'parameter_bound'
                """,
                [.text(row.query), .integer(Int64(row.need)), .integer(Int64(row.position))]
            ) { (try $0.text(0) ?? "", try $0.text(1) ?? "") }
            var stored = SQLiteRecallRepository.StoredSelection(queryID: row.query, needPosition: row.need, recordedAtMS: row.at,
                                                                routeID: row.route, firstPosition: row.first, lastPosition: row.last,
                                                                bindings: Dictionary(bindings, uniquingKeysWith: { first, _ in first }),
                                                                taskRevision: row.revision)
            stored.selectionPosition = row.position
            stored.isChoice = row.choice
            return stored
        }
    }

    static func calls(_ handle: some SQLiteQuerying, attemptID: String, after afterMS: Int64) throws -> [RecallUseLinking.Call] {
        let ids = try handle.query(
            """
            SELECT t.event_id FROM memory_task_events t JOIN memory_agent_actions a ON a.event_id = t.event_id
            WHERE t.task_occurrence_id = ? AND t.role = 'action' AND ifnull(a.started_at_ms, 0) >= ?
            ORDER BY t.position
            """,
            [.text(attemptID), .integer(afterMS)]
        ) { try $0.text(0) ?? "" }
        return try ids.compactMap { id in
            guard let call = try SQLiteAgentCallRows.call(handle, eventID: id), call.request.tool.isOperation,
                  call.progress.status != .planned, call.progress.status != .skipped else { return nil }
            let passed = try handle.query(
                """
                SELECT count(*) FROM memory_operation_verifications v JOIN memory_verifications b ON b.event_id = v.event_id
                WHERE v.call_event_id = ? AND b.verdict = 'passed'
                """,
                [.text(id)]
            ) { $0.integer(0) ?? 0 }.first ?? 0
            let entry = try SQLiteProcedureRows.confirmedScene(handle, eventID: id, phase: .before)
            return RecallUseLinking.Call(eventID: id, request: call.request, checkPassed: passed > 0 && call.progress.status == .completed,
                                         bundleID: try bundle(handle, eventID: id), entry: entry.map(RecallSource.Entry.state) ?? .unknown,
                                         elementKey: try elementKey(handle, callEventID: id))
        }
    }

    static func observedState(_ handle: some SQLiteQuerying, source: MemoryEventSource, stream: String,
                              since sinceMS: Int64) throws -> ObservedState? {
        let latest = try handle.query(
            """
            SELECT e.event_id, b.bundle_id, e.occurred_at_ms FROM memory_events e JOIN brain_apps b ON b.app_id = e.app_id
            WHERE e.source = ? AND e.source_stream_id = ? AND e.event_kind IN ('action', 'observation')
            ORDER BY e.local_order DESC LIMIT 1
            """,
            [.text(source.rawValue), .text(stream)]
        ) { (event: try $0.text(0) ?? "", bundle: try $0.text(1) ?? "", at: $0.integer(2) ?? 0) }
        guard let (event, bundle, at) = latest.first, at >= sinceMS else { return nil }
        return try handle.query(
            """
            SELECT scene_id FROM memory_event_scenes WHERE event_id = ? AND phase IN ('after', 'current') AND match_status = 'confirmed'
            ORDER BY CASE phase WHEN 'current' THEN 0 ELSE 1 END, sample_ordinal DESC LIMIT 1
            """,
            [.text(event)]
        ) { try $0.text(0) }.first?.map { ObservedState(bundleID: bundle, sceneID: $0) }
    }

    /// The application a call's event acted on.
    static func bundle(_ handle: some SQLiteQuerying, eventID: String) throws -> String? {
        try handle.query(
            "SELECT b.bundle_id FROM memory_events e JOIN brain_apps b ON b.app_id = e.app_id WHERE e.event_id = ?", [.text(eventID)]
        ) { try $0.text(0) }.first ?? nil
    }

    /// The functional identity of the element a call acted on, as the Brain's relation its latest evaluation supports
    /// keys it; nil when no relation identified the element (an indistinct element, a call still waiting for its state).
    static func elementKey(_ handle: some SQLiteQuerying, callEventID: String) throws -> String? {
        try handle.query(
            """
            SELECT r.element_key FROM brain_relation_evidence v JOIN brain_relations r ON r.relation_id = v.relation_id
            WHERE v.call_event_id = ? AND v.relation = 'supports' AND r.element_key IS NOT NULL
            ORDER BY v.sequence DESC LIMIT 1
            """,
            [.text(callEventID)]
        ) { try $0.text(0) }.first ?? nil
    }
}
