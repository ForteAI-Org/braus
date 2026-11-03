import EngineCore
import Testing
@testable import Engine

struct RefusalCauseTests {
    @Test func detailedCodesKeepTheirCategory() throws {
        let result = try #require(ActionEngine.notSent(
            GestureNotSent(reason: "remote_content_refused.opens_list#42", sentence: "A list opens here."),
            "clicked control"
        ))
        #expect(result.notSent == .targetUnreachable)
        #expect(result.cause == "remote_content_refused.opens_list")
        #expect(result.outcome.recovery == .changeTarget(.unreachable))
    }

    @Test(arguments: [
        ("human_intervention", NotSentCause.humanIntervention, Recovery.doNotRepeat),
        ("input_authority_expired", .inputAuthorityExpired, .observe),
        ("seat_not_ready", .seatNotReady, .retry),
    ])
    func actuatorCodes(_ code: String, _ cause: NotSentCause, _ recovery: Recovery) throws {
        let result = try #require(ActionEngine.notSent(GestureNotSent(reason: code, sentence: "No input."), "clicked"))
        #expect(result.notSent == cause)
        #expect(result.cause == code)
        #expect(result.outcome.recovery == recovery)
    }
}
