import EngineCore
import SeatSession
import Testing
@testable import SeatDriving

struct RemoteRefusalCatalogueTests {
    static let refusals: [RemoteContentActuationRefusal] = [
        .gestureUnmeasured, .pixelDropdown, .noElementAtPoint, .outsideRemoteContent, .unreadable,
        .fieldRequiresClick, .unsupportedRole("AXRow"), .unsupportedRole("AXButton"),
        .unsupportedRole("AXTextField"), .unsupportedRole("fake-role"), .opensMenu("AXMenuButton"),
        .opensMenu("AXPopUpButton"), .columnView, .wrongElement(requested: "fake-label", foundRole: "fake-role"),
        .webContent, .actionRefused(action: "fake-action", code: -25206), .selectionNotVerified("fake-role"),
        .selectedNotOpened(code: nil), .actionRefused(action: "fake-action", code: -25205)
    ]

    @Test(arguments: refusals)
    func everyCodeHasDistinctBoundedText(_ refusal: RemoteContentActuationRefusal) {
        let outcome = Outcome(gesture: refusal.mayHaveTakenEffect ? .uncertain : .notSent,
                              effect: .notApplicable, recovery: .doNotRepeat)
        let text = OutcomeText.message(OutcomeKey(outcome: outcome, verb: "click",
                                                  cause: "remote_content_refused." + refusal.code), label: nil)
        #expect(text.count <= 160)
        for value in ["fake-role", "fake-label", "fake-action", "AX", "-25206", "-25205", "Observe"] {
            #expect(!text.contains(value))
        }
        #expect(text != "No input was sent.")
    }

    @Test(arguments: refusals)
    func typedTransport(_ refusal: RemoteContentActuationRefusal) {
        let error = SeatActuator.deliveryError(refusal)
        if refusal.mayHaveTakenEffect {
            #expect((error as? GestureEffectUncertain)?.cause == "remote_content_refused." + refusal.code)
            #expect((error as? GestureEffectUncertain)?.description == refusal.description)
            #expect(error as? GestureNotSent == nil)
        } else {
            #expect((error as? GestureNotSent)?.reason == "remote_content_refused." + refusal.code)
            #expect((error as? GestureNotSent)?.sentence == refusal.description)
        }
    }
}
