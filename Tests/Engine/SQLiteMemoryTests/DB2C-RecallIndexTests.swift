import Foundation
import Memory
import Testing

@testable import SQLiteMemory

@Suite("Schema 22 Recall index", .serialized)
struct DB2CRecallIndexTests {
    private let space = EmbeddingSpace(
        modelID: "synthetic", modelRevision: "1", weightsDigest: String(repeating: "a", count: 64),
        tokenizerDigest: String(repeating: "b", count: 64), dimensions: 2, pooling: "mean",
        queryPrefix: "query: ", documentPrefix: "document: ", maximumTokens: 16
    )

    @Test func generationsKeepPublicSpaceAndTerminalState() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let recall = SQLiteRecallRepository(store: store)
        try await recall.ensure(space: space, at: 1)
        try await recall.ensure(space: space, at: 2)
        let first = try await recall.startGeneration(format: .labelled, spaceID: space.spaceID, at: 3)
        #expect(first.spaceID == space.spaceID)
        #expect(try await recall.startGeneration(format: .contextual, spaceID: nil, at: 4) == first)
        #expect(try await recall.enumerate(first, pageSize: 10, at: 5).isEmpty)
        try await recall.promote(first.generationID, at: 6)
        let second = try await recall.startGeneration(format: .contextual, spaceID: nil, at: 7)
        try await recall.fail(second.generationID, reason: "synthetic failure", at: 8)
        try await recall.fail(second.generationID, reason: "retry", at: 9)
        #expect(try await recall.liveGenerations().map(\.generationID) == [first.generationID])
        #expect(try await recall.status().vectorBacklog == 0)
        await store.close()
    }

    @Test func equalTextAcrossFormatsSharesOneVectorAndKeepsBothDigests() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let recall = SQLiteRecallRepository(store: store)
        try await recall.ensure(space: space, at: 1)
        let text = "Same exact text."
        let first = SQLiteRecallRepository.digest(format: .labelled, text: text)
        let second = SQLiteRecallRepository.digest(format: .contextual, text: text)
        try await store.write { transaction in
            _ = try DB2CRecallIndexRows.document(transaction, format: .labelled, text: text, at: 2)
            _ = try DB2CRecallIndexRows.document(transaction, format: .contextual, text: text, at: 3)
        }
        let embedded = EmbeddedText(vector: [0.25, -0.75], tokenCount: 4, isTruncated: false)
        try await recall.store(vectors: [(first, embedded)], spaceID: space.spaceID, at: 4)
        try await recall.store(vectors: [(second, embedded)], spaceID: space.spaceID, at: 5)
        let vectors = try await recall.vectors(spaceID: space.spaceID, digests: [first, second, "absent"])
        #expect(vectors == [first: embedded.vector, second: embedded.vector])
        #expect(try await recall.vectors(spaceID: "absent", digests: [first]).isEmpty)
        #expect(try await store.read { snapshot in
            try snapshot.query("SELECT (SELECT count(*) FROM memory_recall_texts), (SELECT count(*) FROM memory_recall_documents), (SELECT count(*) FROM memory_recall_vectors)") {
                [$0.integer(0), $0.integer(1), $0.integer(2)]
            }.first
        } == [1, 2, 1])
        await #expect(throws: (any Error).self) {
            try await recall.store(vectors: [(first, EmbeddedText(vector: [1], tokenCount: 1, isTruncated: false))],
                                   spaceID: space.spaceID, at: 6)
        }
        #expect(try await recall.vectors(spaceID: space.spaceID, digests: [first])[first] == embedded.vector)
        await store.close()
    }

    @Test func failedGenerationCannotAdvanceItsCursor() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let recall = SQLiteRecallRepository(store: store)
        let generation = try await recall.startGeneration(format: .labelled, spaceID: nil, at: 1)
        try await recall.fail(generation.generationID, reason: "synthetic failure", at: 2)
        await #expect(throws: (any Error).self) { _ = try await recall.enumerate(generation, pageSize: 10, at: 3) }
        #expect(try await store.read { snapshot in
            try snapshot.query("SELECT enumerated FROM memory_recall_generations WHERE generation_id = ?", [.integer(generation.generationID)]) {
                $0.integer(0)
            }.first ?? nil
        } == 0)
        await store.close()
    }
}
