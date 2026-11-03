import EngineCore
import Foundation
import Synchronization
import Testing

struct InterruptibleWaitTests {
    @Test func closedReadStillRunsAfterStop() async {
        let wait = InterruptibleWait()
        wait.requestStop()
        let value = await wait.reading { 7 }
        #expect(value == 7)
        #expect(!wait.isOpen)
        #expect(wait.stopRequested)
        #expect(!Task.isCancelled)
    }

    @Test func openStopReturnsNilAndDoesNotCancelCaller() async {
        let wait = InterruptibleWait()
        wait.open()
        let entered = Mutex(false)
        let read = Task {
            await wait.reading {
                entered.withLock { $0 = true }
                do { try await Task.sleep(for: .seconds(30)) } catch { return nil as Int? }
                return 9
            }
        }
        while !entered.withLock({ $0 }) { await Task.yield() }
        wait.requestStop()
        #expect(await read.value == nil)
        #expect(!Task.isCancelled)
        #expect(await wait.reading { 3 } == nil)
        wait.close()
        #expect(await wait.reading { 4 } == 4)
    }

    @Test func readingInheritsTaskLocals() async {
        let wait = InterruptibleWait()
        wait.open()
        let inherited = await InterruptibleWait.$current.withValue(wait) {
            await wait.reading { InterruptibleWait.current === wait }
        }
        #expect(inherited == true)
    }
}

extension InterruptibleWaitTests {
    @Test func stopDoesNotWaitForAnUncooperativeReader() async {
        let wait = InterruptibleWait()
        wait.open()
        let release = Mutex<CheckedContinuation<Int?, Never>?>(nil)
        let reading = Task {
            await wait.reading {
                await withCheckedContinuation { continuation in
                    release.withLock { $0 = continuation }
                }
            }
        }
        while release.withLock({ $0 == nil }) { await Task.yield() }
        wait.requestStop()
        #expect(await reading.value == nil)
        release.withLock { $0 }?.resume(returning: 2)
        #expect(!Task.isCancelled)
    }
}

extension InterruptibleWaitTests {
    @Test func callerCancellationReachesOpenRead() async {
        let wait = InterruptibleWait()
        wait.open()
        let entered = Mutex(false)
        let cancelled = Mutex(false)
        let task = Task {
            await wait.reading {
                entered.withLock { $0 = true }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch is CancellationError { cancelled.withLock { $0 = true }; return nil as Int? }
                catch { Issue.record(error); return nil }
                return 1
            }
        }
        while !entered.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        #expect(await task.value == nil)
        let deadline = ContinuousClock.now + .milliseconds(200)
        while !cancelled.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(cancelled.withLock { $0 })
        #expect(!wait.stopRequested)
    }
}
