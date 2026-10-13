import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

@MainActor
@Suite("Independent D2 corrections: native command evidence on errors", .serialized)
struct D2NativeCommandIndependentReviewTests {
    struct AfterPerceptionFailure: Error {}

    @Test("a press whose observation fails after its gesture keeps the before sample it already perceived")
    func afterPerceptionFailureKeepsBefore() async throws {
        let service = try W.service()
        let recorder = W.recorder(service)
        let before = W.window([W.button("Save", x: 0.2)], title: "Export")
        try await recorder.begin(.press(button: "Save"), app: AppContextIdentity(bundleID: W.bundle))
        var reads = 0
        var gestures = 0
        do {
            _ = try await PerceivedCommand.perform(bundleID: W.bundle, recorder: recorder, perceive: {
                reads += 1
                if reads == 2 { throw AfterPerceptionFailure() }
                return before
            }) { observe in
                // The production DialogButtonPress also awaits observation after the dispatched gesture,
                // and propagates its error. No actual UI input is performed in this test.
                gestures += 1
                let after = try await observe()
                return ActOutcome(.foundActed, "pressed", scene: after)
            }
            Issue.record("the post-dispatch observation should have failed")
        } catch {
            try await recorder.end(.failed, result: .error(message: "post-dispatch observation failed"), tool: .press)
        }
        #expect(reads == 2 && gestures == 1)
        let eventID = recorder.eventID
        let savedBefore = try await service.perform { try await $0.captures.sample(CaptureSampleKey(eventID: eventID, phase: .before)) }
        #expect(savedBefore != nil, "the successful initial perception vanished when the later perception threw")
        #expect(await service.flush(within: .seconds(10)))
        await service.close()
    }
}
