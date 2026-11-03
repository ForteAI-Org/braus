import EngineCore
import SeatCore
import SeatInput
import SeatSession
import Switches
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

    @Test(arguments: ["v1", "v2"])
    func postedCommandsStayInterrupted(_ arm: String) {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": arm])) {
            let receipt = InputReceipt(eventCount: 2, route: InputRoute(
                poster: .publicProcess, routedEventCount: 0, windowNumber: 1, ownerConnectionID: 2))
            let sequence = InputSequenceFailure(completedReceipts: [receipt],
                                                cause: InputFailure.inputPaused([.humanIntervention]))
            let native = NativeTextInputFailure(cause: sequence, cleanup: .notRequired)
            for failure: any Error in [sequence, native] {
                #expect(pauseReasons(of: failure).isEmpty)
                #expect(SeatActuator.unsent(failure) == nil)
                #expect(SeatActuator.deliveryError(failure) is GestureInterrupted)
            }
        }
    }

}
