import Capabilities
import Foundation
import Synchronization
import Testing

@Suite
struct LexicalFallbackTests {
    @Test func noVectorsNeverCallsOrWaitsForTheModel() async {
        let model = SuspendedTextEmbedding()
        let entries = [searchEntry("scroll", examples: ["Scorri la lista"]), searchEntry("other")]
        let events = Mutex<[CapabilitySearch.Event]>([])
        let search = CapabilitySearch(entries: entries, vectors: nil, embedding: model,
                                      onEvent: { event in events.withLock { $0.append(event) } })
        let old = CapabilitySearch(entries: entries)
        for query in ["scroll", "scorri lista", "unknown", "", "the"] {
            #expect(await search.search(query, limit: 5) == old.search(query, limit: 5))
        }
        #expect(await model.calls == 0)
        #expect(events.withLock { $0.contains(.lexicalFallback(.noVectors)) })
    }

    @Test func failedModelPreservesExactLexicalScoresAndReportsReason() async throws {
        let entries = [searchEntry("scroll"), searchEntry("other")]
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: CountingTextEmbedding())
        let events = Mutex<[CapabilitySearch.Event]>([])
        let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: FailingTextEmbedding(),
                                      onEvent: { event in events.withLock { $0.append(event) } })
        #expect(await search.search("scroll", limit: 5) == CapabilitySearch(entries: entries).search("scroll", limit: 5))
        #expect(events.withLock { $0.contains { if case .lexicalFallback(.embeddingFailed) = $0 { true } else { false } } })
    }

    @Test @MainActor func mixedSearchSuspendsWithoutBlockingTheMainActor() async throws {
        let entries = [searchEntry("scroll"), searchEntry("other")]
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: CountingTextEmbedding())
        let model = SuspendedTextEmbedding()
        let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: model)
        let completed = Mutex(false)
        let task = Task { @MainActor in
            let result = await search.search("unseen paraphrase", limit: 5)
            completed.withLock { $0 = true }
            return result
        }
        await model.waitForCall()
        #expect(!completed.withLock { $0 })
        let progressed = await Task { @MainActor in true }.value
        #expect(progressed)
        await model.release()
        #expect(!(await task.value).isEmpty)
    }
}
