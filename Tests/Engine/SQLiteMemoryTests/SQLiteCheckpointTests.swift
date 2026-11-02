//
//  SQLiteCheckpointTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
import SQLiteAmalgamation
@testable import SQLiteMemory
import Testing

/// Explicit passive checkpoints report their cost and tolerate readers still on older snapshots.
@Suite("Checkpoints of the write-ahead log")
struct SQLiteCheckpointTests {

    @Test func checkpointDurationReported() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let report = try await store.checkpoint()
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.lastCheckpoint?.duration == report.duration)
        #expect(report.duration >= .zero)
        await #expect(throws: MemoryStoreError.self) {
            try await store.snapshot(to: store.url)
        }
        let failedDuration = try #require(try await store.diagnostics().lastSnapshotDuration)
        #expect(failedDuration >= .zero)
        #expect(try await store.diagnostics().snapshots == 0)
        let destination = store.url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let copy = try await store.snapshot(to: destination)
        #expect(try await store.diagnostics().lastSnapshotDuration == copy.duration)
        await store.close()
    }

    @Test func forcedCheckpoint() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase(), configuration: .init(
            checkpointFrames: 1, forcedCheckpointFrames: 2
        ))
        _ = try await record(EventRow(id: "forced", key: "forced-key"), in: store)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await store.diagnostics().forcedCheckpoints == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.forcedCheckpoints == 1)
        #expect(diagnostics.pauseCheckpoints == 0)
        #expect(diagnostics.residualWALFrames == 0)
        await store.close()
    }

    @Test func walAccounting() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        _ = try await store.checkpoint()
        let before = try await store.diagnostics()
        _ = try await record(EventRow(id: "accounted", key: "accounted-key"), in: store)
        let written = try await store.diagnostics()
        #expect(written.lastWriteFramesAdded > 0)
        #expect(written.framesAdded - before.framesAdded == written.lastWriteFramesAdded)
        #expect(written.residualWALFrames == written.lastWriteFramesAdded)
        #expect(written.walBytes > 0)
        let report = try await store.checkpoint()
        let copied = try await store.diagnostics()
        #expect(copied.framesAdded == written.framesAdded)
        #expect(copied.residualWALFrames == 0)
        #expect(copied.checkpointedFrames - written.checkpointedFrames == report.framesCopied)
        #expect(copied.checkpointDuration - written.checkpointDuration == report.duration)
        #expect(copied.walBytes == written.walBytes)
        let url = store.url
        await store.close()
        #expect(try walSize(url) == 0)
    }

    @Test func busyCloseCheckpointIsReported() async throws {
        let store = try await SQLiteMemoryStore.open(at: temporaryDatabase())
        let reader = try SQLiteConnection(path: store.url.path, readOnly: true)
        defer { reader.close() }
        try reader.execute("BEGIN")
        _ = try reader.query("SELECT count(*) FROM brain_apps") { $0.integer(0) }
        _ = try await store.write {
            try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('later.app')")
        }
        await store.close()
        guard case .contention(let fault, _, _)? = await store.lastCloseError else {
            Issue.record("expected a busy close checkpoint, got \(String(describing: await store.lastCloseError))")
            return
        }
        #expect(fault.code.primary == SQLITE_BUSY)
        #expect(fault.phase == .checkpoint)
        #expect(await store.liveHandles == 0)
        try reader.execute("COMMIT")
    }

    @Test func archiveReaderCloseDoesNotTruncate() async throws {
        let url = try temporaryDatabase()
        let producer = try await SQLiteMemoryStore.open(at: url)
        let archive = try await SQLiteMemoryStore.open(at: url, opening: .existingArchive)
        _ = try await producer.write {
            try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('producer.app')")
        }
        let size = try walSize(url)
        #expect(size > 0)
        await archive.close()
        #expect(await archive.lastCloseError == nil)
        #expect(try walSize(url) == size)
        await producer.close()
        #expect(await producer.lastCloseError == nil)
        #expect(try walSize(url) == 0)
    }

    private func walSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? UInt64) ?? 0
    }

    @Test("an explicit passive checkpoint moves every frame when nobody needs them, and is reported")
    func explicitCheckpoint() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await store.diagnostics().autoCheckpointFrames == 0)
        for index in 0..<20 {
            _ = try await record(EventRow(id: "e\(index)", key: "k\(index)"), in: store)
        }
        let report = try await store.checkpoint()
        #expect(report.frames > 0)
        #expect(report.checkpointedFrames == report.frames)
        #expect(report.outcome == .complete)
        #expect(report.duration >= .zero)
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.checkpoints == 1)
        #expect(diagnostics.lastCheckpoint == report)
        // Nothing new: the log's frames are all in the file already.
        let again = try await store.checkpoint()
        #expect(again.outcome == .complete)
        #expect(again.framesCopied == 0)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 20)
        await store.close()
    }

    @Test("a reader on an older snapshot keeps the rest of the log: partial, not a failure, and the store writes on")
    func readerKeepsTheRest() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        for index in 0..<10 {
            _ = try await record(EventRow(id: "a\(index)", key: "a-k\(index)"), in: store)
        }
        #expect(try await store.checkpoint().outcome == .complete)
        let reader = try SQLiteConnection(path: url.path, readOnly: true)
        try reader.execute("BEGIN")
        #expect(try reader.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 10)
        for index in 0..<10 {
            _ = try await record(EventRow(id: "b\(index)", key: "b-k\(index)"), in: store)
        }
        let partial = try await store.checkpoint()
        #expect(partial.outcome == .partial)
        #expect(partial.checkpointedFrames < partial.frames)
        _ = try await record(EventRow(id: "c", key: "c-k"), in: store)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 21)
        #expect(try reader.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 10)
        try reader.execute("COMMIT")
        reader.close()
        let complete = try await store.checkpoint()
        #expect(complete.outcome == .complete)
        #expect(complete.checkpointedFrames == complete.frames)
        #expect(try await store.diagnostics().checkpoints == 3)
        await store.close()
    }

    @Test("continuous writes defer checkpoints below the forced threshold")
    func checkpointOnlyInPause() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let padding = String(repeating: "x", count: 3900)
        // Ten commits of about 250 pages each: 2500 pages, well past the 1000-frame threshold.
        for batch in 0..<10 {
            _ = try await store.write { transaction in
                for index in 0..<250 {
                    try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES (?)", [.text("app.\(batch).\(index).\(padding)")])
                }
            }
        }
        let size = try walSize(url)
        #expect(size > 0)
        #expect(size > 8 * 1024 * 1024)
        #expect(try await store.diagnostics().checkpoints == 0)
        #expect(try await store.checkpointIfDue() != nil)
        #expect(try await store.diagnostics().pauseCheckpoints == 1)
        #expect(try await store.checkpointIfDue() == nil)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 2500)
        await store.close()
    }
}
