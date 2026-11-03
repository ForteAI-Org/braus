import AutomationRuntime
import EngineCore
import Testing

extension BatchDrainBoundTests {
    @Test @MainActor func deadlineStopsReadAndCompletesDelivery() async throws {
        var deliveries = 0
        var finishes = 0
        let began = ContinuousClock.now
        let result = try await BatchStepBoundary.perform(until: began.advanced(by: .milliseconds(40))) {
            deliveries += 1
            try await Task.sleep(for: .milliseconds(10))
            finishes += 1
            let wait = try #require(InterruptibleWait.current)
            wait.open()
            defer { wait.close() }
            let read: Bool? = await wait.reading {
                do { try await Task.sleep(for: .seconds(60)); return true }
                catch { return nil }
            }
            return read
        }
        #expect(result == nil)
        #expect(deliveries == 1 && finishes == 1)
        let elapsed = began.duration(to: .now)
        print("Batch boundary elapsed: \(elapsed)")
        #expect(elapsed < BatchPolicy.stepAllowance)
    }

    @Test @MainActor func takeoverDrainsWaitWithoutCancellingDelivery() async throws {
        let call = AutomationCallInterruption()
        var deliveries = 0
        var finishes = 0
        let began = ContinuousClock.now
        let stop = Task {
            try await Task.sleep(for: .milliseconds(30))
            call.interruptForHumanControl()
            call.requestWaitStop()
        }
        defer { stop.cancel() }
        try await AutomationCallInterruption.$current.withValue(call) {
            try await call.withWait {
                try await BatchStepBoundary.perform(until: .now.advanced(by: BatchPolicy.timeCap)) {
                    deliveries += 1
                    try await Task.sleep(for: .milliseconds(50))
                    finishes += 1
                    let wait = try #require(InterruptibleWait.current)
                    wait.open()
                    defer { wait.close() }
                    let read: Bool? = await wait.reading { true }
                    #expect(read == nil)
                }
            }
        }
        #expect(deliveries == finishes && finishes == 1)
        let elapsed = began.duration(to: .now)
        print("Batch boundary elapsed: \(elapsed)")
        #expect(elapsed < BatchPolicy.stepAllowance)
    }
}
