import Dispatch
import Foundation
import Memory
import SQLiteAmalgamation
import Synchronization
@testable import SQLiteMemory
import Testing

@Suite("Independent SQLite connection execution")
struct SQLiteExecutorTests {

    /// HeldOperation blocks only a dedicated connection queue, with a deadline to keep a regression finite.
    private final class HeldOperation: Sendable {
        let entered: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let released = DispatchSemaphore(value: 0)

        init() {
            (entered, continuation) = AsyncStream.makeStream()
        }

        func hold() -> Bool {
            continuation.yield(())
            continuation.finish()
            return released.wait(timeout: .now() + 10) == .success
        }

        func release() { released.signal() }
    }

    @Test func readsDoNotWaitForWriter() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let held = HeldOperation()
        let writing = Task {
            try await store.write { transaction in
                try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES ('held.app')")
                return held.hold()
            }
        }
        defer { held.release() }
        for await _ in held.entered { break }
        let rows = try await store.read(priority: .critical) {
            try $0.query("SELECT count(*) FROM brain_apps") { $0.integer(0) ?? -1 }.first
        }
        #expect(rows == 0)
        held.release()
        #expect(try await writing.value)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 1)
        await store.close()
    }

    @Test(arguments: [false, true])
    func checkpointsDoNotHoldWriter(forced: Bool) async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase(), configuration: .init(
            checkpointFrames: 1, forcedCheckpointFrames: forced ? 2 : 16000
        ))
        let held = HeldOperation()
        let checkpointState = Mutex<(ConnectionRole?, Bool?)>((nil, nil))
        await store.holdCheckpoints {
            let role = SQLiteConnectionExecutor.currentRole
            let released = held.hold()
            checkpointState.withLock { $0 = (role, released) }
        }
        defer { held.release() }
        _ = try await store.write {
            try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('first.app')")
        }
        let paused = Task { if !forced { _ = try await store.checkpointIfDue() } }
        for await _ in held.entered { break }
        #expect(try await store.write { transaction in
            try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES ('second.app')")
            return SQLiteConnectionExecutor.currentRole
        } == .writer)
        held.release()
        try await paused.value
        let deadline = ContinuousClock.now + .seconds(5)
        while try await store.diagnostics().checkpoints == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(checkpointState.withLock { $0.0 } == .bulk)
        #expect(checkpointState.withLock { $0.1 } == true, "writer finished before the checkpoint's hold expired")
        #expect(try await store.diagnostics().checkpoints == 1)
        await store.close()
    }

    @Test func diagnosticsDuringCloseReportsClosed() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let held = HeldOperation()
        let reading = Task { try await store.read(priority: .critical) { _ in held.hold() } }
        defer { held.release() }
        for await _ in held.entered { break }
        let inspecting = Task { await storeError { _ = try await store.diagnostics() } }
        let closing = Task { await store.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        var closed = false
        while ContinuousClock.now < deadline {
            if await storeError({ _ = try await store.read { _ in 1 } }) == .unavailable(.closed) {
                closed = true
                break
            }
            await Task.yield()
        }
        #expect(closed)
        held.release()
        #expect(try await reading.value)
        #expect(await inspecting.value == .unavailable(.closed))
        await closing.value
        #expect(await store.liveHandles == 0)
    }

    @Test func readerRetriesProtocolContention() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let attempts = Mutex(0)
        let result = try await store.read(priority: .critical) { snapshot in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            _ = try snapshot.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }
            if attempt == 1 {
                throw SQLiteConnection.Failure(primary: SQLITE_PROTOCOL, extended: SQLITE_PROTOCOL,
                                               message: "reader WAL lock contention")
            }
            return attempt
        }
        #expect(result == 2)
        #expect(try await store.diagnostics().busyRetries == 1)
        await store.close()
    }

    @Test func readRouting() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let roles = try await [
            store.read(priority: .critical) { _ in SQLiteConnectionExecutor.currentRole },
            store.read(priority: .interactive) { _ in SQLiteConnectionExecutor.currentRole },
            store.read { _ in SQLiteConnectionExecutor.currentRole },
            store.read(priority: .bulk) { _ in SQLiteConnectionExecutor.currentRole }
        ]
        #expect(roles == [.reader(index: 0), .reader(index: 0), .reader(index: 1), .bulk])
        #expect(try await store.write { _ in SQLiteConnectionExecutor.currentRole } == .writer)
        let held = HeldOperation()
        let bulk = Task { try await store.read(priority: .bulk) { _ in held.hold() } }
        defer { held.release() }
        for await _ in held.entered { break }
        #expect(try await store.read(priority: .critical) { _ in 42 } == 42)
        held.release()
        #expect(try await bulk.value)
        await store.close()
    }

    @Test func dataVersionFromOneConnection() async throws {
        let url = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let initial = try await store.dataVersion()
        for priority in [ReadPriority.bulk, .common, .critical, .interactive] {
            _ = try await store.read(priority: priority) { try $0.query("SELECT count(*) FROM memory_events") { $0.integer(0) } }
            #expect(try await store.dataVersion() == initial)
        }
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened "))
        #expect(try await store.dataVersion() == initial)
        #expect(try await probe.ask("record external external-key 100") == "committed")
        let changed = try await store.dataVersion()
        #expect(changed != initial)
        let versioned = try await store.readVersioned {
            try $0.query("SELECT count(*) FROM memory_events") { $0.integer(0) ?? -1 }.first ?? -1
        }
        #expect(versioned.version == changed && versioned.value == 1)
        #expect(try await store.dataVersion() == changed)
        #expect(try await probe.ask("close") == "closed")
        await store.close()
    }

    @Test func readVersionedKeepsOneSnapshot() async throws {
        let url = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let initial = try await store.dataVersion()
        let result = try await store.readVersioned { snapshot in
            let first = try snapshot.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }.first ?? nil
            let external = try SQLiteConnection(path: url.path)
            defer { external.close() }
            try external.execute("INSERT INTO brain_apps (bundle_id) VALUES ('external.app')")
            let second = try snapshot.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }.first ?? nil
            return (first, second, SQLiteConnectionExecutor.currentRole)
        }
        #expect(result.version == initial)
        #expect(result.value.0 == 0 && result.value.1 == 0)
        #expect(result.value.2 == .reader(index: 0))
        #expect(try await store.dataVersion() != initial)
        await store.close()
    }

    @Test func readersDoNotRetainTheirOwner() async throws {
        let url = try temporaryDatabase()
        weak var released: SQLiteMemoryStore?
        do {
            let store = try await SQLiteMemoryStore.open(at: url)
            released = store
            #expect(try await store.read { _ in 1 } == 1)
        }
        #expect(released == nil)
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "released") == .notCorrupt)
    }

    @Test func closeRejectsWaitingWritesBeforeReadersFinish() async throws {
        let url = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        var events = await waits(of: store)
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")
        let held = HeldOperation()
        let reading = Task { try await store.read(priority: .bulk) { _ in held.hold() } }
        defer { held.release() }
        for await _ in held.entered { break }
        let writing = Task { await storeError { _ = try await record(EventRow(id: "waiting", key: "waiting-key"), in: store) } }
        #expect(await events.next() == .pausing(.begin, attempt: 1))
        let closing = Task { await store.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        var closed = false
        while ContinuousClock.now < deadline {
            let error = await storeError { _ = try await store.read(priority: .critical) { _ in 1 } }
            if error == .unavailable(.closed) { closed = true; break }
            await Task.yield()
        }
        #expect(closed)
        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await writing.value == .unavailable(.closed))
        held.release()
        #expect(try await reading.value)
        await closing.value
        #expect(await store.liveHandles == 0)
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: url) == 0)
    }

    @Test func writeOrderUnchanged() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        for index in 0..<20 {
            _ = try await record(EventRow(id: "event-\(index)", key: "key-\(index)"), in: store)
        }
        let ids = try await store.read {
            try $0.query("SELECT event_id FROM memory_events ORDER BY local_order") { try $0.text(0) ?? "" }
        }
        #expect(ids == (0..<20).map { "event-\($0)" })
        #expect(try await store.diagnostics().commits == 20)
        await store.close()
    }
}
