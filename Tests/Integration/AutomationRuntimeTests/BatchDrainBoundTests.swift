import AutomationRuntime
import EngineCore
import Testing
import LocalMCP

@Suite @MainActor struct BatchDrainBoundTests {
    @Test func deadlineStopsWaitButDrainsDelivery() async throws {
        var delivered = false
        let value = try await BatchStepBoundary.perform(until: .now.advanced(by: .milliseconds(5))) {
            try await Task.sleep(for: .milliseconds(25))
            delivered = true
            #expect(InterruptibleWait.current?.stopRequested == true)
            return 42
        }
        #expect(delivered)
        #expect(value == 42)
        #expect(BatchPolicy.timeCap < BatchPolicy.hostDrainLimit)
    }
}


extension BatchDrainBoundTests {
    @Test func hostDrainRetainsInFlightDelivery() async throws {
        let interruption = AutomationCallInterruption()
        var entered = false
        var delivered = false
        let router = MCPRouter(tools: [.object(["name": .string("batch")])], instructions: nil) { _, _ in
            try await AutomationCallInterruption.$current.withValue(interruption) {
                try await BatchStepBoundary.perform(until: .now.advanced(by: .seconds(1))) {
                    entered = true
                    try await Task.sleep(for: .milliseconds(25))
                    delivered = true
                    return MCPRouter.textResult("Delivered")
                }
            }
        }
        let call = Task {
            await router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("tools/call"), "params": .object(["name": .string("batch")])]))
        }
        while !entered { await Task.yield() }
        interruption.interruptForHumanControl()
        router.suspendForHumanIntervention()
        await router.drain()
        #expect(delivered)
        #expect(await call.value != nil)
    }
}
