import Memory

extension SQLiteRecallRepository {
    static func recordProposal22(_ transaction: SQLiteTransaction, _ recorded: RecordedProposal, assignedIdentity: Bool) throws {
            let proposal = recorded.proposal
            let proposedKey: SQLiteValue = assignedIdentity ? (Int64(proposal.proposalID).map(SQLiteValue.integer) ?? .null) : .null
            try transaction.execute(
                """
                INSERT INTO memory_recall_proposals (proposal_id, task_id, task_occurrence_id, task_revision, source, source_stream_id,
                    reason, remaining_work, generation_id, channel, search_status, search_note, candidates_considered, proposal_bytes,
                    format_version, recorded_at_ms, duration_us)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [proposedKey, try DB2CIdentity.key(transaction, "memory_tasks", proposal.taskID), try DB2CIdentity.key(transaction, "memory_task_occurrences", proposal.attemptID), .integer(Int64(proposal.revision)),
                 .text(proposal.producer.source.rawValue), .text(proposal.producer.streamID), .text(proposal.reason.rawValue),
                 .text(proposal.remainingWork), recorded.generationID.map(SQLiteValue.integer) ?? .null, .text(recorded.channel.rawValue),
                 .text(recorded.searchStatus.rawValue), recorded.searchNote.map(SQLiteValue.text) ?? .null,
                 .integer(Int64(recorded.candidatesConsidered)), .integer(Int64(recorded.bytes)), .text(RecallChoice.formatVersion),
                 .integer(proposal.recordedAtMS), recorded.durationUS.map(SQLiteValue.integer) ?? .null]
            )
            let proposalKey = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
            for (position, need) in proposal.needs.enumerated() {
                try transaction.execute(
                    "INSERT INTO memory_recall_proposal_needs (proposal_id, position, text, bundle_id) VALUES (?, ?, ?, ?)",
                    [.integer(proposalKey), .integer(Int64(position)), .text(need.text), need.bundleID.map(SQLiteValue.text) ?? .null]
                )
            }
            var positions: [Int: Int] = [:]
            for item in proposal.shortlisted {
                let position = positions[item.needPosition, default: 0]
                positions[item.needPosition] = position + 1
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_proposal_sources (proposal_id, need_position, position, source_key, route_id, relevance,
                        suggested_first, suggested_last, proposal_need_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.integer(proposalKey), .integer(Int64(item.needPosition)), .integer(Int64(position)), .text(item.key),
                     try DB2CIdentity.key(transaction, "memory_routes", item.routeID), .real(item.relevance.isFinite ? item.relevance : 0),
                     item.suggested.map { .integer(Int64($0.lowerBound)) } ?? .null,
                     item.suggested.map { .integer(Int64($0.upperBound)) } ?? .null,
                     .integer(try transaction.query("SELECT proposal_need_id FROM memory_recall_proposal_needs WHERE proposal_id = ? AND position = ?",
                                                    [.integer(proposalKey), .integer(Int64(item.needPosition))]) { $0.integer(0) ?? 0 }.first ?? 0)]
                )
            }
        try DB2CCoherence.validate(transaction)
    }

    public enum ChoiceRecording<Value: Sendable>: Sendable {
        case recorded(RecordedQuery, Value)
        case alreadyApplied(queryID: String, plan: RecallChoice.Plan)
    }

    public func recordPreparedProposal<Value: Sendable>(proposedID: String,
        build: @escaping @Sendable (String) throws -> (RecordedProposal, Value)
    ) async throws -> (RecordedProposal, Value) {
        try await store.write { transaction in
            let id = try Self.assignedID(transaction, table: "memory_recall_proposals", column: "proposal_id", proposed: proposedID)
            let (proposal, value) = try build(id)
            guard proposal.proposal.proposalID == id else {
                throw SQLiteRecallRows.malformed("memory_recall_proposals", id, "assigned identity changed")
            }
            try Self.insertProposal(transaction, proposal, assignedIdentity: true)
            return (proposal, value)
        }
    }

    public func recordPreparedChoice<Value: Sendable>(proposedID: String, proposalID: String,
        declarations: [RecallChoice.Chosen], at nowMS: Int64,
        build: @escaping @Sendable (String) throws -> (RecordedQuery, Value)
    ) async throws -> ChoiceRecording<Value> {
        try await store.write { transaction in
            if let earlier = try Self.choice(transaction, proposalID: proposalID) {
                return .alreadyApplied(queryID: earlier.queryID, plan: earlier.plan)
            }
            let id = try Self.assignedID(transaction, table: "memory_recall_queries", column: "query_id", proposed: proposedID)
            let (query, value) = try build(id)
            guard query.queryID == id else { throw SQLiteRecallRows.malformed("memory_recall_queries", id, "assigned identity changed") }
            try SQLiteRecallRows.record(transaction, query, at: nowMS, assignedIdentity: true)
            try Self.insertChoice(transaction, queryID: id, proposalID: proposalID, declarations: declarations, at: nowMS)
            return .recorded(query, value)
        }
    }

    static func insertChoice(_ transaction: SQLiteTransaction, queryID: String, proposalID: String,
        declarations: [RecallChoice.Chosen], at nowMS: Int64
    ) throws {
        let integerKeys = try SQLiteRowIdentity(transaction).usesIntegerKeys
        let queryKey: SQLiteValue = integerKeys ? Int64(queryID).map(SQLiteValue.integer) ?? .null : .text(queryID)
        let proposalKey: SQLiteValue = integerKeys ? Int64(proposalID).map(SQLiteValue.integer) ?? .null : .text(proposalID)
        try transaction.execute("INSERT INTO memory_recall_choices (query_id, proposal_id, recorded_at_ms) VALUES (?, ?, ?)",
                                [queryKey, proposalKey, .integer(nowMS)])
        for chosen in declarations {
            let owner = integerKeys ? ", need_id" : ""
            let lookup = integerKeys ? ", (SELECT need_id FROM memory_recall_needs WHERE query_id = ? AND position = ?)" : ""
            var bindings: [SQLiteValue] = [queryKey, .integer(Int64(chosen.outcome.position)), .text(chosen.declared.rawValue),
                chosen.uncovered.map(SQLiteValue.text) ?? .null, chosen.settledBy.map(SQLiteValue.text) ?? .null]
            if integerKeys { bindings += [queryKey, .integer(Int64(chosen.outcome.position))] }
            try transaction.execute("INSERT INTO memory_recall_choice_needs (query_id, need_position, declared, uncovered, settled_by\(owner)) VALUES (?, ?, ?, ?, ?\(lookup))", bindings)
        }
        try DB2CCoherence.validate(transaction)
    }
}

extension SQLiteRecallRepository.RecordedQuery {
    public func withIdentity(_ id: String, deliveryBytes: Int?) -> Self {
        var result = Self(queryID: id, request: request, producer: producer, generationID: generationID, channel: channel,
            searchStatus: searchStatus, searchNote: searchNote, candidatesConsidered: candidatesConsidered, coverage: coverage,
            delivery: delivery, deliveryBytes: deliveryBytes, durationUS: durationUS, needs: needs)
        result.selectorVersion = selectorVersion
        return result
    }
}

extension SQLiteRecallRepository.RecordedProposal {
    public func withIdentity(_ id: String, bytes: Int) -> Self {
        let assigned = RecallChoice.Proposal(proposalID: id, taskID: proposal.taskID, attemptID: proposal.attemptID,
            revision: proposal.revision, producer: proposal.producer, reason: proposal.reason, remainingWork: proposal.remainingWork,
            needs: proposal.needs, shortlisted: proposal.shortlisted, recordedAtMS: proposal.recordedAtMS)
        return Self(proposal: assigned, generationID: generationID, channel: channel, searchStatus: searchStatus,
            searchNote: searchNote, candidatesConsidered: candidatesConsidered, bytes: bytes, durationUS: durationUS, calibration: calibration)
    }
}
