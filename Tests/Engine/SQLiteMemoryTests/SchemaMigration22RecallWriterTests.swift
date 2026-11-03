import Memory
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 Recall writer identity")
struct SchemaMigration22RecallWriterTests {
    @Test
    func currentWriterRetainsEqualTextAcrossSupportedFormats() async throws {
        let memory = try await ProcedureRepositoryTests.populated()
        let (_, route) = try await ProcedureRepositoryTests.interpreted(memory)
        let recall = SQLiteRecallRepository(store: memory.store)
        let labelled = try await recall.startGeneration(format: .labelled, spaceID: nil, at: 1)
        _ = try await recall.enumerate(labelled, pageSize: 100, at: 2)
        try await recall.promote(labelled.generationID, requiringVectors: false, at: 3)
        let contextual = try await recall.startGeneration(format: .contextual, spaceID: nil, at: 4)
        _ = try await recall.sync(routeID: route, generations: [contextual], at: 5)
        let equalTexts = try await memory.store.read { snapshot in
            try snapshot.query("""
                SELECT a.text FROM memory_recall_documents a JOIN memory_recall_documents b ON a.text=b.text
                WHERE a.document_format='recall-document-1' AND b.document_format='recall-document-1c'
                """) { try $0.text(0) ?? "" }
        }
        #expect(!equalTexts.isEmpty)
        #expect(try await recall.liveGenerations().count == 2)
        await memory.store.close()
    }
}
