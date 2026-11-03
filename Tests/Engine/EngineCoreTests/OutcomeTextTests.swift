import EngineCore
import PerceptionCore
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
    @Test func quotesThirdPartyText() {
        let quoted = OutcomeText.quoted("Title's\nnext\rline\u{2028}" + String(repeating: "x", count: 80))
        #expect(quoted.hasPrefix("'Title\\'s next line "))
        #expect(quoted.hasSuffix("'"))
        #expect(quoted.count <= 48)
        #expect(!quoted.contains("\n") && !quoted.contains("\r") && !quoted.contains("\u{2028}"))
        let closure = ActionPolicy.windowClosureRefusal("Escape", window: "Title's\nnext", application: "App\nname",
                                                         alternatives: ["Don't\nclose"])
        #expect(closure.contains(OutcomeText.quoted("Title's\nnext")))
        #expect(closure.contains(OutcomeText.quoted("App\nname")))
        #expect(!closure.contains("\n"))
    }
    @Test func quotesEveryEffectValue() {
        let text = "Title's\nnext"
        #expect(OutcomeText.summary(.windowTitleChanged(title: text)) == "navigates to " + OutcomeText.quoted(text))
        #expect(OutcomeText.summary(.menuOpened(labels: [text])).contains(OutcomeText.quoted(text)))
        #expect(OutcomeText.summary(.valueChanged(label: text, value: text))
            == OutcomeText.quoted(text) + " now reads " + OutcomeText.quoted(text))
        for text in [String(repeating: "'", count: 60), String(repeating: "\\", count: 60), "\u{0}\t\u{7F}\u{2029}"] {
            #expect(OutcomeText.quoted(text).count <= 48)
            #expect(!OutcomeText.quoted(text).contains("\u{0}"))
        }
    }
}
