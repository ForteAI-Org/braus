//
//  RecallService.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Accelerate
import Foundation
import LocalEmbedding
import Memory
import OSLog
import SQLiteMemory
import Synchronization

/// RecallService is the Recall of one living memory: it keeps the derived index in line with the catalogue, and
/// answers a task's query with the one selection per need the D2 contracts support.
///
/// **Index.** The archive's triggers record index work with every write that changes what the catalogue offers.
/// A worker of this service takes it after the commit, in bounded passes: it enters each changed version's offered
/// parts in the live generations (short transactions, no model inside), computes the vectors of new documents off
/// this actor and outside any transaction, builds a new generation completely before making it current, and stops
/// between passes when the memory closes. A model, a tokenizer or a format other than the current generation's is a
/// new generation; the current one answers until the new one is complete. Work that keeps failing is left pending,
/// counted and said in the status, never dropped.
///
/// **Query.** Each need is searched with the task's values masked (`RecallText.masked`): values are bound, never
/// searched with. Every part of the current generation is scored exactly: the dot product with the query's vector, the
/// lexical coverage, or their combination. No approximate index stands between a query and a part, so no filter
/// applied after a shortlist can lose the right one. The best parts name the versions to read; the versions are read
/// from the authoritative tables, so a part retired, superseded or no longer admitted is not selectable whatever the
/// index holds; the selection is checked against the catalogue once more just before it is recorded. A search the
/// index cannot answer says so (`unavailable`, `failed`); one that answered with less than it should says what it
/// lacked (`limited`); neither is reported as nothing found.
///
/// **Use.** The calls an attempt makes after a delivery are linked to the delivered steps they carry out
/// (`RecallUseLinking`), and the agent's declared use is kept beside the links. Nothing here changes a part's
/// qualification or state: a reuse proves its own calls, not the source's.
public actor RecallService {

    /// IndexCache is the current generation's entries in memory: each part's document tokens and vector, read once,
    /// then kept in line with the generation by reading only what changed: when its revision moves, the entries of the
    /// versions with index work since the cache's mark; when vectors arrive, those of the documents still without one.
    /// Entries live in slots: a removed entry leaves its slot empty for the next one, so a change costs what changed, not
    /// the size of the index. The order of the slots means nothing: the ranking breaks ties by part id.
    struct IndexCache {
        let generation: SQLiteRecallRepository.Generation
        private(set) var revision: Int64
        /// The work mark of the snapshot the cache matches: the versions with work at or after it may have changed since.
        private(set) var mark: Int64
        /// The entries by slot, nil for an empty slot.
        private(set) var slots: [SQLiteRecallRepository.IndexEntry?]
        private(set) var tokens: [Set<String>]
        private(set) var byPart: [String: Int]
        private var byRoute: [String: [Int]]
        private var free: [Int]
        /// How many entries hold each token: the collection weighting's frequencies, kept as entries come and go.
        private var frequencies: [String: Int]
        private(set) var lexical: LexicalIndex
        /// For a lexical weighting by version, each version's index over its own entries.
        private(set) var versions: [String: LexicalIndex]
        private let weighting: LexicalIndex.Weighting
        /// How many slots hold an entry, and how many of those have their vector.
        private(set) var count: Int
        private(set) var vectorCount: Int
        /// The slots of the entries without a vector, by document.
        private var lacking: [String: Set<Int>]
        /// When the vectors of the entries already held were last read: what a later read of the computed ones waits on.
        private(set) var readAt: ContinuousClock.Instant

        init(_ generation: SQLiteRecallRepository.Generation, revision: Int64, mark: Int64, entries: [SQLiteRecallRepository.IndexEntry],
             weighting: LexicalIndex.Weighting) {
            self.generation  = generation
            self.revision    = revision
            self.mark        = mark
            self.weighting   = weighting
            slots = []; tokens = []; byPart = [:]; byRoute = [:]; free = []; frequencies = [:]; versions = [:]; lacking = [:]
            count = 0; vectorCount = 0
            lexical = LexicalIndex(frequencies: [:], count: 0, weighting: weighting)
            readAt = .now
            slots.reserveCapacity(entries.count)
            tokens.reserveCapacity(entries.count)
            byPart.reserveCapacity(entries.count)
            for entry in entries { insert(entry, tokens: Set(RecallText.tokens(entry.text))) }
            lexical = LexicalIndex(frequencies: frequencies, count: count, weighting: weighting)
            versions = Self.versionIndexes(slots: slots, tokens: tokens, routes: Array(byRoute.keys), byRoute: byRoute, weighting: weighting)
        }

        /// The documents of the generation still without a vector in its space.
        var missingVectors: Int { generation.spaceID == nil ? 0 : lacking.count }

        /// The digests of the documents still without a vector.
        var missingDigests: [String] { Array(lacking.keys) }

        /// The slots that hold an entry.
        var live: [Int] { slots.indices.filter { slots[$0] != nil } }

        /// Whether the entry in slot `a` ranks before the one in slot `b` for these scores: the higher score, then the
        /// smaller part id, so the ranking is the same whatever slots the entries are in.
        func precedes(_ a: Int, _ b: Int, by scores: [Double]) -> Bool {
            if scores[a] != scores[b] { return scores[a] > scores[b] }
            return (slots[a]?.partID ?? "").utf8.lexicographicallyPrecedes((slots[b]?.partID ?? "").utf8)
        }

        private mutating func insert(_ entry: SQLiteRecallRepository.IndexEntry, tokens set: Set<String>) {
            let slot: Int
            if let reused = free.popLast() {
                slot = reused
                slots[slot] = entry
                tokens[slot] = set
            } else {
                slot = slots.count
                slots.append(entry)
                tokens.append(set)
            }
            byPart[entry.partID] = slot
            byRoute[entry.routeID, default: []].append(slot)
            for token in set { frequencies[token, default: 0] += 1 }
            count += 1
            if entry.vector != nil { vectorCount += 1 } else { lacking[entry.digest, default: []].insert(slot) }
        }

        private mutating func remove(_ slot: Int) {
            guard let entry = slots[slot] else { return }
            for token in tokens[slot] {
                let left = (frequencies[token] ?? 0) - 1
                frequencies[token] = left > 0 ? left : nil
            }
            byPart[entry.partID] = nil
            if entry.vector != nil {
                vectorCount -= 1
            } else {
                lacking[entry.digest]?.remove(slot)
                if lacking[entry.digest]?.isEmpty == true { lacking[entry.digest] = nil }
            }
            slots[slot] = nil
            tokens[slot] = []
            free.append(slot)
            count -= 1
        }

        /// Replaces the entries of `routes` by `fresh` (those versions' entries now), at the revision and mark of the
        /// snapshot that read them.
        mutating func replace(routes: [String], with fresh: [SQLiteRecallRepository.IndexEntry], revision: Int64, mark: Int64) {
            for route in routes {
                for slot in byRoute[route] ?? [] { remove(slot) }
                byRoute[route] = nil
            }
            for entry in fresh { insert(entry, tokens: Set(RecallText.tokens(entry.text))) }
            lexical = LexicalIndex(frequencies: frequencies, count: count, weighting: weighting)
            if weighting == .version {
                for route in routes { versions[route] = nil }
                versions.merge(Self.versionIndexes(slots: slots, tokens: tokens, routes: routes, byRoute: byRoute, weighting: weighting)) { $1 }
            }
            self.revision = revision
            self.mark = mark
        }

        /// Gives the vectors computed since to the entries that lacked them.
        mutating func fill(_ vectors: [String: [Float]]) {
            for (digest, vector) in vectors {
                for slot in lacking[digest] ?? [] {
                    guard let entry = slots[slot] else { continue }
                    slots[slot] = entry.with(vector: vector)
                    vectorCount += 1
                }
                lacking[digest] = nil
            }
            readAt = .now
        }

        /// Each version's lexical index over its own entries, for the version weighting, for `routes`.
        private static func versionIndexes(slots: [SQLiteRecallRepository.IndexEntry?], tokens: [Set<String>], routes: [String],
                                           byRoute: [String: [Int]], weighting: LexicalIndex.Weighting) -> [String: LexicalIndex] {
            guard weighting == .version else { return [:] }
            var indexes: [String: LexicalIndex] = [:]
            for route in routes {
                guard let owned = byRoute[route], !owned.isEmpty else { continue }
                var frequencies: [String: Int] = [:]
                for slot in owned { for token in tokens[slot] { frequencies[token, default: 0] += 1 } }
                indexes[route] = LexicalIndex(frequencies: frequencies, count: owned.count, weighting: .version)
            }
            return indexes
        }
    }

    /// Refreshes counts, for the measures, how the index in memory was kept current: whole reads, reads of the versions
    /// that changed, reads of vectors, with their durations.
    package struct Refreshes: Sendable {
        package var whole: [Double] = []
        package var changed: [Double] = []
        package var changedVersions: [Int] = []
        package var vectors: [Double] = []
    }

    /// Status is what a diagnosis shows of the Recall in this process.
    public struct Status: Sendable {
        public let index: SQLiteRecallRepository.Status
        public let model: String?
        public let modelFailure: String?
        public let workerFailure: String?
        public let isWorking: Bool
    }

    nonisolated public let memory: MemoryService
    nonisolated public let configuration: RecallConfiguration
    private var embedder: (any TextEmbedding)?
    private var embedderFailure: String?
    private var embedderLoaded = false
    /// The one load of the model in progress: every caller waits for it, none sees a model half loaded.
    private var embedderLoading: Task<(any TextEmbedding)?, Never>?
    private var cache: IndexCache?
    private var refreshesIncrementally = true
    private var refreshes = Refreshes()
    /// The versions this worker entered since it last looked for documents without a vector among them, and whether the
    /// next look reads every entry (the first pass of a process, for what an earlier one left).
    private var vectorRoutes: Set<String> = []
    private var vectorScanWhole = true
    private var lastWholeVectorScan: ContinuousClock.Instant?
    private var tracksVectorWork = true
    private var worker: Task<Void, Never>?
    private var workWanted = false
    private var workerFailure: String?
    /// A test's seam between the search and the delivery's last check, for the package's tests only.
    private var beforeRecord: (@Sendable () async -> Void)?
    private var workPaused = false
    /// A test's seam that makes the index read fail, for the package's tests only.
    private var indexFault: (any Error)?

    private static let log = Logger(subsystem: "dev.forte.Mecum", category: "Recall")

    /// The most versions one need's search reads from the authoritative tables.
    static let versionLimit = 12
    /// How often a query reads the vectors computed since, while more than `vectorReadBound` documents still lack one.
    static let cacheRefresh: Duration = .seconds(2)
    /// Up to this many documents without a vector, a query reads those computed since at once: a small read. Above it
    /// (a whole generation being embedded), at most every `cacheRefresh`.
    static let vectorReadBound = 2_048
    /// The most versions a moved revision reads apart before the whole generation is read instead.
    static let refreshLimit = 2_000
    /// How often the worker reads every entry for documents without a vector, beyond those of the versions it entered.
    static let vectorScanInterval: Duration = .seconds(600)
    /// How long a query waits for the derived writes of the session's last calls before reading the state they show.
    static let observationFlush: Duration = .seconds(1)
    /// How old the latest observation of a session may be for a query to start from the state it showed.
    static let observationFreshnessMS: Int64 = 15 * 60 * 1000
    /// How much of the index work one pass of the worker takes.
    static let workBatch = 16
    static let enumerationPage = 32
    static let vectorBatch = 16
    /// Work that failed this many times is left pending and said in the status.
    static let workAttemptLimit = 3

    public init(memory: MemoryService, configuration: RecallConfiguration = .resolved(), embedder: (any TextEmbedding)? = nil) {
        self.memory        = memory
        self.configuration = configuration
        if let embedder {
            self.embedder       = embedder
            self.embedderLoaded = true
        }
    }

    // MARK: One service per memory

    private static let services = Mutex<[ObjectIdentifier: RecallService]>([:])

    /// The Recall of a memory for this process, made on first request with the process's configuration.
    public static func shared(for memory: MemoryService) -> RecallService {
        services.withLock { services in
            if let known = services[ObjectIdentifier(memory)] { return known }
            let made = RecallService(memory: memory)
            services[ObjectIdentifier(memory)] = made
            return made
        }
    }

    /// Replaces the Recall of a memory, for tests and the comparison that run another configuration or embedder.
    package static func install(_ service: RecallService) {
        services.withLock { $0[ObjectIdentifier(service.memory)] = service }
    }

    package static func forget(_ memory: MemoryService) {
        services.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(memory)) }
    }

    package func setBeforeRecord(_ gate: (@Sendable () async -> Void)?) { beforeRecord = gate }
    package func setIndexFault(_ fault: (any Error)?) { indexFault = fault }

    // MARK: The model

    /// The configured embedding space, known from the manifest alone; nil for a lexical configuration.
    nonisolated public var space: EmbeddingSpace? {
        configuration.channel == .lexical ? nil : configuration.model?.space
    }

    /// The model, loaded once off this actor; nil with the reason kept when it cannot be loaded. Concurrent callers
    /// wait for the same load.
    private func model() async -> (any TextEmbedding)? {
        if embedderLoaded { return embedder }
        if let embedderLoading { return await embedderLoading.value }
        guard let manifest = configuration.model, configuration.channel != .lexical else {
            embedderLoaded = true
            return nil
        }
        guard let directory = configuration.modelsDirectory?.appendingPathComponent(manifest.directoryName) else {
            embedderFailure = "no models folder is configured"
            embedderLoaded = true
            return nil
        }
        let loading = Task { () -> (any TextEmbedding)? in
            let loaded = await Task.detached { () -> Result<LocalEmbeddingModel, any Error> in
                Result { try LocalEmbeddingModel(manifest: manifest, directory: directory) }
            }.value
            return self.settle(loaded, manifest: manifest)
        }
        embedderLoading = loading
        return await loading.value
    }

    private func settle(_ loaded: Result<LocalEmbeddingModel, any Error>, manifest: EmbeddingModelManifest) -> (any TextEmbedding)? {
        switch loaded {
            case .success(let model):
                embedder = model
                Self.log.info("recall model \(manifest.modelID, privacy: .public) loaded in \(model.loadDuration, privacy: .public)")
            case .failure(let error):
                embedderFailure = String(describing: error)
                Self.log.error("recall model unavailable: \(self.embedderFailure ?? "", privacy: .public)")
        }
        embedderLoaded = true
        embedderLoading = nil
        return embedder
    }

    // MARK: The index

    /// Asks the worker to look at the index work, now or after the pass in progress.
    public func schedule() {
        workWanted = true
        guard worker == nil, !workPaused else { return }
        worker = Task { await self.runWorker() }
    }

    /// Whether the worker is held: it takes no index work while held (the triggers still queue it), and resumes what is
    /// wanted when released. For the measure that separates the index worker's contention from another producer's.
    package func holdWork(_ held: Bool) {
        workPaused = held
        if !held, workWanted, worker == nil { worker = Task { await self.runWorker() } }
    }

    /// Waits until the worker has nothing left to do, within a budget; true when it finished in time.
    @discardableResult
    public func waitUntilIdle(within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while worker != nil || (workWanted && !workPaused) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func runWorker() async {
        defer { worker = nil }
        while workWanted, !Task.isCancelled {
            workWanted = false
            do {
                while try await workPass() {
                    await Task.yield()
                    if Task.isCancelled { return }
                }
                workerFailure = nil
            } catch {
                workerFailure = MemoryService.describe(error)
                Self.log.error("recall index work stopped: \(self.workerFailure ?? "", privacy: .public)")
                return
            }
        }
    }

    /// One bounded pass over the index work; true when it did something and another pass may be useful.
    func workPass() async throws -> Bool {
        try await SQLiteMemoryStore.$operationLabel.withValue("recall index work") { try await indexWork() }
    }

    private func indexWork() async throws -> Bool {
        let now = memory.clock.calendarMS()
        let space = self.space
        if let space { try await memory.perform { try await $0.recall.ensure(space: space, at: now) } }
        var live = try await memory.perform { try await $0.recall.liveGenerations() }
        var did = false
        let owner = configuration.ownsIndex
        let wanted = { (generation: SQLiteRecallRepository.Generation) in
            owner && generation.format == self.configuration.format && generation.spaceID == space?.spaceID
        }
        // The owner's configuration decides the generations: one being built for another configuration is no longer
        // wanted, and one is started for this one. A guest decides none.
        if owner {
            for building in live where building.status == .building && !wanted(building) {
                try await memory.perform { try await $0.recall.abandon(building.generationID, reason: "configuration changed", at: now) }
                did = true
            }
            live = try await memory.perform { try await $0.recall.liveGenerations() }
            if !live.contains(where: wanted) {
                _ = try await memory.perform { try await $0.recall.startGeneration(format: self.configuration.format, spaceID: space?.spaceID, at: now) }
                live = try await memory.perform { try await $0.recall.liveGenerations() }
                did = true
            }
        }

        // The work the triggers recorded: a version entered again everywhere; the whole catalogue, a new generation, which
        // only the owner starts, so a guest leaves that work pending for it.
        let work = try await memory.perform { try await $0.recall.pendingWork(limit: Self.workBatch * 4) }
            .filter { $0.attempts < Self.workAttemptLimit && (owner || $0.routeID != nil) }.prefix(Self.workBatch)
        var done: [Int64] = []
        for item in work {
            do {
                if let route = item.routeID {
                    let generations = live
                    _ = try await memory.perform { try await $0.recall.sync(routeID: route, generations: generations, at: now) }
                    vectorRoutes.insert(route)
                } else if !live.contains(where: { $0.status == .building && wanted($0) }) {
                    _ = try await memory.perform {
                        try await $0.recall.startGeneration(format: self.configuration.format, spaceID: space?.spaceID, at: now)
                    }
                    live = try await memory.perform { try await $0.recall.liveGenerations() }
                }
                done.append(item.workID)
            } catch {
                try await memory.perform { try await $0.recall.failed(item.workID, reason: MemoryService.describe(error)) }
                throw error
            }
        }
        if !done.isEmpty {
            let finished = done
            try await memory.perform { try await $0.recall.complete(finished, at: now) }
            did = true
        }

        // A generation being built takes the next page of the catalogue.
        if let building = live.first(where: { $0.status == .building && wanted($0) }), !building.isEnumerated {
            let routes = try await memory.perform { try await $0.recall.enumerate(building, pageSize: Self.enumerationPage, at: now) }
            vectorRoutes.formUnion(routes)
            did = true
            live = try await memory.perform { try await $0.recall.liveGenerations() }
        }

        // Vectors of the documents that have none, computed off this actor and outside any transaction. The documents are
        // looked for among the versions this worker entered since (a sync, a page of a build); every entry is read at the
        // worker's first pass and at most every `vectorScanInterval` after, for what another process left (one stopped
        // between an entry and its vector). A look that finds fewer than a batch clears what it looked among.
        var missing: [(digest: String, text: String)] = []
        if let space, let model = await model() {
            let ids = live.filter { $0.spaceID == space.spaceID }.map(\.generationID)
            if let last = lastWholeVectorScan, last.duration(to: .now) >= Self.vectorScanInterval { vectorScanWhole = true }
            let whole = vectorScanWhole || !tracksVectorWork
            if whole { lastWholeVectorScan = .now }
            let routes = whole ? nil : Array(vectorRoutes)
            missing = try await MemoryService.labelled("recall index work: documents without a vector") {
                try await memory.perform {
                    try await $0.recall.documentsWithoutVector(spaceID: space.spaceID, generationIDs: ids, routes: routes, limit: Self.vectorBatch)
                }
            }
            if missing.count < Self.vectorBatch {
                if whole { vectorScanWhole = false }
                vectorRoutes.subtract(routes ?? [])
            }
            if !missing.isEmpty {
                let texts = missing.map(\.text)
                let vectors = try await Task.detached { try model.embed(texts, as: .document) }.value
                let pairs = zip(missing.map(\.digest), vectors).map { (digest: $0, embedded: $1) }
                try await memory.perform { try await $0.recall.store(vectors: pairs, spaceID: space.spaceID, at: now) }
                did = true
            }
        }

        // A complete generation becomes current; the first of an archive as soon as it is enumerated. Its backlog is counted
        // only once no document was found missing in this pass: while some are, it is not empty.
        if let building = live.first(where: { $0.status == .building && wanted($0) }), building.isEnumerated,
           missing.isEmpty || !tracksVectorWork {
            let hasReady = live.contains { $0.status == .ready }
            let backlog = try await MemoryService.labelled("recall index work: backlog") {
                try await memory.perform { try await $0.recall.vectorBacklog(of: building) }
            }
            if !hasReady || backlog == 0 || (space != nil && embedderLoaded && embedder == nil && !hasReady) {
                try await memory.perform { try await $0.recall.promote(building.generationID, requiringVectors: hasReady, at: now) }
                did = true
            }
        }
        return did
    }

    /// The current generation's entries in memory, kept current with what changed since they were read: the versions with
    /// index work when the revision moved, the vectors computed since (at once for a few documents, at most every
    /// `cacheRefresh` for many), the whole generation when it is another one or when more than `refreshLimit` versions
    /// changed. The cache is changed in place.
    private func currentCache() async throws -> IndexCache? {
        if let indexFault { throw indexFault }
        let live = try await memory.perform { try await $0.recall.liveGenerations() }
        guard let ready = live.first(where: { $0.status == .ready }) else {
            cache = nil
            return nil
        }
        let revision = try await memory.perform { try await $0.recall.revision(of: ready.generationID) }
        guard let held = cache, held.generation.generationID == ready.generationID, held.revision == revision || refreshesIncrementally else {
            return try await readWhole(ready)
        }
        if held.revision != revision {
            let started = ContinuousClock.now
            let mark = held.mark
            guard let changes = try await memory.perform({ try await $0.recall.changes(of: ready, since: mark, limit: Self.refreshLimit) }) else {
                return try await readWhole(ready)
            }
            cache?.replace(routes: changes.routes, with: changes.entries, revision: changes.revision, mark: changes.mark)
            refreshes.changed.append(Self.milliseconds(started.duration(to: .now)))
            refreshes.changedVersions.append(changes.routes.count)
        }
        if let current = cache, current.missingVectors > 0, let space = ready.spaceID,
           current.missingVectors <= Self.vectorReadBound || current.readAt.duration(to: .now) >= Self.cacheRefresh {
            let started = ContinuousClock.now
            let digests = current.missingDigests
            let found = try await memory.perform { try await $0.recall.vectors(spaceID: space, digests: digests) }
            cache?.fill(found)
            refreshes.vectors.append(Self.milliseconds(started.duration(to: .now)))
        }
        return cache
    }

    /// The whole generation read into memory.
    private func readWhole(_ ready: SQLiteRecallRepository.Generation) async throws -> IndexCache {
        let started = ContinuousClock.now
        let (revision, mark, entries) = try await memory.perform { try await $0.recall.entries(of: ready) }
        let made = IndexCache(ready, revision: revision, mark: mark, entries: entries, weighting: configuration.lexicalWeighting)
        cache = made
        refreshes.whole.append(Self.milliseconds(started.duration(to: .now)))
        return made
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// How this service kept its index in memory current so far, for the measures.
    package func refreshCounts() -> Refreshes { refreshes }

    /// Whether a moved revision reads only the versions that changed (the default) or the whole generation, for the
    /// measures that compare the two.
    package func refreshIncrementally(_ incremental: Bool) { refreshesIncrementally = incremental }

    /// Whether the worker looks for documents without a vector among the versions it entered (the default) or among every
    /// entry at each pass, for the measures that compare the two.
    package func trackVectorWork(_ tracked: Bool) { tracksVectorWork = tracked }

    /// The parts, documents and vector presence of the index in memory now, read current, for the tests that compare a
    /// cache kept current with one read whole.
    package func cachedEntries() async throws -> [(partID: String, digest: String, hasVector: Bool)] {
        guard let cache = try await currentCache() else { return [] }
        return cache.slots.compactMap { $0 }.sorted { $0.partID.utf8.lexicographicallyPrecedes($1.partID.utf8) }
            .map { ($0.partID, $0.digest, $0.vector != nil) }
    }

    // MARK: Query

    /// Answer is a query's delivery and its record, with how long its phases took.
    public struct Answer: Sendable {
        public let delivery: RecallDelivery
        public let recorded: SQLiteRecallRepository.RecordedQuery
        public let phases: Phases
    }

    /// Phases are the durations of one query's work, for the measures: the query's embedding, the exact scoring
    /// of the index, the reading of the versions from the authoritative tables, the selection, the last check, the
    /// record. Each is measured on the monotonic clock of this process.
    public struct Phases: Sendable, Equatable {
        /// The index's status and its entries in memory brought current.
        public var index: Duration = .zero
        public var embedding: Duration = .zero
        public var scoring: Duration = .zero
        public var reading: Duration = .zero
        public var selection: Duration = .zero
        public var checking: Duration = .zero
        public var recording: Duration = .zero
    }

    /// Prepared is a query searched and its versions read, before the selection: what a selection under any
    /// thresholds needs, so the comparison can select again without searching again.
    package struct Prepared: Sendable {
        let status: SQLiteRecallRepository.Status
        let cache: IndexCache?
        package let channel: RecallChannel
        package let searchStatus: SearchStatus
        package let notes: [String]
        package let needs: [RecallNeed]
        /// The task's values, constraints and observed state every need's selection reads.
        package let context: RecallSelector.Context
        let scores: [[Double]]
        package let sources: [RecallSource]
        package let considered: Int
        var phases: Phases
    }

    /// Searches for the request's needs and reads the versions the best parts belong to; `observed` is the state the
    /// latest observation of the task's session showed, when the facts know one.
    package func prepare(_ request: RecallRequest, observed: Set<ObservedState> = []) async throws -> Prepared {
        var phases = Phases()
        let begun = ContinuousClock.now
        let context = RecallSelector.Context(values: request.values, constraints: request.constraints, observed: observed,
                                             needs: request.searchedNeeds)
        // The status without counting the generation's entries or vectors: the index in memory has both.
        let light = try await memory.perform { try await $0.recall.queryStatus() }
        var status = light
        var notes: [String] = []
        let needs = request.searchedNeeds
        let cache: IndexCache?
        do {
            cache = try await currentCache()
            if let cache {
                status = SQLiteRecallRepository.Status(generations: light.generations, pendingWork: light.pendingWork,
                                                       entries: cache.count, vectorBacklog: cache.missingVectors)
            }
        } catch {
            notes.append("the index could not be read (\(MemoryService.describe(error)))")
            return Prepared(status: status, cache: nil, channel: .none, searchStatus: .failed, notes: notes, needs: needs,
                            context: context, scores: [], sources: [], considered: 0, phases: phases)
        }
        guard let cache else {
            let building = status.generations.contains { $0.status == .building }
            notes.append(building ? "the index is being built and has no complete generation yet" : "no index exists yet")
            return Prepared(status: status, cache: nil, channel: .none, searchStatus: .unavailable, notes: notes, needs: needs,
                            context: context, scores: [], sources: [], considered: 0, phases: phases)
        }
        phases.index = begun.duration(to: .now)
        // The channel that can answer now: the configured one, or the lexical one when vectors are missing.
        var searchStatus = SearchStatus.completed
        let model = configuration.channel == .lexical ? nil : await model()
        let hasVectors = cache.vectorCount > 0 && model != nil && cache.generation.spaceID == model?.space.spaceID
        let channel: RecallChannel = switch configuration.channel {
            case .lexical : .lexical
            case .semantic: hasVectors ? .semantic : .lexical
            case .hybrid  : hasVectors ? .hybrid : .lexical
        }
        if !configuration.ownsIndex,
           cache.generation.format != configuration.format || (configuration.channel != .lexical && cache.generation.spaceID != space?.spaceID) {
            searchStatus = .limited
            notes.append("the index was built for the archive's own configuration (\(cache.generation.format.rawValue)"
                         + (cache.generation.spaceID.map { ", \($0)" } ?? ", lexical") + "); this process's configuration answered over it")
        }
        if configuration.channel != .lexical, !hasVectors {
            searchStatus = .limited
            notes.append("the semantic index is unavailable (\(embedderFailure ?? "no vector computed yet")); the lexical index answered")
        } else if cache.vectorCount < cache.count, configuration.channel != .lexical {
            searchStatus = .limited
            notes.append("\(cache.count - cache.vectorCount) parts are not embedded yet and were scored lexically")
        }
        if status.pendingWork > 0 {
            searchStatus = .limited
            notes.append("\(status.pendingWork) changes of the catalogue are not in the index yet")
        }
        var clock = ContinuousClock.now
        // The task's values are bound, never searched with: each need is searched with them masked.
        let searched = needs.map { RecallText.masked($0.text, values: request.values) }
        let vectors: [[Float]?]
        if channel != .lexical, let model {
            vectors = try await Task.detached { try model.embed(searched, as: .query) }.value.map(\.vector)
        } else {
            vectors = needs.map { _ in nil }
        }
        phases.embedding = clock.duration(to: .now)
        clock = .now
        let thresholds = configuration.thresholds(for: channel)
        var scores: [[Double]] = []
        var routes: [String] = []
        var considered = 0
        for (index, need) in needs.enumerated() {
            let needScores = score(text: searched[index], vector: vectors[index], cache: cache, channel: channel)
            scores.append(needScores)
            // A need bound to an application excludes, before any cut, the parts that run in another one: the selector
            // could select none of their steps.
            let live = cache.live
            let eligible = need.bundleID.map { bundle in
                live.filter { cache.slots[$0]?.bundleID == nil || cache.slots[$0]?.bundleID == bundle }
            } ?? live
            let ranked = eligible.sorted { cache.precedes($0, $1, by: needScores) }.prefix(RecallContract.candidateLimit)
            considered += ranked.count
            let relevant = eligible.filter { needScores[$0] >= thresholds.absolute }
            if relevant.count > RecallContract.candidateLimit {
                if searchStatus == .completed { searchStatus = .limited }
                notes.append("more parts were relevant than the \(RecallContract.candidateLimit) a need considers")
            }
            var mine: [String] = []
            for entry in ranked.compactMap({ cache.slots[$0] }) where !mine.contains(entry.routeID) && mine.count < Self.versionLimit {
                mine.append(entry.routeID)
            }
            let relevantVersions = Set(relevant.compactMap { cache.slots[$0]?.routeID })
            if relevantVersions.subtracting(mine).count > 0 {
                if searchStatus == .completed { searchStatus = .limited }
                notes.append("\(relevantVersions.count) versions were relevant to a need and the \(Self.versionLimit) best were read")
            }
            for route in mine where !routes.contains(route) { routes.append(route) }
        }
        phases.scoring = clock.duration(to: .now)
        clock = .now
        let wanted = routes
        let sources = try await memory.perform { try await $0.recall.sources(wanted) }
        phases.reading = clock.duration(to: .now)
        return Prepared(status: status, cache: cache, channel: channel, searchStatus: searchStatus, notes: notes, needs: needs,
                        context: context, scores: scores, sources: sources, considered: considered, phases: phases)
    }

    /// The selection of every need of a prepared query under `thresholds` (the configuration's for its channel when nil).
    package nonisolated func outcomes(_ prepared: Prepared, thresholds: SelectionThresholds? = nil) -> [NeedOutcome] {
        guard let scored = scored(prepared) else {
            return prepared.needs.enumerated().map {
                NeedOutcome(position: $0.offset, need: $0.element, coverage: .unknown, reason: nil, selected: nil, alternatives: [])
            }
        }
        let thresholds = thresholds ?? configuration.thresholds(for: prepared.channel)
        return prepared.needs.enumerated().map { index, need in
            RecallSelector.select(position: index, need: need, sources: scored[index], context: prepared.context, thresholds: thresholds)
        }
    }

    /// The versions a prepared query read, each with the relevance of its offered parts to each need; nil when the
    /// search could not answer.
    package nonisolated func scored(_ prepared: Prepared) -> [[ScoredSource]]? {
        guard let cache = prepared.cache, prepared.searchStatus != .failed, prepared.searchStatus != .unavailable else { return nil }
        return prepared.needs.indices.map { index in
            let scores = prepared.scores[index]
            return prepared.sources.map { source -> ScoredSource in
                var steps: [Int: Double] = [:]
                var parts: [String: Double] = [:]
                for part in source.parts where part.isOffered {
                    guard let at = cache.byPart[part.partID] else { continue }
                    parts[part.partID] = scores[at]
                    if part.kind == .step { steps[part.firstPosition] = scores[at] }
                }
                return ScoredSource(source: source, stepRelevance: steps, partRelevance: parts)
            }
        }
    }

    /// The entries the search scored highest for one need of a prepared query, best first: for the comparison's
    /// measure of the candidates, before any selection.
    package nonisolated func ranked(_ prepared: Prepared, need: Int, limit: Int) -> [(partID: String, routeID: String, score: Double)] {
        guard let cache = prepared.cache, prepared.scores.indices.contains(need) else { return [] }
        let scores = prepared.scores[need]
        return cache.live.sorted { cache.precedes($0, $1, by: scores) }.prefix(limit).compactMap { slot in
            cache.slots[slot].map { ($0.partID, $0.routeID, scores[slot]) }
        }
    }

    /// Searches for the request's needs, selects, records the query and answers its delivery.
    public func recall(_ request: RecallRequest, producer: TaskProducer) async throws -> Answer {
        let started = ContinuousClock.now
        let queryID = UUID().uuidString
        // The state the session shows now, from the facts: the derived writes of its last calls first, within a budget.
        _ = await memory.flush(within: Self.observationFlush)
        let since = memory.clock.calendarMS() - Self.observationFreshnessMS
        let observed = try await memory.perform { try await $0.recall.observedState(of: producer.source, stream: producer.streamID, since: since) }
        var prepared = try await prepare(request, observed: observed.map { [$0] } ?? [])
        var clock = ContinuousClock.now
        var outcomes = outcomes(prepared)
        prepared.phases.selection = clock.duration(to: .now)
        if prepared.cache != nil {
            if let beforeRecord { await beforeRecord() }
            clock = .now
            // The last check: every selected step is still offered, or the versions are read again and selected again.
            for attempt in 0..<2 {
                let byRoute = Dictionary(uniqueKeysWithValues: prepared.sources.map { ($0.routeID, $0) })
                let selected = outcomes.compactMap(\.selected).flatMap { selection in
                    (byRoute[selection.routeID]?.steps ?? []).filter { selection.positions.contains($0.position) }.map(\.partID)
                }
                let still = try await memory.perform { try await $0.recall.offered(selected) }
                if Set(selected).isSubset(of: still) || attempt == 1 { break }
                let routes = prepared.sources.map(\.routeID)
                let reread = try await memory.perform { try await $0.recall.sources(routes) }
                prepared = Prepared(status: prepared.status, cache: prepared.cache, channel: prepared.channel,
                                    searchStatus: prepared.searchStatus, notes: prepared.notes, needs: prepared.needs,
                                    context: prepared.context, scores: prepared.scores, sources: reread, considered: prepared.considered,
                                    phases: prepared.phases)
                outcomes = self.outcomes(prepared)
            }
            prepared.phases.checking = clock.duration(to: .now)
        }
        let sources = Dictionary(uniqueKeysWithValues: prepared.sources.map { ($0.routeID, $0) })
        let coverage = NeedOutcome.overall(outcomes)
        let note = prepared.notes.isEmpty ? nil : prepared.notes.joined(separator: "; ")
        var state = coverage == .absent || coverage == .unknown ? "nothing" : "delivered"
        var delivery = deliver(queryID: queryID, request: request, outcomes: outcomes, sources: sources, status: prepared.status,
                               channel: prepared.channel, searchStatus: prepared.searchStatus, note: note,
                               considered: prepared.considered, generation: prepared.cache?.generation, state: state)
        var bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        if bytes > RecallContract.channelLimitBytes {
            state = "not_delivered"
            delivery = deliver(queryID: queryID, request: request, outcomes: outcomes, sources: sources, status: prepared.status,
                               channel: prepared.channel, searchStatus: prepared.searchStatus, note: note,
                               considered: prepared.considered, generation: prepared.cache?.generation, state: state)
            bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        }
        let elapsed = started.duration(to: .now)
        let recorded = SQLiteRecallRepository.RecordedQuery(
            queryID: queryID, request: request, producer: producer,
            generationID: prepared.channel == .none ? nil : prepared.cache?.generation.generationID, channel: prepared.channel,
            searchStatus: prepared.searchStatus,
            searchNote: prepared.searchStatus == .completed ? nil : (note ?? prepared.searchStatus.rawValue),
            candidatesConsidered: prepared.considered, coverage: coverage, delivery: state, deliveryBytes: bytes,
            durationUS: elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000,
            needs: outcomes
        )
        let at = memory.clock.calendarMS()
        clock = .now
        try await memory.perform { try await $0.recall.record(recorded, at: at) }
        prepared.phases.recording = clock.duration(to: .now)
        return Answer(delivery: delivery, recorded: recorded, phases: prepared.phases)
    }

    /// The relevance of every entry of the cache to the text a need is searched with, in the channel's scale.
    nonisolated func score(text: String, vector: [Float]?, cache: IndexCache, channel: RecallChannel) -> [Double] {
        let query = Set(RecallText.tokens(text)).sorted()
        // An empty slot scores below anything: it is never eligible.
        let lexical = cache.versions.isEmpty ? zip(cache.slots, cache.tokens).map { $0 == nil ? -.infinity : cache.lexical.score(sorted: query, document: $1) }
            : zip(cache.slots, cache.tokens).map { entry, document in
                entry.map { (cache.versions[$0.routeID] ?? cache.lexical).score(sorted: query, document: document) } ?? -.infinity
            }
        guard channel != .lexical, let vector else { return lexical }
        var semantic = [Double](repeating: 0, count: cache.slots.count)
        var byDigest: [String: Double] = [:]
        vector.withUnsafeBufferPointer { query in
            for (index, slot) in cache.slots.enumerated() {
                guard let entry = slot, let stored = entry.vector, stored.count == query.count else { semantic[index] = .nan; continue }
                if let known = byDigest[entry.digest] {
                    semantic[index] = known
                    continue
                }
                var dot: Float = 0
                stored.withUnsafeBufferPointer { vDSP_dotpr(query.baseAddress!, 1, $0.baseAddress!, 1, &dot, vDSP_Length(query.count)) }
                semantic[index] = Double(dot)
                byDigest[entry.digest] = Double(dot)
            }
        }
        switch channel {
            case .semantic:
                return zip(semantic, lexical).map { $0.isNaN ? $1 * 0 : $0 }
            default:
                let weight = configuration.hybridWeight
                return zip(semantic, lexical).map { $0.isNaN ? $1 : (1 - weight) * $0 + weight * $1 }
        }
    }

    // MARK: Delivery

    private func deliver(queryID: String, request: RecallRequest, outcomes: [NeedOutcome], sources: [String: RecallSource],
                         status: SQLiteRecallRepository.Status, channel: RecallChannel, searchStatus: SearchStatus, note: String?,
                         considered: Int, generation: SQLiteRecallRepository.Generation?, state: String) -> RecallDelivery {
        // `nothing`: no selection to deliver; `not_delivered`: selections too large for the channel, withheld.
        let delivered = state != "not_delivered"
        let candidates = RecallBinding.candidates(request.values)
        let indexStatus: String = switch (generation, status.generations.contains { $0.status == .building }) {
            case (.some, _): "ready"
            case (nil, true): "building"
            case (nil, false): searchStatus == .failed ? "failed" : "unavailable"
        }
        let needs = outcomes.map { outcome -> RecallDelivery.Need in
            let selection = delivered ? outcome.selected.flatMap { selection in
                sources[selection.routeID].map {
                    Self.render(selection, source: $0, candidates: candidates, values: request.values, constraints: request.constraints)
                }
            } : nil
            let alternatives = outcome.alternatives.isEmpty ? nil : outcome.alternatives.compactMap { alternative -> RecallDelivery.Alternative? in
                guard let source = sources[alternative.routeID] else { return nil }
                let labels = source.steps.filter { alternative.positions.contains($0.position) }.compactMap(\.label)
                return RecallDelivery.Alternative(version: source.routeID, procedure: source.procedureLabel,
                                                  steps: "\(alternative.firstPosition + 1)–\(alternative.lastPosition + 1)",
                                                  labels: Array(labels.prefix(6)))
            }
            let excluded = outcome.excluded.isEmpty ? nil : outcome.excluded.compactMap { exclusion -> RecallDelivery.Excluded? in
                guard let source = sources[exclusion.routeID] else { return nil }
                let labels = source.steps.filter { exclusion.positions.contains($0.position) }.compactMap(\.label)
                let why = exclusion.requirements.map { requirement -> String in
                    let step = (requirement.stepPosition ?? 0) + 1
                    switch requirement.kind {
                        case .certainConflict:
                            return "step \(step) fixes a choice that the task's \(requirement.taskValueName ?? "value") contradicts"
                        default:
                            let text = requirement.constraintPosition.flatMap { request.constraints.indices.contains($0) ? request.constraints[$0] : nil }
                            return "step \(step) does what a constraint forbids: \(text ?? "a constraint")"
                    }
                }
                return RecallDelivery.Excluded(version: source.routeID, procedure: source.procedureLabel,
                                               steps: "\(exclusion.firstPosition + 1)–\(exclusion.lastPosition + 1)",
                                               labels: Array(labels.prefix(6)), why: why)
            }
            var need = RecallDelivery.Need(need: outcome.need.text, app: outcome.need.bundleID, coverage: outcome.coverage.rawValue,
                                           reason: outcome.reason?.rawValue, selection: selection, alternatives: alternatives,
                                           excluded: excluded)
            if !outcome.unaccounted.isEmpty { need.unaccounted = outcome.unaccounted }
            if let left = outcome.leftOut {
                need.leftOut = "steps \(left.lowerBound + 1)–\(left.upperBound + 1) of this method are named by the need but not delivered: "
                    + "steps of another application it does not ask for lie between them and this selection"
            }
            return need
        }
        let readVersions = Set(outcomes.compactMap { $0.selected?.routeID } + outcomes.flatMap { $0.alternatives.map(\.routeID) })
        return RecallDelivery(
            query   : queryID,
            reason  : request.reason.rawValue,
            revision: request.revision,
            index   : RecallDelivery.Index(status: indexStatus, generation: generation?.generationID,
                                           model: generation?.spaceID == nil ? nil : configuration.model?.modelID,
                                           backlog: status.vectorBacklog, pendingWork: status.pendingWork,
                                           note: embedderFailure.map { "semantic model: \($0)" }),
            search  : RecallDelivery.Search(status: searchStatus.rawValue, channel: channel.rawValue, partsConsidered: considered,
                                            versionsRead: max(sources.count, readVersions.count), note: note),
            coverage: NeedOutcome.overall(outcomes).rawValue,
            delivery: state,
            needs   : needs,
            guidance: delivered ? RecallDelivery.guidance
                : "The selected details exceed what one answer can carry, so none of them is given. Ask again with fewer or narrower needs."
        )
    }

    /// The part that produced, in the source, the value a missing input took, as its attempts state it (review F10): named
    /// when the selection does not include it, so the agent prepares it or chooses it, without the work between them. When
    /// the task already holds that output, the input is derived from it.
    static func dependency(of parameter: RecallSource.Parameter, in source: RecallSource, candidates: [RecallBinding.Value]) -> String? {
        guard let feed = source.feed(of: parameter), let part = feed.output.producedBy.flatMap({ id in source.parts.first { $0.partID == id } })
        else { return nil }
        let steps = part.firstPosition == part.lastPosition ? "step \(part.firstPosition + 1)" : "steps \(part.firstPosition + 1)–\(part.lastPosition + 1)"
        if case .bound(let value, _) = RecallBinding.bind(feed.output, among: candidates) {
            return "derive it from \(value.name), which the task holds: in the source it was derived from {\(feed.output.name)}"
        }
        return "{\(feed.output.name)}, produced in the source by part \(part.partID)" + (part.label.map { " (\($0))" } ?? "")
            + " at \(steps), which this selection does not include: produce it first"
    }

    /// A selection with every detail the agent needs to use it.
    static func render(_ selection: RecallSelection, source: RecallSource, candidates: [RecallBinding.Value],
                       values: [TaskValue], constraints: [String]) -> RecallDelivery.Selection {
        let parameters = Dictionary(uniqueKeysWithValues: source.parameters.map { ($0.parameterID, $0) })
        func name(_ id: String) -> String { parameters[id]?.name ?? id }
        let roles: [AgentTool: [String: String]] = [
            .act: ["target": "element"], .select: ["control": "element"], .typeText: ["target": "element"],
            .scroll: ["target": "element"], .drag: ["from": "element", "to": "element"], .contextMenu: ["target": "element"],
        ]
        let steps = source.steps.filter { selection.positions.contains($0.position) }.map { step -> RecallDelivery.Step in
            let arguments = step.arguments.map { argument -> RecallDelivery.Argument in
                let kind = roles[step.tool]?[argument.name] ?? "fixed"
                switch argument.value {
                    case .literal(let value):
                        let text: String = switch value {
                            case .text(let text): text
                            case .integer(let number): String(number)
                            case .real(let number): String(number)
                            case .boolean(let flag): String(flag)
                        }
                        return RecallDelivery.Argument(name: argument.name, value: text, kind: kind)
                    case .parameter(let id):
                        return RecallDelivery.Argument(name: argument.name, value: "{\(name(id))}", kind: "parameter")
                    case .template(let segments):
                        let text = segments.map { segment -> String in
                            switch segment {
                                case .literal(let text): text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
                                case .parameter(let id): "{\(name(id))}"
                            }
                        }.joined()
                        return RecallDelivery.Argument(name: argument.name, value: text, kind: "parameter")
                    case .anchor(let id): return RecallDelivery.Argument(name: argument.name, value: id, kind: "element")
                    case .menu(let path): return RecallDelivery.Argument(name: argument.name, value: path, kind: "fixed")
                }
            }
            return RecallDelivery.Step(step: step.position + 1, label: step.label, app: step.bundleID.map(RecallDocument.applicationName),
                                       tool: step.tool.rawValue, arguments: arguments, verifiedAs: nil)
        }
        var rendered: [RecallDelivery.Parameter] = []
        var conditions: [RecallDelivery.Condition] = []
        for requirement in selection.requirements {
            let step = requirement.stepPosition.map { $0 + 1 }
            switch requirement.kind {
                case .parameterBound, .parameterMissing, .parameterAmbiguous:
                    guard let id = requirement.parameterID, let parameter = parameters[id] else { continue }
                    let value = requirement.taskValueName.flatMap { taken in candidates.first { $0.name == taken } }
                    let secret = requirement.taskValueName.flatMap { taken in values.first { $0.name == taken }?.sensitivity } == .secret
                    let status = requirement.kind == .parameterBound ? "bound" : requirement.kind == .parameterMissing ? "missing" : "ambiguous"
                    var item = RecallDelivery.Parameter(name: parameter.name, role: parameter.role, kind: parameter.kind.rawValue,
                                                        status: status, value: secret ? "[withheld]" : value?.text,
                                                        from: requirement.taskValueName, match: requirement.bindingMatch?.rawValue,
                                                        candidates: requirement.candidates.isEmpty ? nil : requirement.candidates)
                    if requirement.kind == .parameterMissing { item.producedBy = Self.dependency(of: parameter, in: source, candidates: candidates) }
                    rendered.append(item)
                case .entryState:
                    let app = requirement.bundleID.map(RecallDocument.applicationName) ?? "the application"
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step, detail: requirement.sceneID == nil
                        ? "start in \(app) where step \(step ?? 0) began in the source; that state was not recognized, observe it"
                        : "start in \(app) in the state step \(step ?? 0) began from in the source (open the application or document as needed, then observe)"))
                case .applicationSwitch:
                    let app = requirement.bundleID.map(RecallDocument.applicationName) ?? "the next application"
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "before step \(step ?? 0), the source switched to \(app): open or focus it with the task's document"))
                case .unknownEntryState:
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "what step \(step ?? 0) needs on screen was not recorded: earlier steps of the source may be needed; observe and prepare"))
                case .prerequisiteOutOfCatalogue:
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "step \(step ?? 0) of the source prepares this selection but is not offered by the catalogue: prepare that state yourself"))
                case .compatibilityUnknown:
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "the source made this choice with another value: check that the application offers the task's value"))
                case .unboundTaskInput:
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "the task still lacks \(requirement.taskValueName ?? "a value") and step \(step ?? 0) fixes this choice: resolve "
                            + "the value first; if it differs, this method does not fit"))
                case .observedState:
                    let app = requirement.bundleID.map(RecallDocument.applicationName) ?? "the application"
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "your latest observation showed \(app) in the state step \(step ?? 0) began from in the source: continue from it; "
                            + "the source's steps that reached it are not repeated, so if the screen changed, prepare it again. The observation "
                            + "shows the state, not which document it is for: check it is the task's"))
                case .preparedBefore:
                    let app = requirement.bundleID.map(RecallDocument.applicationName) ?? "the application"
                    let block = source.block(of: requirement.stepPosition ?? 0)
                    let label = source.step(requirement.stepPosition ?? 0)?.label.map { " (last: \($0))" } ?? ""
                    // The data those steps read that the task does not give: what preparing them again would need.
                    let lacking = (block.lowerBound...(requirement.stepPosition ?? block.lowerBound)).flatMap { source.step($0)?.parameterIDs ?? [] }
                        .filter { id in
                            guard let parameter = parameters[id] else { return false }
                            if case .bound = RecallBinding.bind(parameter, among: candidates) { return false }
                            return true
                        }
                    let names = Array(NSOrderedSet(array: lacking.map(name))).compactMap { $0 as? String }
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "in the source, steps \(block.lowerBound + 1)–\(step ?? 0) in \(app) came before this selection\(label): the request "
                            + "does not name them and no fact says whether what they left (an item created, an edit, a field filled) is in place; "
                            + "check it, and prepare it if it is not" + (names.isEmpty ? "" : " (they read \(names.map { "{\($0)}" }.joined(separator: ", ")), "
                            + "which the task does not give)")))
                case .inputProduced:
                    let input = requirement.parameterID.map(name) ?? "an input"
                    // The relation as the source's attempt stated it: the output, whether the input was it or a value derived
                    // from it, and the part that produced it.
                    let feed = requirement.parameterID.flatMap { id in source.parameters.first { $0.parameterID == id } }.flatMap(source.feed(of:))
                    let producer = feed?.output.producedBy.flatMap { id in source.parts.first { $0.partID == id } }
                    let relation = feed.map { $0.isSame ? "it was {\($0.output.name)}" : "it was derived from {\($0.output.name)}" } ?? "it came"
                    let part = producer.map { " by part \($0.partID)" + ($0.label.map { " (\($0))" } ?? "") } ?? ""
                    // In a choice the producer may be in an earlier tract of the same version.
                    let holder = requirement.stepPosition.map(selection.positions.contains) ?? true ? "this selection" : "an earlier tract of this plan"
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "the task has no value for {\(input)}: in the source's attempt \(relation), produced\(part) from step \(step ?? 0), "
                            + "which \(holder) includes; produce it there"))
                case .outputReady:
                    let output = requirement.parameterID.map(name) ?? "an output"
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: step,
                        detail: "the task already holds \(requirement.taskValueName ?? "it") for {\(output)}, which the source produced from step "
                            + "\(step ?? 0): that part is not repeated"))
                case .constraintUnchecked:
                    let text = requirement.constraintPosition.flatMap { constraints.indices.contains($0) ? constraints[$0] : nil } ?? ""
                    conditions.append(RecallDelivery.Condition(kind: requirement.kind.rawValue, step: nil,
                        detail: "the Recall does not check this constraint against the steps: \(text)"))
                case .certainConflict, .constraintExcluded:
                    continue
            }
        }
        let whole = selection.wholePartID.flatMap { id in source.parts.first { $0.partID == id } }
        let evidence = (whole != nil ? "qualified as a whole part" : "a tract of individually qualified steps, not qualified as a whole")
            + " (qualification A: each operation's own check, not the task's result)"
            + (source.confirmedUses > 0 ? "; carried out and verified in \(source.confirmedUses) earlier reuse(s)" : "")
        return RecallDelivery.Selection(version: source.routeID, procedure: source.procedureLabel, wholePart: whole?.label, steps: steps,
                                        parameters: rendered, conditions: conditions, evidence: evidence)
    }

    // MARK: Diagnosis

    /// Scored is one part's relevance to a text in a diagnosis.
    public struct Scored: Sendable {
        public let partID: String
        public let kind: PartKind
        public let text: String
        public let semantic: Double?
        public let lexical: Double
        public let combined: Double
    }

    /// Every part of the current generation scored against a text, the most relevant first, for diagnosis: no query
    /// is recorded and nothing is selected.
    public func explain(_ text: String, limit: Int = 20) async throws -> (channel: RecallChannel, parts: [Scored]) {
        guard let cache = try await currentCache() else { return (.none, []) }
        _ = try RecallNeed(text: text)
        let model = configuration.channel == .lexical ? nil : await model()
        let vector = try model.map { try $0.embed([text], as: .query)[0].vector }
        let channel: RecallChannel = vector == nil ? .lexical : (configuration.channel == .semantic ? .semantic : .hybrid)
        let combined = score(text: text, vector: vector, cache: cache, channel: channel)
        let lexical = score(text: text, vector: nil, cache: cache, channel: .lexical)
        let semantic = vector.map { score(text: text, vector: $0, cache: cache, channel: .semantic) }
        let order = cache.live.sorted { cache.precedes($0, $1, by: combined) }.prefix(limit)
        return (channel, order.compactMap { index in
            guard let entry = cache.slots[index] else { return nil }
            return Scored(partID: entry.partID, kind: entry.kind, text: entry.text, semantic: semantic?[index], lexical: lexical[index],
                          combined: combined[index])
        })
    }

    // MARK: Use

    /// LinkSummary is what the linking found for one need of one query.
    public struct LinkSummary: Sendable, Equatable {
        public let queryID: String
        public let needPosition: Int
        /// The tract of a choice's need (its selection's position); nil for a query's one selection.
        public let tract: Int?
        public let executed: [Int]
        public let confirmed: [Int]
        public let notExecuted: [Int]
        public let ownOperations: Int
        /// Of the agent's own operations, those that may have carried out a step: the facts cannot tell.
        public let undetermined: Int
    }

    /// Links the attempt's calls to the steps of the selections delivered to it, each call to the latest query
    /// delivered before it started, and answers what each need's selection was used for. The facts a link reads (the
    /// call's state before it, the element the Brain identified) are derived after the call: the caller flushes the
    /// memory's queue first, and a fact not yet derived only leaves a link unproven.
    public func link(attemptID: String, taskID: String, producer: TaskProducer) async throws -> [LinkSummary] {
        let selections = try await memory.perform { try await $0.recall.selections(ofAttempt: attemptID) }
        guard !selections.isEmpty else { return [] }
        // Each query's values are the ones of the revision it was made under, never a later revision's.
        var revisions: [Int: [RecallBinding.Value]] = [:]
        for number in Set(selections.map(\.taskRevision)) {
            let content = try await memory.perform { try await $0.tasks.revision(number, of: taskID, for: producer) }
            revisions[number] = RecallBinding.candidates(content?.content.inputs ?? [])
        }
        let queries = Array(NSOrderedSet(array: selections.map(\.queryID))).compactMap { $0 as? String }
        let routes = Array(Set(selections.map(\.routeID)))
        let sources = Dictionary(uniqueKeysWithValues: try await memory.perform { try await $0.recall.sources(routes) }.map { ($0.routeID, $0) })
        var summaries: [LinkSummary] = []
        let now = memory.clock.calendarMS()
        for (index, query) in queries.enumerated() {
            let mine = selections.filter { $0.queryID == query }
            guard let from = mine.first?.recordedAtMS else { continue }
            let until = queries.indices.contains(index + 1) ? selections.first { $0.queryID == queries[index + 1] }?.recordedAtMS : nil
            var calls = try await memory.perform { try await $0.recall.calls(ofAttempt: attemptID, after: from) }
            if let until {
                let later = Set(try await memory.perform { try await $0.recall.calls(ofAttempt: attemptID, after: until) }.map(\.eventID))
                calls = calls.filter { !later.contains($0.eventID) }
            }
            var remaining = calls
            for (offset, selection) in mine.enumerated() {
                guard let source = sources[selection.routeID] else { continue }
                let steps = source.steps.filter { (selection.firstPosition...selection.lastPosition).contains($0.position) }
                var values: [String: String] = [:]
                let candidates = revisions[selection.taskRevision] ?? []
                for (parameter, taken) in selection.bindings {
                    if let text = candidates.first(where: { $0.name == taken })?.text { values[parameter] = text }
                }
                let links = RecallUseLinking.link(steps: steps, calls: remaining, values: values)
                // A call that carried out no step of this need may carry out one of the next need's.
                let matched = links.filter { $0.stepPosition != nil }
                let isLast = offset == mine.count - 1
                let kept = isLast ? links : matched
                _ = try await memory.perform {
                    try await $0.recall.link(queryID: query, needPosition: selection.needPosition, selectionPosition: selection.selectionPosition,
                                             isChoice: selection.isChoice, links: kept, at: now)
                }
                let used = Set(matched.map(\.callEventID))
                remaining = remaining.filter { !used.contains($0.eventID) }
                let executed = matched.compactMap(\.stepPosition)
                summaries.append(LinkSummary(queryID: query, needPosition: selection.needPosition,
                                             tract: selection.isChoice ? selection.selectionPosition : nil, executed: executed,
                                             confirmed: matched.filter(\.confirmed).compactMap(\.stepPosition),
                                             notExecuted: steps.map(\.position).filter { !executed.contains($0) },
                                             ownOperations: isLast ? links.filter { $0.stepPosition == nil }.count : 0,
                                             undetermined: isLast ? links.filter(\.undetermined).count : 0))
            }
        }
        return summaries
    }

    /// Records the agent's declared use of a need's selection.
    public func report(queryID: String, attemptID: String, needPosition: Int, declared: String, cause: String?, note: String?) async throws {
        guard let count = try await memory.perform({ try await $0.recall.needCount(queryID: queryID, attemptID: attemptID) }),
              (0..<count).contains(needPosition) else {
            throw RecallUseError.unknownQuery(queryID)
        }
        let at = memory.clock.calendarMS()
        try await memory.perform { try await $0.recall.report(queryID: queryID, needPosition: needPosition, declared: declared, cause: cause,
                                                              note: note, at: at) }
    }

    /// The Recall's state in this process.
    public func status() async throws -> Status {
        let index = try await memory.perform { try await $0.recall.status() }
        return Status(index: index, model: space == nil ? nil : configuration.model?.modelID, modelFailure: embedderFailure,
                      workerFailure: workerFailure, isWorking: worker != nil)
    }
}

/// RecallUseError is a use report the Recall refuses.
nonisolated public enum RecallUseError: Error, Equatable {
    /// No query with this id was made by this attempt, or it has no need at that position.
    case unknownQuery(String)
}
