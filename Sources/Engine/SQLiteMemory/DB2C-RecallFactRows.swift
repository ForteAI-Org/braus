import Memory

extension SQLiteRecallRows {
    static func record22(_ transaction: SQLiteTransaction, _ query: SQLiteRecallRepository.RecordedQuery, at nowMS: Int64, assignedIdentity: Bool) throws -> String {
        let request = query.request
        let queryValue: SQLiteValue = assignedIdentity ? (Int64(query.queryID).map(SQLiteValue.integer) ?? .null) : .null
        let remainingWork = RecallQueryMasking.masked(request.remainingWork, values: request.values)
        try transaction.execute(
            """
            INSERT INTO memory_recall_queries (query_id, task_id, task_occurrence_id, task_revision, source, source_stream_id, reason,
                remaining_work, generation_id, channel, search_status, search_note, candidate_limit, candidates_considered, coverage,
                delivery, delivery_bytes, selector_version, recorded_at_ms, duration_us)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [queryValue, try DB2CIdentity.key(transaction, "memory_tasks", request.taskID), try DB2CIdentity.key(transaction, "memory_task_occurrences", request.attemptID), .integer(Int64(request.revision)),
             .text(query.producer.source.rawValue), .text(query.producer.streamID), .text(request.reason.rawValue), .text(remainingWork),
             query.generationID.map(SQLiteValue.integer) ?? .null, .text(query.channel.rawValue), .text(query.searchStatus.rawValue),
             query.searchNote.map(SQLiteValue.text) ?? .null, .integer(Int64(RecallContract.candidateLimit)),
             .integer(Int64(query.candidatesConsidered)), .text(query.coverage.rawValue), .text(query.delivery),
             query.deliveryBytes.map { .integer(Int64($0)) } ?? .null, .text(query.selectorVersion), .integer(nowMS),
             query.durationUS.map(SQLiteValue.integer) ?? .null]
        )
        let queryID = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
        for need in query.needs {
            let text = RecallQueryMasking.masked(need.need.text, values: request.values)
            try transaction.execute(
                "INSERT INTO memory_recall_needs (query_id, position, text, bundle_id, coverage, reason) VALUES (?, ?, ?, ?, ?, ?)",
                [.integer(queryID), .integer(Int64(need.position)), .text(text), need.need.bundleID.map(SQLiteValue.text) ?? .null,
                 .text(need.coverage.rawValue), need.reason.map { .text($0.rawValue) } ?? .null]
            )
            let needID = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
            let selections = need.delivered + need.alternatives + need.excluded
            for (position, selection) in selections.enumerated() {
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_selections (query_id, need_position, position, role, route_id, first_position, last_position,
                        whole_part_id, relevance, preparations, need_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(queryID), .integer(Int64(need.position)), .integer(Int64(position)), .text(selection.role.rawValue),
                     try DB2CIdentity.key(transaction, "memory_routes", selection.routeID), .integer(Int64(selection.firstPosition)), .integer(Int64(selection.lastPosition)),
                     try DB2CIdentity.key(transaction, "memory_procedure_parts", selection.wholePartID), .real(selection.relevance), .integer(Int64(selection.preparations)), .integer(needID)]
                )
                let selectionID = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
                for (index, requirement) in selection.requirements.enumerated() {
                    try transaction.execute(
                        """
                        INSERT INTO memory_recall_requirements (query_id, need_position, selection_position, position, kind, step_position,
                            parameter_id, scene_id, bundle_id, task_value_name, binding_match, constraint_position, selection_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.integer(queryID), .integer(Int64(need.position)), .integer(Int64(position)), .integer(Int64(index)),
                         .text(requirement.kind.rawValue), requirement.stepPosition.map { .integer(Int64($0)) } ?? .null,
                         try DB2CIdentity.key(transaction, "memory_route_parameters", requirement.parameterID), try DB2CIdentity.key(transaction, "brain_scenes", requirement.sceneID),
                         requirement.bundleID.map(SQLiteValue.text) ?? .null, requirement.taskValueName.map(SQLiteValue.text) ?? .null,
                         requirement.bindingMatch.map { .text($0.rawValue) } ?? .null,
                         requirement.constraintPosition.map { .integer(Int64($0)) } ?? .null, .integer(selectionID)]
                    )
                }
            }
        }
        try DB2CCoherence.validate(transaction)
        return String(queryID)
    }
}

