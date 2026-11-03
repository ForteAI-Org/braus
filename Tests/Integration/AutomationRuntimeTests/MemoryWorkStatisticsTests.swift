import Foundation
import Memory
import PhaseSignposts
import Synchronization
import Testing
@testable import AutomationRuntime

@Suite("Memory work statistics")
struct MemoryWorkStatisticsTests {
    @Test func everyEnqueueHasAClass() async throws {
        let service = try W.service()
        for label in ["brain record", "brain relation", "brain observe",
                      "scene before", "scene after", "scene current"] {
            await service.enqueue(label) { _ in }
        }
        for label in ["scene menu", "unknown", "brain record extra"] {
            await service.enqueue(label) { _ in }
        }
        #expect(await service.flush(within: .seconds(10)))
        let statistics = await service.status().workStatistics
        #expect(statistics[.followUp].completed == 6)
        #expect(statistics[.background].completed == 3)
        #expect(statistics.unclassifiedCount == 3)
        await service.close()
    }

    @Test func enqueueCallSitesUseTheDeclaredVocabulary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ))
        var labels: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            labels += source.components(separatedBy: "enqueue(\"").dropFirst().map {
                String($0.prefix { $0 != "\"" })
            }
        }
        #expect(labels == ["derived pause"])
        #expect(CapturePhase.allCases.filter(\.isAssociable).map(\.rawValue).sorted()
                == ["after", "before", "current"])
    }

    @Test func waitAndDurationCounted() async throws {
        let service = try W.service()
        let released = Mutex(false)
        await service.enqueue("brain record") { _ in
            while !released.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(1))
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        await service.enqueue("brain observe") { _ in
            try await Task.sleep(for: .milliseconds(10))
        }
        released.withLock { $0 = true }
        #expect(await service.flush(within: .seconds(10)))
        let totals = await service.status().workStatistics[.followUp]
        #expect(totals.completed == 2)
        #expect(totals.waitCount == 2)
        #expect(totals.wait >= .milliseconds(20))
        #expect(totals.duration >= .milliseconds(40))
        await service.close()
    }

    @Test func enqueueOrderUnchanged() async throws {
        let service = try W.service()
        let order = Mutex<[Int]>([])
        for index in 0..<30 {
            await service.enqueue(index.isMultiple(of: 2) ? "scene before" : "unknown") { _ in
                order.withLock { $0.append(index) }
            }
        }
        #expect(await service.flush(within: .seconds(10)))
        #expect(order.withLock { $0 } == Array(0..<30))
        await service.close()
    }

    @Test func synchronousEntriesHaveNoQueueWait() async throws {
        let service = try W.service()
        for before in [false, true] {
            for after in [false, true] {
                try await service.confirm("call unknown start", beforeEffect: before, afterEffect: after) { _ in }
            }
        }
        let value = try await service.perform { _ in 42 }
        #expect(value == 42)
        let statistics = await service.status().workStatistics
        #expect(statistics[.critical].completed == 4)
        #expect(statistics[.critical].attempts == 4)
        #expect(statistics[.critical].waitCount == 0)
        #expect(statistics[.interactive].completed == 1)
        #expect(statistics[.interactive].waitCount == 0)
        #expect(statistics.unclassifiedCount == 0)
        await service.close()
    }

    @Test func retriesAndFallbackCountOneLogicalRequest() async throws {
        let service = try W.service(.init(essentialPause: .zero))
        let attempts = Mutex(0)
        try await service.confirm("unknown") { _ in
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt < 3 { throw EssentialWriteFailure.io("Transient test failure") }
        }
        try await service.confirm("unknown", fallback: { _, _ in }) { _ in
            throw EssentialWriteFailure.refused("Test refusal")
        }
        let totals = await service.status().workStatistics[.critical]
        #expect(totals.completed == 2)
        #expect(totals.attempts == 5)
        #expect(totals.waitCount == 0)
        await service.close()
    }

    @Test func pendingRetryDoesNotCountAnotherLogicalRequest() async throws {
        let service = try W.service(.init(essentialAttempts: 1))
        let attempts = Mutex(0)
        await #expect(throws: EssentialWriteFailure.self) {
            try await service.confirm("unknown", afterEffect: true) { _ in
                let attempt = attempts.withLock { value in
                    value += 1
                    return value
                }
                if attempt == 1 { throw EssentialWriteFailure.io("Transient test failure") }
            }
        }
        try await service.confirm("unknown", beforeEffect: true) { _ in }
        let totals = await service.status().workStatistics[.critical]
        #expect(totals.completed == 2)
        #expect(totals.attempts == 3)
        #expect(attempts.withLock { $0 } == 2)
        await service.close()
    }

    @Test func failedBackupIsIdle() async throws {
        let service = try W.service()
        await service.setBackupEnvironment(now: { Date() }, capacity: { _ in Int64.max })
        await service.setBeforeBackup { throw EssentialWriteFailure.io("Test copy failure") }
        _ = try await service.ready()
        let deadline = ContinuousClock.now + .seconds(10)
        while await service.status().workStatistics[.idle].completed == 0 {
            guard ContinuousClock.now < deadline else {
                Issue.record("Backup did not complete")
                await service.close()
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await service.close()
        let totals = await service.status().workStatistics[.idle]
        #expect(totals.completed >= 1)
        #expect(totals.attempts == totals.completed)
        #expect(totals.waitCount == 0)
    }

    @Test func refusedAdmissionIsCounted() async throws {
        let service = try W.service(.init(queueLimit: 0))
        await service.enqueue("brain record") { _ in Issue.record("Dropped body ran") }
        let statistics = await service.status().workStatistics
        #expect(statistics[.followUp].dropped == 1)
        #expect(statistics[.followUp].completed == 0)
        await service.close()
    }
}
