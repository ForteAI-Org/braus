import EngineCore
import Testing

struct OutcomeTextTests {
    @Test func boundedCatalogueAndStructuralCauses() {
        for kind in ActOutcomeKind.allCases {
            for cause in NotSentCause.allCases {
                let outcome = Outcome.converting(kind, check: nil, notSent: cause, noop: nil, sceneAttached: false)
                let text = OutcomeText.message(OutcomeKey(outcome: outcome, verb: "click"),
                                               label: String(repeating: "x", count: 48))
                #expect(text.count <= 160)
                #expect(!text.lowercased().contains("observe") || outcome.recovery == .observe)
            }
        }
        let outcome = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat)
        let first = OutcomeKey(outcome: outcome, verb: "click", cause: "remote_content_refused.opens_list")
        let second = OutcomeKey(outcome: outcome, verb: "click", cause: "remote_content_refused.wrong_element")
        #expect(OutcomeText.message(first, label: nil) != OutcomeText.message(second, label: nil))
        #expect(OutcomeKey(outcome: outcome, verb: "click", cause: "endpoint_refused#42").cause == "endpoint_refused")
        #expect(OutcomeKey(outcome: outcome, verb: "click", cause: "fake private value").cause == nil)
    }
}
