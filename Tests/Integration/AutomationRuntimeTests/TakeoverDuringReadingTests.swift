import AutomationRuntime
import EngineCore
import Foundation
import Memory
import Synchronization
import Testing

@MainActor
struct TakeoverDuringReadingTests {
    @Test func takeoverCancelsOnlyTheReadAndCompletesMemory() async throws {
        let service = try W.service()
        do {
            let recorder = W.recorder(service)
            let interruption = AutomationCallInterruption()
            let entered = Mutex(false)
            let gestures = Mutex(0)
            try await recorder.begin(.act(target: "Format", verb: .click, value: nil, section: nil),
                app: AppContextIdentity(bundleID: W.bundle))
            let call = Task {
                try await interruption.withWait {
                    gestures.withLock { $0 += 1 }
                    interruption.wait.open()
                    defer { interruption.wait.close() }
                    let result = await interruption.wait.reading {
                        entered.withLock { $0 = true }
                        do { try await Task.sleep(for: .seconds(30)) } catch { return nil as Int? }
                        return 1
                    }
                    #expect(result == nil)
                    #expect(!Task.isCancelled)
                    await recorder.record(ActionRecord(bundleID: W.bundle, element: W.format, verb: .click,
                        effect: nil, windowTitleAfter: nil, before: W.window([W.format]),
                        attempt: .deliveryFailed("delivery stopped")))
                    let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                        verdict: .unknown, limits: [.deliveryUncertain, .noAfterScene], performed: .uncertain)
                    let outcome = ActOutcome(.actedUnverified, "No after-scene was read", check: check)
                    try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message),
                        tool: .act, check: check)
                    return outcome
                }
            }
            while !entered.withLock({ $0 }) { await Task.yield() }
            interruption.interruptForHumanControl()
            interruption.requestWaitStop()
            let outcome = try await call.value
            #expect(outcome.outcome.row == "uncertain · unknown(not_readable) · do_not_repeat")
            #expect(interruption.wasInterrupted)
            #expect(!call.isCancelled)
            #expect(gestures.withLock { $0 } == 1)
            #expect(await service.flush(within: .seconds(10)))
            let recorded = try #require(try await service.call(recorder.eventID))
            #expect(recorded.progress.status == .completed)
            let status = await service.status()
            #expect(status.state == .open)
            #expect(status.failed == 0 && status.partial == 0)
        } catch {
            await service.close()
            throw error
        }
        await service.close()
    }
}
