import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import SQLiteMemory

private final class RetirementLockRelease: Sendable {
    let release = DispatchSemaphore(value: 0)
    let result = Mutex<Int32?>(nil)
}

struct RetirementLockDeferralTests {
    private func whileLockIsHeld(_ directory: URL, _ body: () async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".retirement.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try #require(fd >= 0)
        defer { #expect(Darwin.close(fd) == 0) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let state = RetirementLockRelease()
        let (completion, finished) = AsyncStream<Void>.makeStream()
        DispatchQueue.global().async {
            // The safety release lets the unchanged implementation fail instead of hanging forever.
            _ = state.release.wait(timeout: .now() + .seconds(5))
            state.result.withLock { $0 = flock(fd, LOCK_UN) }
            finished.finish()
        }
        let released = Task.detached { for await _ in completion {} }
        var failure: (any Error)?
        do {
            try await body()
            #expect(state.result.withLock { $0 } == nil, "The operation returned while the lock was still held.")
        } catch { failure = error }
        state.release.signal()
        await released.value
        #expect(state.result.withLock { $0 } == 0)
        if let failure { throw failure }
    }

    @Test(arguments: [false, true])
    func contentionDefersWithoutMovingAnyMember(_ residues: Bool) async throws {
        let base = try temporaryDatabase("deferred-copy")
        let retired = base.deletingLastPathComponent().appendingPathComponent(".retired")
        let suffixes = residues ? ["-wal", "-shm", "-journal"] : ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            try Data("original\(suffix)".utf8).write(to: URL(fileURLWithPath: base.path + suffix))
        }
        try await whileLockIsHeld(retired) {
            let report = try residues
                ? SQLiteArchiveRetirement.retireResidues(base, into: retired)
                : SQLiteArchiveRetirement.retire(base, into: retired)
            #expect(report.state.rawValue == "deferred")
            #expect(report.reason?.hasPrefix("retirementDeferred:") == true)
            #expect(report.manifestURL == nil)
            #expect(report.memberCount == 0 && report.byteCount == 0)
            for suffix in suffixes {
                let source = URL(fileURLWithPath: base.path + suffix)
                #expect(FileManager.default.fileExists(atPath: source.path))
                if FileManager.default.fileExists(atPath: source.path) {
                    #expect(try Data(contentsOf: source) == Data("original\(suffix)".utf8))
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: retired.path) == [".retirement.lock"])
        }
        let retry = try residues
            ? SQLiteArchiveRetirement.retireResidues(base, into: retired)
            : SQLiteArchiveRetirement.retire(base, into: retired)
        #expect(retry.state == .retired)
        for suffix in suffixes {
            let saved = retired.appendingPathComponent(base.lastPathComponent)
                .appendingPathComponent(base.lastPathComponent + suffix)
            #expect(try Data(contentsOf: saved) == Data("original\(suffix)".utf8))
        }
    }

    @Test func verifiedSnapshotAndWriterContinueWhileRetirementIsDeferred() async throws {
        let base = try temporaryDatabase("deferred-snapshot")
        let store = try await SQLiteMemoryStore.open(at: base)
        _ = try await record(EventRow(id: "before-copy", key: "before-copy"), in: store)
        let copy = base.deletingLastPathComponent().appendingPathComponent("verified.sqlite")
        try await whileLockIsHeld(base.deletingLastPathComponent().appendingPathComponent(".retired")) {
            _ = try await store.snapshot(to: copy)
            let diagnostics = try await store.diagnostics()
            #expect(diagnostics.lastRetirement?.state.rawValue == "deferred")
            #expect(diagnostics.lastRetirement?.reason?.hasPrefix("retirementDeferred:") == true)
            _ = try await record(EventRow(id: "after-copy", key: "after-copy"), in: store)
        }
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: copy) == 1)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 2)
        await store.close()
    }
}
