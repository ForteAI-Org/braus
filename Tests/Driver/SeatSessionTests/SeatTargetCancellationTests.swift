import EngineCore
import SeatCore
import SeatSession
import Switches
import Testing
@testable import SeatDriving

struct SeatTargetCancellationTests {
    @MainActor
    @Test func cancelledObserveStopsBeforeAccessingTheSeat() async {
        let target = SeatTarget()
        let read = Task { try await target.observe() }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test(arguments: ["off", "on"])
    func remotePartialEffectKeepsItsHistoricalWords(_ arm: String) {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v1", "scene_after_uncertain": arm])) {
            let refusal = RemoteContentActuationRefusal.selectionNotVerified("AXRow")
            let error = SeatActuator.deliveryError(refusal)
            #expect(String(describing: error) == refusal.description)
            if arm == "on" { #expect((error as? GestureMayHaveActed)?.sentence == refusal.description) }
            else { #expect(error as? RemoteContentActuationRefusal == refusal) }
        }
    }
}
