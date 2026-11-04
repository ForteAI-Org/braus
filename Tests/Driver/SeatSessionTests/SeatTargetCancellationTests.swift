import EngineCore
import SeatCore
import SeatSession
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

    @Test
    func remotePartialEffectKeepsItsTypedCauseAndDiagnostic() {
        let refusal = RemoteContentActuationRefusal.selectionNotVerified("AXRow")
        let error = SeatActuator.deliveryError(refusal)
        #expect(String(describing: error) == refusal.description)
        #expect((error as? GestureEffectUncertain)?.cause == "remote_content_refused." + refusal.code)
        #expect((error as? GestureEffectUncertain)?.description == refusal.description)
        #expect(error as? GestureNotSent == nil)
    }
}
