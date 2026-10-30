//
//  HumanInterventionEmbeddings.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import Foundation
import LocalEmbedding
import Memory
import Synchronization

/// HumanInterventionEmbeddings owns one episode's bounded inference and caches its outcome, including fallback.
/// Loading and inference run off the main actor. A deadline stops waiting, and cancellation is checked between
/// synchronous model calls; a call already executing may finish later, but its vectors are discarded.
actor HumanInterventionEmbeddings {

    nonisolated struct Result: Sendable {
        let actionVectors: [[Float]]
        let effectVectors: [[Float]]
        let mode: String
        let elapsedMilliseconds: Double
        /// Why linking fell back to the deterministic rules; nil when embedding succeeded.
        var reason: String? = nil
        /// The model the vectors come from, "id@revision"; nil without vectors.
        var model: String? = nil
    }

    /// The model the report ranks causes with: Granite 107m (no query or passage prefixes), the one the attribution
    /// floor was calibrated on. It is pinned here, whatever channel or model the Recall uses.
    nonisolated static let manifest = EmbeddingModelManifest.graniteEmbedding107MMultilingual
    nonisolated static let modelIdentity = identity(of: manifest.space)

    nonisolated static func identity(of space: EmbeddingSpace) -> String { "\(space.modelID)@\(space.modelRevision)" }

    nonisolated private struct Request: Sendable, Equatable {
        let actions: [String]
        let effects: [String]
    }

    nonisolated private struct Text: Hashable {
        let value: String
        let role: EmbeddingRole
    }

    /// ModelCache shares one immutable model across episodes. Every caller awaits the same load, which may start
    /// before any episode needs it (`prepare`) and keeps running past an episode's deadline for later episodes.
    nonisolated final class ModelCache: Sendable {

        private let loader: @Sendable () throws -> (any TextEmbedding)?
        private let loading = Mutex<Task<(any TextEmbedding)?, Never>?>(nil)

        init(loader: @escaping @Sendable () throws -> (any TextEmbedding)?) {
            self.loader = loader
        }

        /// Starts the load without waiting for it.
        func prepare() {
            _ = load()
        }

        func model() async -> (any TextEmbedding)? {
            await load().value
        }

        private func load() -> Task<(any TextEmbedding)?, Never> {
            loading.withLock { loading in
                if let loading { return loading }
                let loader = self.loader
                // A missing or refused installation stays unavailable until the process restarts.
                let task = Task.detached(priority: .utility) { (try? loader()) ?? nil }
                loading = task
                return task
            }
        }
    }

    /// The pinned model from the shared models folder; only the folder comes from the recall configuration. The
    /// synchronized cache retains at most one model; installing another revision requires a process restart.
    nonisolated private static let installedModel: ModelCache = {
        let directory = RecallConfiguration.resolved().modelsDirectory
        return ModelCache {
            guard let directory else { return nil }
            return try LocalEmbeddingModel(manifest: manifest, directory: directory.appendingPathComponent(manifest.directoryName))
        }
    }()

    private let loader: @Sendable () async throws -> (any TextEmbedding)?
    private var operation: (request: Request, task: Task<Result, Never>)?

    init(loader: @escaping @Sendable () async throws -> (any TextEmbedding)?) {
        self.loader = loader
    }

    /// Loads the pinned model in the background, so the episode's digest does not pay for it.
    nonisolated static func prepareLocal() {
        installedModel.prepare()
    }

    /// Uses the pinned model shared across episodes, without downloading missing files.
    nonisolated static func local() -> HumanInterventionEmbeddings {
        HumanInterventionEmbeddings { await installedModel.model() }
    }

    /// Embeds at most 96 texts of 1,024 UTF-8 bytes each, about 3 ms a text once the model is loaded. The first accepted request owns the episode's job;
    /// changed input falls back instead of starting overlapping work. Callers log the returned mode and duration.
    func vectors(
        actions: [String],
        effects: [String],
        timeout: Duration = .seconds(1)
    ) async -> Result {
        let start = ContinuousClock.now
        guard actions.count <= 96, effects.count <= 96 - actions.count,
              (actions + effects).allSatisfy({ $0.utf8.count <= 1_024 }) else {
            return Self.fallback(since: start, "\(actions.count) actions and \(effects.count) effects exceed the bounds")
        }
        let request = Request(actions: actions, effects: effects)
        if let operation {
            guard operation.request == request else { return Self.fallback(since: start, "changed input") }
            return await operation.task.value
        }
        let loader = self.loader
        let task = Task.detached {
            await Self.run(
                request,
                loader: loader,
                timeout: max(.zero, min(timeout, .seconds(1))),
                start: start
            )
        }
        operation = (request, task)
        return await task.value
    }

    nonisolated private static func run(
        _ request: Request,
        loader: @escaping @Sendable () async throws -> (any TextEmbedding)?,
        timeout: Duration,
        start: ContinuousClock.Instant
    ) async -> Result {
        guard timeout > .zero, !request.actions.isEmpty, !request.effects.isEmpty else {
            return fallback(since: start, "nothing to embed")
        }
        let (stream, continuation) = AsyncStream<Result>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let resolved = Mutex(false)
        let complete: @Sendable (Result) -> Void = { result in
            let isFirst = resolved.withLock { resolved in
                guard !resolved else { return false }
                resolved = true
                return true
            }
            guard isFirst else { return }
            let outcome = start.duration(to: .now) > timeout ? fallback(since: start, "deadline") : result
            continuation.yield(outcome)
            continuation.finish()
        }
        let worker = Task.detached {
            let result = await infer(request, loader: loader, start: start)
            guard !Task.isCancelled else { return }
            complete(result)
        }
        let deadline = Task.detached {
            do {
                try await ContinuousClock().sleep(until: start.advanced(by: timeout))
                complete(fallback(since: start, "deadline"))
            } catch {
                // Cancellation means inference finished before the deadline.
            }
        }
        defer {
            worker.cancel()
            deadline.cancel()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? fallback(since: start, "cancelled")
    }

    nonisolated private static func infer(
        _ request: Request,
        loader: @Sendable () async throws -> (any TextEmbedding)?,
        start: ContinuousClock.Instant
    ) async -> Result {
        do {
            try Task.checkCancellation()
            guard let model = try await loader(), (1...4_096).contains(model.space.dimensions) else {
                return fallback(since: start, "model unavailable")
            }
            var cache: [Text: [Float]] = [:]
            func vectors(_ texts: [String], role: EmbeddingRole) throws -> [[Float]] {
                try texts.map { text in
                    try Task.checkCancellation()
                    let key = Text(value: text, role: role)
                    if let vector = cache[key] { return vector }
                    let embedded = try model.embed([text], as: role)
                    guard embedded.count == 1, let vector = embedded.first?.vector,
                          vector.count == model.space.dimensions,
                          vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                        throw InvalidVector()
                    }
                    try Task.checkCancellation()
                    cache[key] = vector
                    return vector
                }
            }
            let actions = try vectors(request.actions, role: .document)
            let effects = try vectors(request.effects, role: .query)
            return Result(
                actionVectors: actions,
                effectVectors: effects,
                mode: "embedding",
                elapsedMilliseconds: milliseconds(since: start),
                model: identity(of: model.space)
            )
        } catch {
            // Missing files, refused models and cancellation all leave deterministic linking available.
            return fallback(since: start, String(describing: error))
        }
    }

    nonisolated private struct InvalidVector: Error {}

    nonisolated private static func fallback(since start: ContinuousClock.Instant, _ reason: String) -> Result {
        Result(
            actionVectors: [],
            effectVectors: [],
            mode: "deterministic",
            elapsedMilliseconds: milliseconds(since: start),
            reason: reason
        )
    }

    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
