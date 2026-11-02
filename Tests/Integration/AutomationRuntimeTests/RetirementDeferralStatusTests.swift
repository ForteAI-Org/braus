import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import AutomationRuntime

private final class MaintenanceLockRelease: Sendable {
    let release = DispatchSemaphore(value: 0)
    let result = Mutex<Int32?>(nil)
}

struct RetirementDeferralStatusTests {
    @Test func statusReportsDeferralAndLaterMaintenanceRetiresTheCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retirement-status-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = MemoryService(directory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var oldest: URL?
        for day in 1...4 {
            let stamp = MemoryService.copyStamp(now.addingTimeInterval(-Double(day) * 86_400))
            let file = directory.appendingPathComponent("memory.sqlite.backup-\(stamp)")
            try Data("copy-\(day)".utf8).write(to: file)
            oldest = file
        }
        let source = try #require(oldest)
        let retired = directory.appendingPathComponent(".retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let fd = Darwin.open(retired.appendingPathComponent(".retirement.lock").path,
                             O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try #require(fd >= 0)
        defer { #expect(Darwin.close(fd) == 0) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let state = MaintenanceLockRelease()
        let (completion, finished) = AsyncStream<Void>.makeStream()
        DispatchQueue.global().async {
            // The safety release exposes blocking on the unchanged implementation without leaving a stuck test.
            _ = state.release.wait(timeout: .now() + .seconds(5))
            state.result.withLock { $0 = flock(fd, LOCK_UN) }
            finished.finish()
        }
        let released = Task.detached { for await _ in completion {} }
        var failure: (any Error)?
        do {
            await service.maintainCopies(now: now, verifiedBackupAt: nil)
            let deferred = await service.status().retirement
            #expect(deferred.reason?.hasPrefix("retirementDeferred:") == true)
            #expect(deferred.collisions == 0 && deferred.incomplete == 0)
            #expect(FileManager.default.fileExists(atPath: source.path))
            if FileManager.default.fileExists(atPath: source.path) {
                #expect(try Data(contentsOf: source) == Data("copy-4".utf8))
            }
            #expect(state.result.withLock { $0 } == nil, "Maintenance and status returned while the lock was still held.")
        } catch { failure = error }
        state.release.signal()
        await released.value
        #expect(state.result.withLock { $0 } == 0)
        if let failure { throw failure }
        await service.maintainCopies(now: now, verifiedBackupAt: nil)
        let completed = await service.status().retirement
        #expect(completed.reason == nil)
        #expect(completed.count == 1)
        let saved = retired.appendingPathComponent(source.lastPathComponent).appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: saved) == Data("copy-4".utf8))
        await service.close()
    }
}
