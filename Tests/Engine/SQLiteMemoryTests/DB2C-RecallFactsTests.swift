import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Recall assigned identities on schema 22", .serialized)
struct DB2CRecallFactsTests {
    private func open() async throws -> SQLiteMemoryStore {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        try await store.write { transaction in
            let statements = """
                INSERT INTO memory_tasks(task_uuid,contract_version,source,source_stream_id,opened_at_ms,status,current_revision)
                VALUES ('task',1,'app','stream',1,'open',1);
                INSERT INTO memory_task_revisions(task_id,revision,recorded_at_ms,change_kind,goal)
                VALUES (1,1,1,'opened','Save');
                INSERT INTO memory_task_occurrences(task_occurrence_uuid,started_at_ms,status) VALUES ('attempt',1,'in_progress');
                INSERT INTO memory_task_attempts(task_occurrence_id,task_id,ordinal,source,source_stream_id,opened_at_ms,opened_at_revision,task_revision_id)
                VALUES (1,1,1,'app','stream',1,1,1);
                """
            for statement in statements.split(separator: ";") { try transaction.execute(String(statement)) }
        }
        return store
    }

    @Test func assignsBeforeRenderingAndKeepsMaskedNeeds() async throws {
        let store = try await open()
        let repository = SQLiteRecallRepository(store: store)
        let need = try RecallNeed(text: "Save the document")
        let request = try RecallRequest(taskID: "task", attemptID: "attempt", revision: 1, reason: .initial,
                                       remainingWork: "Save the document", needs: [need])
        let producer = try TaskProducer(source: .app, streamID: "stream")
        let (query, rendered) = try await repository.recordPrepared(proposedID: "producer-id", at: 2) { id in
            let text = "query=\(id)"
            let query = SQLiteRecallRepository.RecordedQuery(
                queryID: id, request: request, producer: producer, generationID: nil, channel: .none,
                searchStatus: .completed, searchNote: nil, candidatesConsidered: 0, coverage: .absent,
                delivery: "nothing", deliveryBytes: text.utf8.count, durationUS: nil,
                needs: [.init(position: 0, need: need, coverage: .absent, reason: nil, selected: nil, alternatives: [])])
            return (query, text)
        }
        #expect(rendered == "query=\(query.queryID)")
        #expect(Int64(query.queryID) != nil)
        #expect(query.deliveryBytes == rendered.utf8.count)
        #expect(try await repository.facts(ofQuery: query.queryID) == SQLiteRecallRepository.facts(of: query))
        try await store.write { transaction in
            try transaction.execute("INSERT INTO memory_events(event_uuid,source,source_stream_id,event_kind,occurred_at_ms,capture_status) VALUES ('event','app','stream','action',3,'not_applicable')")
            try transaction.execute("INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status) VALUES (1,'status','planned')")
            try transaction.execute("INSERT INTO memory_task_events(task_occurrence_id,event_id,position,role) VALUES (1,1,0,'action')")
        }
        let links = RecallUseLinking.link(steps: [], calls: [.init(eventID: "event", request: .status, checkPassed: false)], values: [:])
        #expect(try await repository.link(queryID: query.queryID, needPosition: 0, links: links, at: 4) == 1)
        #expect(try await repository.link(queryID: query.queryID, needPosition: 0, links: links, at: 5) == 0)
        try await repository.report(queryID: query.queryID, needPosition: 0, declared: "not_executed", cause: "agent", note: nil, at: 6)
        let inspection = try await store.read { try SQLiteRecallInspectionRows.queries($0, attemptID: "attempt") }
        #expect(inspection.first?.queryID == query.queryID)
        #expect(inspection.first?.remainingWork == "Save the document")
        #expect(inspection.first?.needs.first?.links.first?.callEventID == "event")
        #expect(inspection.first?.needs.first?.reports.first?.declared == "not_executed")
        try await repository.record(query.withIdentity("9000", deliveryBytes: nil), at: 7)
        let assigned = try await store.read { try $0.query("SELECT query_id FROM memory_recall_queries ORDER BY query_id DESC LIMIT 1") { try $0.text(0) }.first ?? nil }
        #expect(assigned != "9000")
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }
    @Test func proposalAndChoiceUseAssignedKeys() async throws {
        let store = try await open()
        let repository = SQLiteRecallRepository(store: store)
        let producer = try TaskProducer(source: .app, streamID: "stream")
        let need = try RecallNeed(text: "Save the document")
        let (recorded, text) = try await repository.recordPreparedProposal(proposedID: "producer-proposal") { id in
            let proposal = RecallChoice.Proposal(proposalID: id, taskID: "task", attemptID: "attempt", revision: 1,
                                                 producer: producer, reason: .initial, remainingWork: "Save the document",
                                                 needs: [need], shortlisted: [], recordedAtMS: 2)
            return (SQLiteRecallRepository.RecordedProposal(proposal: proposal, generationID: nil, channel: .none,
                searchStatus: .completed, searchNote: nil, candidatesConsidered: 0, bytes: id.utf8.count, durationUS: nil), id)
        }
        #expect(text == recorded.proposal.proposalID)
        #expect(Int64(text) != nil)
        let read = try #require(try await repository.proposal(text))
        #expect(read.proposal.taskID == "task")
        #expect(read.proposal.attemptID == "attempt")
        #expect(read.proposal.needs.first?.text == "Save the document")
        let request = try RecallRequest(taskID: "task", attemptID: "attempt", revision: 1, reason: .initial,
                                       remainingWork: "Save the document", needs: [need])
        let result = try await repository.recordPreparedChoice(proposedID: "producer-query", proposalID: text, declarations: [], at: 3) { id in
            let query = SQLiteRecallRepository.RecordedQuery(queryID: id, request: request, producer: producer,
                generationID: nil, channel: .none, searchStatus: .completed, searchNote: nil, candidatesConsidered: 0,
                coverage: .absent, delivery: "nothing", deliveryBytes: 1, durationUS: nil,
                needs: [.init(position: 0, need: need, coverage: .absent, reason: nil, selected: nil, alternatives: [])])
            return (query, id)
        }
        guard case .recorded(let query, let rendered) = result else { Issue.record("expected recorded choice"); return }
        #expect(rendered == query.queryID)
        #expect(try await repository.choice(ofProposal: text)?.queryID == query.queryID)
        let duplicate = try await repository.recordPreparedChoice(proposedID: "other-query", proposalID: text, declarations: [], at: 4) { _ -> (SQLiteRecallRepository.RecordedQuery, String) in
            Issue.record("a chosen proposal allocated another query")
            return (query, "unexpected")
        }
        guard case .alreadyApplied(let id, _) = duplicate else { Issue.record("expected previous choice"); return }
        #expect(id == query.queryID)
        try await repository.recordProposal(recorded.withIdentity("9000", bytes: 4))
        let secondID = try #require(try await store.read { try $0.query("SELECT proposal_id FROM memory_recall_proposals ORDER BY proposal_id DESC LIMIT 1") { try $0.text(0) }.first ?? nil })
        #expect(secondID != "9000")
        try await repository.record(query.withIdentity("independent", deliveryBytes: 1), at: 5)
        #expect(try await repository.recordChoice(query.withIdentity("caller-query", deliveryBytes: 1), proposalID: secondID, declarations: [], at: 5) == nil)
        let secondChoice = try #require(try await repository.choice(ofProposal: secondID))
        #expect(Int64(secondChoice.queryID) != nil)
        let latestQuery = try await store.read { try $0.query("SELECT query_id FROM memory_recall_queries ORDER BY query_id DESC LIMIT 1") { try $0.text(0) }.first ?? nil }
        #expect(secondChoice.queryID == latestQuery)
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }

    @Test func calibratedProposalKeepsAssignedIdentityAndMissingSignals() async throws {
        let memory = try await ProcedureRepositoryTests.populated(schema: .version22)
        let (_, route) = try await ProcedureRepositoryTests.interpreted(memory)
        let procedures = SQLiteProcedureRepository(store: memory.store)
        let version = try #require(try await procedures.version(route))
        let part = try #require(version.version.parts.first)
        let repository = SQLiteRecallRepository(store: memory.store)
        let need = try RecallNeed(text: "Open the export menu")
        let proposal = RecallChoice.Proposal(proposalID: "producer-proposal", taskID: "task-1",
            attemptID: "attempt-1", revision: 1, producer: TaskFixtures.producer, reason: .initial,
            remainingWork: need.text, needs: [need], shortlisted: [], recordedAtMS: TaskFixtures.t0 + 200)
        let original = SQLiteRecallRepository.RecordedProposal(proposal: proposal, generationID: nil,
            channel: .none, searchStatus: .completed, searchNote: nil, candidatesConsidered: 1,
            bytes: 0, durationUS: nil, calibration: [.init(needPosition: 0, partID: part.partID,
                rank: 0, cosine: nil, lexical: 0.8, score: 0.8, threshold: 0.6, delivered: true)])
        let (saved, rendered) = try await repository.recordPreparedProposal(proposedID: proposal.proposalID) { id in
            let text = "proposal=\(id)"
            return (original.withIdentity(id, bytes: text.utf8.count), text)
        }
        #expect(saved.calibration == original.calibration)
        #expect(rendered == "proposal=\(saved.proposal.proposalID)")
        #expect(saved.bytes == rendered.utf8.count)
        let rows = try await memory.store.read { handle in
            try handle.query("""
                SELECT q.query_id,p.part_uuid,c.cosine,c.lexical,c.used
                FROM memory_recall_calibration c JOIN memory_recall_queries q USING(query_id)
                JOIN memory_procedure_parts p USING(part_id)
                """) { (try $0.text(0), try $0.text(1), $0.real(2), $0.real(3), $0.integer(4)) }
        }
        #expect(rows.count == 1)
        #expect(rows.first?.0 == saved.proposal.proposalID)
        #expect(rows.first?.1 == part.partID)
        #expect(rows.first?.2 == nil)
        #expect(rows.first?.3 == 0.8)
        try await repository.finishCalibration(attemptID: "attempt-1")
        let used = try await memory.store.read {
            try $0.query("SELECT used FROM memory_recall_calibration") { $0.integer(0) }
        }
        #expect(used == [0])
        #expect(try await memory.store.read { try SchemaCoherence.check($0) }.isEmpty)
        await memory.store.close()
    }

    @Test func admissibilityReadsPublicRouteAndAttemptIdentities() async throws {
        let memory = try await ProcedureRepositoryTests.populated(schema: .version22)
        let (_, route) = try await ProcedureRepositoryTests.interpreted(memory)
        let repository = SQLiteProcedureRepository(store: memory.store)
        let facts = try await repository.admissibility(of: [route])
        let fact = try #require(facts[route])
        #expect(fact.family.rootRouteUUID == route)
        #expect(!fact.channels.isEmpty)
        #expect(!fact.fromFailedAttempt)
        await memory.store.close()
    }

}