extension SQLiteRecallRows {
    static func link22(_ transaction: SQLiteTransaction, queryID: String, needPosition: Int, selectionPosition: Int,
                      isChoice: Bool, links: [RecallUseLinking.Link], at nowMS: Int64) throws -> Int {
        let queryKey = Int64(queryID).map(SQLiteValue.integer) ?? .null
        let need = try transaction.query("SELECT need_id FROM memory_recall_needs WHERE query_id=? AND position=?",
                                        [queryKey, .integer(Int64(needPosition))]) { $0.integer(0) }.first ?? nil
        guard let need else { throw malformed("memory_recall_needs", queryID, "missing need") }
        var written = 0
        for link in links {
            let event = try DB2CIdentity.key(transaction, "memory_events", link.callEventID)
            let step = link.stepPosition.map { SQLiteValue.integer(Int64($0)) } ?? .null
            let flags: [SQLiteValue] = [.integer(link.confirmed ? 1 : 0), .integer(link.undetermined ? 1 : 0), .integer(nowMS)]
            if isChoice {
                let selection = link.stepPosition == nil ? nil : try transaction.query("""
                    SELECT selection_id FROM memory_recall_selections WHERE query_id=? AND need_position=? AND position=?
                    """, [queryKey, .integer(Int64(needPosition)), .integer(Int64(selectionPosition))]) { $0.integer(0) }.first ?? nil
                written += try transaction.execute("""
                    INSERT INTO memory_recall_choice_links(query_id,need_position,selection_position,call_event_id,step_position,
                        confirmed,undetermined,linked_at_ms,need_id,selection_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(query_id,call_event_id) DO NOTHING
                    """, [queryKey, .integer(Int64(needPosition)), link.stepPosition == nil ? .null : .integer(Int64(selectionPosition)), event, step]
                        + flags + [.integer(need), selection.map(SQLiteValue.integer) ?? .null])
            } else {
                written += try transaction.execute("""
                    INSERT INTO memory_recall_links(query_id,need_position,call_event_id,step_position,confirmed,undetermined,linked_at_ms,
                        need_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(query_id,call_event_id) DO NOTHING
                    """, [queryKey, .integer(Int64(needPosition)), event, step] + flags + [.integer(need)])
            }
        }
        try DB2CCoherence.validate(transaction)
        return written
    }

    static func report22(_ transaction: SQLiteTransaction, queryID: String, needPosition: Int, declared: String,
                         cause: String?, note: String?, at nowMS: Int64) throws {
        let key = Int64(queryID).map(SQLiteValue.integer) ?? .null
        let need = try transaction.query("SELECT need_id FROM memory_recall_needs WHERE query_id=? AND position=?",
            [key, .integer(Int64(needPosition))]) { $0.integer(0) }.first ?? nil
        guard let need else { throw malformed("memory_recall_needs", queryID, "missing need") }
        let next = (try transaction.query("SELECT coalesce(max(sequence),0) FROM memory_recall_reports WHERE need_id=?",
                                         [.integer(need)]) { $0.integer(0) ?? 0 }.first ?? 0) + 1
        try transaction.execute("""
            INSERT INTO memory_recall_reports(query_id,need_position,sequence,declared,cause,note,recorded_at_ms,need_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [key, .integer(Int64(needPosition)), .integer(next), .text(declared), cause.map(SQLiteValue.text) ?? .null,
                    note.map(SQLiteValue.text) ?? .null, .integer(nowMS), .integer(need)])
        try DB2CCoherence.validate(transaction)
    }
}
