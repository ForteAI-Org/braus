import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

@Suite("Frozen projection cache")
struct ProjectionCacheTests {
    private typealias F = BrainFixtures

    private func frozen(_ labels: [String] = ["Save", "Open"]) async throws -> SQLiteMemoryStore {
        let memory = try await F.open()
        _ = try await memory.brain.ingest(F.scene(labels), into: F.bundle, now: F.t0, window: nil)
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".frozen")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        return store
    }

    @Test func stoppedCompletedLoadNeverPublishes() async throws {
        let store = try await frozen()
        let cache = ProjectionCache()
        let control = BrainReadControl()
        var repository = SQLiteBrainRepository(store: store, projectionCache: cache)
        repository.beforeProjectionPublication = { control.requestStop() }
        await #expect(throws: CancellationError.self) {
            try await BrainReadControl.$current.withValue(control) {
                _ = try await repository.indexedProjection(of: F.bundle, for: [])
            }
        }
        #expect(cache.statistics.cachedBytes == 0)
        #expect(cache.statistics.indexBuilds == 0)
        await store.close()
    }

    @Test(arguments: [false, true])
    func uncacheableProjectionIsNotLoadedAgain(punctuation: Bool) async throws {
        let store = try await frozen(punctuation ? ["✓", "✓", "✓"] : ["Save", "Open"])
        let cache = ProjectionCache(byteLimit: punctuation ? 8 * 1024 * 1024 : 1024)
        let repository = SQLiteBrainRepository(store: store, projectionCache: cache)
        let elements = [F.element("live", "Save", x: 0.5, y: 0.1)]
        let detections = elements.map(BrainDetection.init)
        let first = try #require(try await repository.indexedProjection(of: F.bundle, for: detections))
        let second = try #require(try await repository.indexedProjection(of: F.bundle, for: detections))
        #expect(first.enrich(elements) == second.enrich(elements))
        #expect(cache.statistics.loads == 1)
        #expect(cache.statistics.indexBuilds == 1)
        #expect(cache.statistics.cachedBytes <= cache.byteLimit)
        await store.close()
    }

    @Test func sameStoreSameAppReusesIndex() async throws {
        let store = try await frozen()
        let cache = ProjectionCache()
        let first = SQLiteBrainRepository(store: store, projectionCache: cache)
        let second = SQLiteBrainRepository(store: store, projectionCache: cache)
        let a = try #require(try await first.indexedProjection(of: F.bundle, for: F.scene(["Save"])))
        let b = try #require(try await second.indexedProjection(of: F.bundle, for: F.scene(["Open"])))
        #expect(a === b)
        #expect(cache.statistics.hits == 1)
        #expect(cache.statistics.loads == 1)
        #expect(cache.statistics.indexBuilds == 1)
        #expect(cache.statistics.cachedBytes > 0)
        await store.close()
        #expect(cache.statistics.cachedBytes == 0)
    }

    @Test func differentDetectionsMatchUncached() async throws {
        let (memory, _) = try await ProjectionSliceTests.populated()
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".frozen")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let cache = ProjectionCache()
        let cached = SQLiteBrainRepository(store: store, projectionCache: cache)
        let uncached = SQLiteBrainRepository(store: store, projectionCache: ProjectionCache(byteLimit: 0))
        let scenes = [ProjectionSliceTests.scene(), [F.element("other", "Screen 31 item 4", x: 0.3, y: 0.3)],
                      [F.element("unknown", "Unseen", x: 0.1, y: 0.2)], []]
        for elements in scenes {
            let detections = elements.map(BrainDetection.init)
            let a = try #require(try await cached.indexedProjection(of: F.bundle, for: detections))
            let b = try #require(try await uncached.indexedProjection(of: F.bundle, for: detections))
            let old = try #require(try await cached.projection(of: F.bundle, for: detections))
            #expect(a.enrich(elements) == b.enrich(elements))
            #expect(b.enrich(elements) == old.enrich(elements, affordances: false))
        }
        #expect(cache.statistics.indexBuilds == 1)
        await store.close()
    }

    @Test func punctuationLabelsKeepExistingSliceBehavior() async throws {
        let store = try await frozen(["✓", "✓", "✓"])
        let cache = ProjectionCache()
        let repository = SQLiteBrainRepository(store: store, projectionCache: cache)
        let whole = try #require(try await repository.brain(of: F.bundle))
        #expect(!whole.groups.isEmpty)
        let elements = [F.element("live", "Live caption", x: 0.5, y: 0.1)]
        let detections = elements.map(BrainDetection.init)
        let old = try #require(try await repository.projection(of: F.bundle, for: detections))
        let current = try #require(try await repository.indexedProjection(of: F.bundle, for: detections))
        #expect(old.enrich(elements, affordances: false).first?.group == nil)
        #expect(current.enrich(elements) == old.enrich(elements, affordances: false))
        #expect(cache.statistics.cachedBytes == 0)
        await store.close()
    }

    @Test func samePathNewArchiveNeverReuses() async throws {
        let store = try await frozen(["Old"])
        let replacement = try await frozen(["New"])
        let cache = ProjectionCache()
        let old = try #require(try await SQLiteBrainRepository(store: store, projectionCache: cache)
            .indexedProjection(of: F.bundle, for: []))
        let path = store.url
        let source = replacement.url
        await store.close()
        await replacement.close()
        try FileManager.default.removeItem(at: path)
        try FileManager.default.copyItem(at: source, to: path)
        let reopened = SQLiteMemoryStore(url: path, schema: .version22)
        try await reopened.open()
        let new = try #require(try await SQLiteBrainRepository(store: reopened, projectionCache: cache)
            .indexedProjection(of: F.bundle, for: []))
        #expect(old !== new)
        #expect(new.brain.objects.map(\.label) == ["New"])
        await reopened.close()
    }

    @Test func storeReopenAndRollbackInvalidate() async throws {
        enum Refusal: Error { case expected }
        let store = try await frozen()
        let cache = ProjectionCache()
        let repository = SQLiteBrainRepository(store: store, projectionCache: cache)
        let old = try #require(try await repository.indexedProjection(of: F.bundle, for: []))
        await #expect(throws: Refusal.expected) {
            try await store.write { _ in throw Refusal.expected }
        }
        #expect(cache.statistics.cachedBytes == 0)
        let new = try #require(try await repository.indexedProjection(of: F.bundle, for: []))
        #expect(old !== new)
        #expect(old.brain == new.brain)
        await store.close()
        await #expect(throws: MemoryStoreError.self) {
            _ = try await repository.indexedProjection(of: F.bundle, for: [])
        }
        let reopened = SQLiteMemoryStore(url: store.url, schema: .version22)
        try await reopened.open()
        let after = try #require(try await SQLiteBrainRepository(store: reopened, projectionCache: cache)
            .indexedProjection(of: F.bundle, for: []))
        #expect(after !== new)
        await reopened.close()
    }

    @Test func sameEpochDoesNotAuthorizeReuse() async throws {
        let memory = try await F.open()
        let cache = ProjectionCache()
        let repository = SQLiteBrainRepository(store: memory.store, projectionCache: cache)
        _ = try await memory.brain.ingest(F.scene(["Old"]), into: F.bundle, now: F.t0, window: nil)
        let before = try #require(try await repository.indexedProjection(of: F.bundle, for: F.scene(["Old"])))
        let epoch = try await memory.load()?.ingestEpoch
        _ = try await memory.brain.ingest(F.scene(["New"]), into: F.bundle, now: F.t0, window: nil)
        #expect(try await memory.load()?.ingestEpoch == epoch)
        let after = try #require(try await repository.indexedProjection(of: F.bundle, for: F.scene(["New"])))
        #expect(before !== after)
        #expect(after.brain.objects.contains { $0.label == "New" })
        #expect(cache.statistics.cachedBytes == 0)
        await memory.store.close()
    }

    @Test func mutableProjectionBypassesCache() async throws {
        let memory = try await F.open()
        _ = try await memory.brain.ingest(F.scene(["Save"]), into: F.bundle, now: F.t0, window: nil)
        let cache = ProjectionCache()
        let repository = SQLiteBrainRepository(store: memory.store, projectionCache: cache)
        let detections = F.scene(["Save"])
        let first = try #require(try await repository.indexedProjection(of: F.bundle, for: detections))
        let second = try #require(try await repository.indexedProjection(of: F.bundle, for: detections))
        #expect(first !== second)
        #expect(first.brain == (try await repository.projection(of: F.bundle, for: detections)))
        #expect(cache.statistics.hits == 0)
        #expect(cache.statistics.cachedBytes == 0)
        await memory.store.close()
    }

    @Test func budgetAndOversizedEntry() {
        let sample = BrainProjection(UIBrain())
        let cache = ProjectionCache(byteLimit: sample.estimatedBytes * 2 + 512)
        let incarnation = ProjectionCache.Incarnation()
        func load(_ app: String) -> BrainProjection {
            let request = cache.request(incarnation, app: app)
            return cache.publish(BrainProjection(UIBrain()), for: request)
        }
        let a = load("a"), b = load("b")
        #expect(cache.request(incarnation, app: "a").projection === a)
        _ = load("c")
        #expect(cache.request(incarnation, app: "b").projection == nil)
        #expect(cache.statistics.cachedBytes <= cache.byteLimit)
        #expect(cache.statistics.readerBytes >= b.estimatedBytes)
        let tiny = ProjectionCache(byteLimit: sample.estimatedBytes - 1)
        _ = tiny.publish(sample, for: tiny.request(incarnation, app: "large"))
        #expect(tiny.statistics.cachedBytes == 0)
        #expect(tiny.statistics.oversizedEntries == 1)
    }

    @Test func stringsAliasesAndGroupsContributeToBudget() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(F.switchColumn(states: Array(repeating: .off, count: 8)),
                                into: &brain, now: F.t0)
        let small = BrainProjection(brain)
        let alias = String(repeating: "Long alternate label ", count: 1000)
        brain.objects[0].aliases = [alias]
        let large = BrainProjection(brain)
        #expect(!brain.groups.isEmpty)
        #expect(large.estimatedBytes > small.estimatedBytes + alias.utf8.count)
        let cache = ProjectionCache(byteLimit: small.estimatedBytes + 512)
        let incarnation = ProjectionCache.Incarnation()
        _ = cache.publish(small, for: cache.request(incarnation, app: "small"))
        _ = cache.publish(large, for: cache.request(incarnation, app: "large"))
        #expect(cache.statistics.oversizedEntries == 1)
        #expect(cache.request(incarnation, app: "small").projection === small)
        let longKey = String(repeating: "x", count: cache.byteLimit)
        _ = cache.publish(small, for: cache.request(incarnation, app: longKey))
        #expect(cache.statistics.oversizedEntries == 2)
        #expect(cache.statistics.cachedBytes <= cache.byteLimit)
    }

    @Test func releaseActuallyDropsStorage() {
        let cache = ProjectionCache()
        let incarnation = ProjectionCache.Incarnation()
        weak var weakSnapshot: BrainProjection?
        var reader: BrainProjection? = cache.publish(BrainProjection(UIBrain()), for: cache.request(incarnation, app: "a"))
        weakSnapshot = reader
        if let reader {
            _ = cache.publish(reader, for: cache.request(incarnation, app: "b"))
        }
        cache.releaseMemory()
        #expect(cache.statistics.cachedBytes == 0)
        #expect(cache.statistics.readerBytes == reader?.estimatedBytes)
        #expect(weakSnapshot != nil)
        reader = nil
        #expect(weakSnapshot == nil)
        #expect(cache.statistics.readerBytes == 0)
    }

    @Test func closingStoreDuringLoadRejectsLateResult() async throws {
        let store = try await frozen()
        let cache = ProjectionCache()
        let gate = StepGate()
        var repository = SQLiteBrainRepository(store: store, projectionCache: cache)
        repository.beforeProjectionPublication = { await gate.pass() }
        let reader = repository
        let load = Task { try await reader.indexedProjection(of: F.bundle, for: []) }
        #expect(await gate.reached())
        await store.close()
        gate.open()
        await #expect(throws: MemoryStoreError.self) { _ = try await load.value }
        #expect(cache.statistics.cachedBytes == 0)
        #expect(cache.statistics.readerBytes == 0)
    }

    @Test func concurrentLoadAndReplacementNeverPublishesOldSnapshot() async {
        let cache = ProjectionCache()
        let incarnation = ProjectionCache.Incarnation()
        let request = cache.request(incarnation, app: "a")
        // The request is captured before invalidation; publication resumes only afterwards.
        cache.invalidate(incarnation)
        let late = await Task.detached { cache.publish(BrainProjection(UIBrain()), for: request) }.value
        #expect(cache.statistics.cachedBytes == 0)
        #expect(cache.statistics.readerBytes == late.estimatedBytes)
        let current = ProjectionCache.Incarnation()
        let requests = (0..<8).map { _ in cache.request(current, app: "a") }
        let snapshots = await withTaskGroup(of: BrainProjection.self) { group in
            for request in requests {
                group.addTask { cache.publish(BrainProjection(UIBrain()), for: request) }
            }
            var results: [BrainProjection] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(snapshots.allSatisfy { $0 === snapshots.first })
        #expect(cache.statistics.entries == 1)
        cache.releaseMemory()
        let pending = cache.request(current, app: "pending")
        cache.releaseMemory()
        _ = cache.publish(BrainProjection(UIBrain()), for: pending)
        #expect(cache.statistics.cachedBytes == 0)
    }
}
