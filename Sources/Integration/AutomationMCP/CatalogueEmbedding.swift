import AutomationRuntime
import Capabilities
import Foundation
import LocalEmbedding
import Memory
import os

/// CatalogueEmbedding borrows the shared process service in the Recall embedding space.
/// A cold query starts loading and throws immediately, allowing BM25 to answer without waiting.
nonisolated public struct CatalogueEmbedding: Capabilities.TextEmbedding {
    public var modelID: String { source.space.spaceID }
    private let source: EmbeddingService.Source
    private let role: EmbeddingRole

    public init(source: EmbeddingService.Source, role: EmbeddingRole = .query) {
        self.source = source
        self.role = role
    }

    @concurrent
    public func vectors(for texts: [String]) async throws -> [[Float]] {
        let service = EmbeddingService.shared
        guard service.isLoaded else {
            service.prepare(.eager, source: source)
            throw EmbeddingService.Unavailable.notLoaded
        }
        if let failure = await service.ready(source) { throw failure }
        return try service.embed(texts, as: role, in: source.space).map(\.vector)
    }

    /// Keeps catalogue diagnostics with the catalogue inputs used by the shared embedding service.
    @concurrent
    static func prepareSearch(entries: [CatalogueEntry], supportDirectory: URL) async -> CapabilitySearch? {
        let log = Logger(subsystem: "dev.forte.Braus", category: "Capabilities")
        do {
            let search = try await prepareSearch(entries: entries, supportDirectory: supportDirectory,
                onEvent: { event in
                    log.debug("Capability search: \(String(describing: event), privacy: .private)")
                }, onCacheEvent: { event in
                    log.debug("Catalogue vectors: \(String(describing: event), privacy: .private)")
                })
            try Task.checkCancellation()
            return search
        } catch is CancellationError {
            log.debug("Catalogue preparation cancelled")
        } catch {
            log.error("Catalogue preparation failed: \(String(describing: error), privacy: .private)")
        }
        return nil
    }

    /// Prepares a replacement search off the main actor, reusing persistent document vectors.
    /// The composition starts this in its own task and keeps its initial BM25 search until it succeeds.
    /// Loading, inference and persistence errors propagate to that task's owner; query fallback stays available.
    @concurrent
    public static func prepareSearch(
        entries: [CatalogueEntry],
        supportDirectory: URL,
        onEvent: @escaping @Sendable (CapabilitySearch.Event) -> Void,
        onCacheEvent: @escaping @Sendable (CatalogueVectors.Event) -> Void
    ) async throws -> CapabilitySearch {
        let configuration = RecallConfiguration.resolved()
        guard let manifest = configuration.model, let directory = configuration.modelsDirectory else {
            return CapabilitySearch(entries: entries, onEvent: onEvent)
        }
        let source = EmbeddingService.Source(manifest: manifest,
            directory: directory.appendingPathComponent(manifest.directoryName))
        if let failure = await EmbeddingService.shared.ready(source) { throw failure }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let vectors = try await CatalogueVectors.prepare(
            entries: entries,
            embedding: CatalogueEmbedding(source: source, role: .document),
            file: CatalogueVectors.file(in: supportDirectory, modelID: source.space.spaceID),
            onEvent: onCacheEvent
        )
        return CapabilitySearch(entries: entries, vectors: vectors,
                                embedding: CatalogueEmbedding(source: source), onEvent: onEvent)
    }
}
