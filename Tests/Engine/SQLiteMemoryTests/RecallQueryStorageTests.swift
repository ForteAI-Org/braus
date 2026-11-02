import Memory
@testable import SQLiteMemory
import Testing

@Suite("Stored Recall requests with withheld task values")
struct RecallQueryStorageTests {
    @Test func recordsOnlyMaskedText() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let repository = SQLiteRecallRepository(store: memory.store)
        let values = try [
            TaskFixtures.value("file", "private-document.pdf"),
            TaskValue(name: "password", kind: .text, content: .withheld, sensitivity: .secret, source: .request)
        ]
        let text = "open /old-private-document.pdf using sk-fake00000000000000000000"
        let need = try RecallNeed(text: text)
        let request = try RecallRequest(taskID: "task-1", attemptID: "attempt-1", revision: 1, reason: .initial,
                                    remainingWork: text, needs: [need], values: values)
        try await repository.record(.init(
            queryID: "query-1", request: request, producer: TaskFixtures.producer, generationID: nil,
            channel: .none, searchStatus: .completed, searchNote: nil, candidatesConsidered: 0,
            coverage: .absent, delivery: "nothing", deliveryBytes: nil, durationUS: nil,
            needs: [.init(position: 0, need: need, coverage: .absent, reason: nil, selected: nil, alternatives: [])]
        ), at: TaskFixtures.t0)
        let texts = try await memory.store.read { snapshot in
            try snapshot.query("SELECT remaining_work FROM memory_recall_queries UNION ALL SELECT text FROM memory_recall_needs") {
                try $0.text(0) ?? ""
            }
        }
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0 == "open /old-{file} using [withheld]" })
        #expect(request.remainingWork == text && request.searchedNeeds[0].text == text)
        await memory.store.close()
    }
}
