@testable import Capabilities
import Foundation
import Testing

@Suite
struct HybridSearchTests {
    @Test func semanticMatchesNeedNoSharedWordsAndTiesAreStable() async throws {
        let entries = [searchEntry("zeta"), searchEntry("alpha"), searchEntry("beta")]
        let model = CountingTextEmbedding()
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: model)
        let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: model)
        #expect(await search.search("unseen paraphrase", limit: 5).map(\.id.rawValue) == ["alpha", "beta", "zeta"])
        #expect(await search.search("unseen paraphrase", limit: 1).count == 1)
        let calls = await model.textCount
        #expect(await search.search("", limit: 5).isEmpty)
        #expect(await search.search("unseen paraphrase", limit: 0).isEmpty)
        #expect(await model.textCount == calls)
    }

    @Test func irrelevantAbsoluteSimilarityCannotBecomeAConfidentMatch() async throws {
        let entries = [searchEntry("alpha"), searchEntry("beta")]
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: CountingTextEmbedding())
        let search = CapabilitySearch(entries: entries, vectors: vectors,
                                      embedding: CountingTextEmbedding(output: [0.01, 1]))
        #expect(await search.search("unrelated question", limit: 5).isEmpty)
    }

    @Test func mismatchedOrIncompleteVectorsUseTheOriginalIndex() async throws {
        let entry = searchEntry("scroll")
        let vectors = try await CatalogueVectors.prepare(entries: [entry], embedding: CountingTextEmbedding())
        let entries = [entry, searchEntry("other")]
        let old = CapabilitySearch(entries: entries)
        for model in [CountingTextEmbedding(), CountingTextEmbedding(modelID: "different")] {
            let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: model)
            #expect(await search.search("scroll", limit: 5) == old.search("scroll", limit: 5))
            #expect(await model.textCount == 0)
        }
    }

    @Test func wrongQueryDimensionsFallBackInsteadOfTruncatingCosine() async throws {
        let entries = [searchEntry("scroll")]
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: CountingTextEmbedding())
        let search = CapabilitySearch(entries: entries, vectors: vectors,
                                      embedding: CountingTextEmbedding(output: [1]))
        #expect(await search.search("scroll", limit: 5) == CapabilitySearch(entries: entries).search("scroll", limit: 5))
    }
}
