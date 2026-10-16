//
//  AbandonableReadTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 16/10/2026.
//

import Dispatch
import PerceptionCore
import Synchronization
import Testing

/// A read that ignores cancellation, as Vision does while it loads its model or runs it on the
/// Neural Engine, must not keep a cancelled caller waiting.
@Suite("A read its caller abandons", .serialized)
struct AbandonableReadTests {

    /// A read that blocks until it is released, or for five seconds, whatever its caller does.
    private final class BlockingRead: Sendable {
        let started  = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let stopped  = Mutex(false)
        let runs     = Mutex(0)

        func read() -> Int {
            runs.withLock { $0 += 1 }
            started.signal()
            _ = released.wait(timeout: .now() + 5)
            finished.signal()
            return 42
        }

        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }
        func waitUntilFinished() -> Bool { finished.wait(timeout: .now() + 5) == .success }
    }

    private struct Failure: Error {}

    @Test("a caller cancelled while the read runs is answered at once, the read is asked to stop, and the read ends on its own")
    func cancelledWhileReading() async throws {
        let read = BlockingRead()
        let task = Task { try await AbandonableRead.run(read.read, stop: { read.stopped.withLock { $0 = true } }) }
        #expect(await Task.detached { read.waitUntilStarted() }.value)
        let clock = ContinuousClock(), cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - cancelled < .seconds(1), "the caller does not wait for a read that ignores cancellation")
        #expect(read.stopped.withLock { $0 })
        read.released.signal()
        #expect(await Task.detached { read.waitUntilFinished() }.value, "the abandoned read still ends, its result dropped")
    }

    @Test("a caller cancelled before the read starts never starts it")
    func cancelledBeforeReading() async throws {
        let read = BlockingRead()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AbandonableRead.run(read.read)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(read.runs.withLock { $0 } == 0)
    }

    @Test("a read that is not cancelled answers its value or its error")
    func uncancelledRead() async throws {
        let read = BlockingRead()
        read.released.signal()
        #expect(try await AbandonableRead.run(read.read) == 42)
        await #expect(throws: Failure.self) { try await AbandonableRead.run { () throws -> Int in throw Failure() } }
    }
}
