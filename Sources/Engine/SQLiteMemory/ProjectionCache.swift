import Foundation
import Memory

/// ProjectionCache owns the process's retained frozen naming snapshots and their indices.
/// All mutable bookkeeping is protected by `lock`; SQL, index construction, matching and
/// destruction of evicted snapshots run outside it. Readers own immutable snapshots independently.
/// The default owner is shared across stores and repositories. Inject an isolated owner for tests.
public final class ProjectionCache: @unchecked Sendable {
    public static let shared = ProjectionCache()
    public let byteLimit: Int

    /// Estimated storage, not allocator measurements. Reader bytes are evicted snapshots still
    /// borrowed by callers, excluded from cachedBytes and counted once per snapshot.
    public struct Statistics: Sendable {
        public fileprivate(set) var hits = 0
        public fileprivate(set) var misses = 0
        public fileprivate(set) var loads = 0
        public fileprivate(set) var indexBuilds = 0
        public fileprivate(set) var oversizedEntries = 0
        public fileprivate(set) var entries = 0
        public fileprivate(set) var cachedBytes = 0
        public fileprivate(set) var readerBytes = 0
        public fileprivate(set) var bypassBytes = 0
        public fileprivate(set) var sqlTime = Duration.zero
        public fileprivate(set) var indexTime = Duration.zero
    }

    /// Incarnation is independent of the archive's path, app identifiers and observation clock.
    /// Its validity is monotonic under its own lock. Invalidation releases that lock before
    /// entering a cache, so cache lookup/publication can safely check validity under the cache lock.
    final class Incarnation: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var valid = true

        var isCurrent: Bool { lock.withLock { valid } }
        func invalidate() { lock.withLock { valid = false } }
    }

    struct Key: Hashable {
        let store: UUID
        let app: String
    }

    struct Request: Sendable {
        let incarnation: Incarnation
        let app: String
        let generation: UInt64
        let projection: BrainProjection?
        let usesSceneSlice: Bool
    }

    private struct Entry {
        let projection: BrainProjection?
        let bytes: Int
        var used: UInt64
    }

    private struct Borrowed {
        weak var projection: BrainProjection?
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var borrowed: [Borrowed] = []
    private var counters = Statistics()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    /// A zero limit preserves the existing SQL slice path in SQLiteBrainRepository.
    public init(byteLimit: Int = 8 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
    }

    public var statistics: Statistics {
        lock.withLock {
            borrowed = borrowed.filter { $0.projection != nil }
            var counted = Set(entries.values.compactMap { $0.projection.map(ObjectIdentifier.init) })
            var result = counters
            result.entries = entries.values.filter { $0.projection != nil }.count
            result.readerBytes = borrowed.reduce(0) { bytes, item in
                guard let projection = item.projection,
                      counted.insert(ObjectIdentifier(projection)).inserted else { return bytes }
                return bytes + projection.estimatedBytes
            }
            return result
        }
    }

    func request(_ incarnation: Incarnation, app: String) -> Request {
        lock.withLock {
            sequence &+= 1
            let key = Key(store: incarnation.id, app: app)
            var projection: BrainProjection?
            var usesSceneSlice = false
            if incarnation.isCurrent, var entry = entries[key] {
                entry.used = sequence
                entries[key] = entry
                projection = entry.projection
                usesSceneSlice = entry.projection == nil
                counters.hits += 1
            } else {
                counters.misses += 1
            }
            return Request(incarnation: incarnation, app: app, generation: generation, projection: projection,
                           usesSceneSlice: usesSceneSlice)
        }
    }

    /// Publishes only complete snapshots from a current incarnation and retention generation.
    /// Concurrent misses may build separately; only one snapshot wins publication for the key.
    func publish(
        _ projection: BrainProjection,
        for request: Request,
        sqlTime: Duration = .zero,
        indexTime: Duration = .zero,
        retaining: Bool = true
    ) -> BrainProjection {
        publish(projection, for: request, sqlTime: sqlTime, indexTime: indexTime,
                retaining: retaining, checking: {})
    }

    /// Checks the read at publication while holding only the bookkeeping lock.
    func publish(
        _ projection: BrainProjection,
        for request: Request,
        sqlTime: Duration = .zero,
        indexTime: Duration = .zero,
        retaining: Bool = true,
        checking check: () throws -> Void
    ) rethrows -> BrainProjection {
        var retired: [Entry] = []
        let result = try lock.withLock {
            try check()
            counters.loads += 1
            counters.indexBuilds += 1
            counters.sqlTime += sqlTime
            counters.indexTime += indexTime
            borrowed.removeAll { $0.projection == nil }
            borrowed.append(Borrowed(projection: projection))
            guard request.incarnation.isCurrent, request.generation == generation else { return projection }
            let key = Key(store: request.incarnation.id, app: request.app)
            if let existing = entries[key] { return existing.projection ?? projection }
            let overhead = 128 + request.app.utf8.count * 2
            let oversized = projection.estimatedBytes + overhead > byteLimit
            if oversized { counters.oversizedEntries += 1 }
            // A bounded negative entry avoids rebuilding a full projection on every scene.
            // Its bookkeeping shares the same byte budget and invalidation as retained snapshots.
            let retained: BrainProjection? = retaining && !oversized ? projection : nil
            let bytes = overhead + (retained?.estimatedBytes ?? 0)
            guard bytes <= byteLimit else { return projection }
            while counters.cachedBytes + counters.bypassBytes > byteLimit - bytes,
                  let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                retired.append(oldest.value)
                entries.removeValue(forKey: oldest.key)
                if oldest.value.projection == nil { counters.bypassBytes -= oldest.value.bytes }
                else { counters.cachedBytes -= oldest.value.bytes }
            }
            sequence &+= 1
            entries[key] = Entry(projection: retained, bytes: bytes, used: sequence)
            if retained == nil { counters.bypassBytes += bytes }
            else { counters.cachedBytes += bytes }
            return projection
        }
        withExtendedLifetime(retired) {}
        return result
    }

    func invalidate(_ incarnation: Incarnation) {
        incarnation.invalidate()
        let retired = lock.withLock {
            let removed = entries.filter { $0.key.store == incarnation.id }
            for (key, entry) in removed {
                entries.removeValue(forKey: key)
                if entry.projection == nil { counters.bypassBytes -= entry.bytes }
                else { counters.cachedBytes -= entry.bytes }
            }
            return removed
        }
        withExtendedLifetime(retired) {}
    }

    /// Releases retained storage synchronously, without waiting for readers. In-flight loads from
    /// before this call cannot repopulate it. Their returned snapshots remain observable as reader bytes.
    public func releaseMemory() {
        let retired = lock.withLock {
            generation &+= 1
            let removed = entries
            entries = [:]
            counters.cachedBytes = 0
            counters.bypassBytes = 0
            return removed
        }
        withExtendedLifetime(retired) {}
    }
}
