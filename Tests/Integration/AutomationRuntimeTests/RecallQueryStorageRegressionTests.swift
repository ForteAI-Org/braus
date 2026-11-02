@testable import AutomationRuntime
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

@MainActor
@Suite("Recall results stay unchanged when requests are stored", .serialized)
struct RecallQueryStorageRegressionTests {
    @Test func twentyRequestsKeepTheirResults() async throws {
        typealias P = ProcedureLearningTests
        typealias L = RecallLifecycleTests
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService.shared(for: memory)
        let tools = P.tools(session, stream: "query-storage")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Export the photo as PNG","recall":false}"#)
        let taskID = try #require(begun["task"].string)
        let attemptID = try #require(begun["attempt"].string)
        let producer = try TaskProducer(source: .app, streamID: "query-storage")
        for index in 0..<20 {
            let name = "private-photo-\(index).png"
            let text = "Export the photo already rotated in Preview as \(name) in PNG"
            let value = try TaskValue(name: "file", kind: .file, content: .text(name), source: .request)
            let need = try RecallNeed(text: text)
            let request = try RecallRequest(taskID: taskID, attemptID: attemptID, revision: 1, reason: .initial,
                                        remainingWork: text, needs: [need], values: [value])
            let prepared = try await service.prepare(request)
            #expect(prepared.sources.contains { $0.routeID == routeID })
            let before = service.outcomes(prepared)
            let coverage = NeedOutcome.overall(before)
            let query = SQLiteRecallRepository.RecordedQuery(
                queryID: "stored-query-\(index)", request: request, producer: producer,
                generationID: prepared.channel == .none ? nil : prepared.cache?.generation.generationID,
                channel: prepared.channel, searchStatus: prepared.searchStatus,
                searchNote: prepared.notes.isEmpty ? nil : prepared.notes.joined(separator: "; "),
                candidatesConsidered: prepared.considered, coverage: coverage,
                delivery: coverage == .absent || coverage == .unknown ? "nothing" : "delivered",
                deliveryBytes: nil, durationUS: nil, needs: before
            )
            try await memory.perform { try await $0.recall.record(query, at: 1_000 + Int64(index)) }
            let after = service.outcomes(try await service.prepare(request))
            try #require(before == after)
            #expect(request.remainingWork == text && request.searchedNeeds[0].text == text)
        }
        let work = try P.rows("SELECT remaining_work FROM memory_recall_queries WHERE query_id LIKE 'stored-query-%'", in: session)
        let needs = try P.rows("SELECT text FROM memory_recall_needs WHERE query_id LIKE 'stored-query-%'", in: session)
        #expect(work.count == 20 && needs.count == 20)
        #expect((work + needs).allSatisfy { $0.contains("{file}") && !$0.contains("private-photo-") })
        await L.close(session)
    }
}
