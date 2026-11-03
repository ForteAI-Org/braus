import AutomationMCP
@testable import AutomationRuntime
import Foundation
import LocalEmbedding
import Memory
import Testing

@MainActor
@Suite("Recall promotion after model release", .serialized)
struct RecallPromotionTests {
    @Test func releaseAfterInferenceDoesNotPermitMissingVectors() async throws {
        var configuration = RecallLifecycleTests.configuration(.hybrid)
        configuration.modelsDirectory = URL(fileURLWithPath: "/unused")
        let service = EmbeddingService(loader: { _ in RecallLifecycleTests.HashedEmbedding() })
        let source = EmbeddingService.Source(
            manifest: try #require(configuration.model),
            directory: URL(fileURLWithPath: "/unused")
        )
        let recall = RecallService(
            memory: MemoryService.shared(for: try W.directory()),
            configuration: configuration,
            embeddingService: service
        )
        _ = try await recall.workPass()
        #expect(await service.ready(source) == nil)
        _ = try service.embed(["an indexed document"], as: .document, in: source.space)
        _ = service.release()
        #expect(!service.isLoaded)
        #expect(await recall.canPromote(backlog: 1, hasReady: false) == false)
        #expect(await recall.canPromote(backlog: 0, hasReady: false))
        #expect(await recall.canPromote(backlog: 1, hasReady: true) == false)
    }

    @Test func unavailableModelKeepsFirstLexicalGenerationFallback() async throws {
        var configuration = RecallLifecycleTests.configuration(.hybrid)
        configuration.modelsDirectory = URL(fileURLWithPath: "/unused")
        let recall = RecallService(
            memory: MemoryService.shared(for: try W.directory()),
            configuration: configuration,
            embeddingService: EmbeddingService(loader: { _ in throw EmbeddingService.Unavailable.notInstalled })
        )
        _ = try await recall.workPass()
        #expect(await recall.canPromote(backlog: 1, hasReady: false))
        #expect(await recall.canPromote(backlog: 1, hasReady: true) == false)
    }
}
