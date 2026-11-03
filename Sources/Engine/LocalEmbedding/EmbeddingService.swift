import Foundation
import Memory
import OSLog
import Synchronization

/// EmbeddingService owns the process's model behind a mutex. Callers retain adapters and borrow the
/// model only during synchronous inference. Loading belongs to the service and survives caller cancellation.
public final class EmbeddingService: Sendable {
    public static let shared = EmbeddingService { source in
        do {
            let model = try LocalEmbeddingModel(manifest: source.manifest, directory: source.directory)
            Logger(subsystem: "com.braus", category: "EmbeddingService").info(
                "embedding model \(source.manifest.modelID, privacy: .public) loaded in \(model.loadDuration, privacy: .public)"
            )
            return model
        } catch LocalEmbeddingModel.Failure.missingFile {
            throw Unavailable.notInstalled
        }
    }

    public enum Warmth: Sendable { case eager, lazy }
    public enum Unavailable: Error, Sendable, Equatable {
        case differentModel, notInstalled, notLoaded, failed(String)
    }

    /// Source names the model and its own directory. The first registered space wins for this service's lifetime.
    public struct Source: Sendable, Equatable {
        public let manifest: EmbeddingModelManifest
        public let directory: URL
        public var space: EmbeddingSpace { manifest.space }

        public init(manifest: EmbeddingModelManifest, directory: URL) {
            self.manifest = manifest
            self.directory = directory
        }
    }

    private struct State {
        var source: Source?
        var model: (any TextEmbedding)?
        var loading: Task<Unavailable?, Never>?
        var failure: Unavailable?
        var inferences = 0
        var releasePending = false
    }

    private let state = Mutex(State())
    private let loader: @Sendable (Source) async throws -> any TextEmbedding

    package init(loader: @escaping @Sendable (Source) async throws -> any TextEmbedding) {
        self.loader = loader
    }

    /// Records the source; eager starts a service-owned load and returns without waiting.
    public func prepare(_ warmth: Warmth, source: Source) {
        state.withLock { state in
            guard register(source, in: &state) else { return }
            if warmth == .eager { _ = startLoad(in: &state) }
        }
    }

    /// Waits for the shared load. A ready request cancels a deferred release, including during loading.
    public func ready(_ source: Source) async -> Unavailable? {
        let pending: Task<Unavailable?, Never>? = state.withLock { state in
            guard register(source, in: &state) else { return nil }
            state.releasePending = false
            return startLoad(in: &state)
        }
        if let pending { return await pending.value }
        return state.withLock { state in
            if state.source?.space != source.space { return .differentModel }
            return state.failure
        }
    }

    /// Runs one inference without loading. A release between ready and this call throws notLoaded.
    public func embed(_ texts: [String], as role: EmbeddingRole, in space: EmbeddingSpace) throws -> [EmbeddedText] {
        var borrowed: (any TextEmbedding)? = try state.withLock { state in
            if let source = state.source, source.space != space { throw Unavailable.differentModel }
            guard let model = state.model else { throw Unavailable.notLoaded }
            state.inferences += 1
            return model
        }
        defer {
            // Drop the borrowed reference before allowing another load after a deferred release.
            borrowed = nil
            state.withLock { state in
                state.inferences -= 1
                if state.inferences == 0, state.releasePending { discard(in: &state) }
            }
        }
        return try infer(borrowed, texts: texts, role: role)
    }

    private func infer(_ model: (any TextEmbedding)?, texts: [String], role: EmbeddingRole) throws -> [EmbeddedText] {
        guard let model else { throw Unavailable.notLoaded }
        return try model.embed(texts, as: role)
    }

    /// Returns an adapter that retains the service, never the model. Call ready before every use.
    public func embedding(for space: EmbeddingSpace) -> any TextEmbedding {
        Adapter(service: self, space: space)
    }

    /// Releases the model, or defers until loading and active inferences finish. Returns the manifest's
    /// weight bytes on immediate release, zero otherwise; this is not a measurement of resident memory.
    @discardableResult
    public func release() -> Int {
        state.withLock { state in
            guard state.inferences == 0, state.loading == nil else {
                state.releasePending = true
                return 0
            }
            let bytes = state.model == nil ? 0 : state.source?.manifest.weightsBytes ?? 0
            discard(in: &state)
            return bytes
        }
    }

    public var isLoaded: Bool { state.withLock { $0.model != nil } }

    private func register(_ source: Source, in state: inout State) -> Bool {
        if let first = state.source { return first.space == source.space }
        state.source = source
        return true
    }

    private func startLoad(in state: inout State) -> Task<Unavailable?, Never>? {
        if let loading = state.loading { return loading }
        guard state.model == nil, state.failure == nil, let source = state.source else { return nil }
        let task = Task.detached(priority: .utility) { [self] in
            let failure = await load(source)
            self.state.withLock { state in
                state.failure = failure
                state.loading = nil
                if state.releasePending, state.inferences == 0 { discard(in: &state) }
            }
            return failure
        }
        state.loading = task
        return task
    }

    // The load's local reference ends before loading is cleared, so release cannot overlap two models.
    private func load(_ source: Source) async -> Unavailable? {
        do {
            let model = try await loader(source)
            guard model.space == source.space else { return .differentModel }
            state.withLock { $0.model = model }
            return nil
        } catch let error as Unavailable {
            return error
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func discard(in state: inout State) {
        state.model = nil
        state.releasePending = false
    }

    private struct Adapter: TextEmbedding {
        let service: EmbeddingService
        let space: EmbeddingSpace
        func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
            try service.embed(texts, as: role, in: space)
        }
    }
}
