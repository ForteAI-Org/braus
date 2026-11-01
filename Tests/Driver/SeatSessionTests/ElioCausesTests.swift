import EngineCore
import SeatCore
import SeatInput
import SeatSession
import Testing
@testable import SeatDriving

struct ElioCausesTests {
    @Test func humanAndExpiredAuthority() {
        let human = SeatActuator.unsent(InputFailure.inputPaused([.humanIntervention]))
        #expect(human?.reason == "human_intervention")
        let expired = SeatActuator.unsent(InputFailure.inputPaused([.inputAuthorityExpired]))
        #expect(expired?.reason == "input_authority_expired")
        #expect(pauseReasons(of: InputFailure.inputPaused([.humanIntervention])) == [.humanIntervention])
    }

    @Test func unreadSelectionRemainsUncertain() {
        #expect(SeatActuator.unsent(RemoteContentActuationRefusal.selectionNotVerified("AXRow")) == nil)
        #expect(SeatActuator.unsent(RemoteContentActuationRefusal.selectedNotOpened(code: nil)) == nil)
    }

}
