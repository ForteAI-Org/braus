import EngineCore
import Testing

struct MisleadingMessageTests {
    @Test func remoteCatalogueIsBoundedAndHasNoNextObservation() {
        let codes = ["gesture_unmeasured", "pixel_dropdown", "no_element_at_point", "outside_remote_content",
                     "unreadable", "field_requires_click", "row_not_text", "control_not_text", "text_field_clicks",
                     "nothing_clickable", "opens_menu", "opens_list", "column_view", "wrong_element", "web_content",
                     "action_unsupported", "selection_not_verified", "selected_not_opened", "action_refused"]
        let outcome = Outcome(gesture: .notSent, effect: .notApplicable, recovery: .changeTarget(.unreachable))
        let texts = codes.map { OutcomeText.message(OutcomeKey(outcome: outcome, verb: "click",
            cause: "remote_content_refused." + $0), label: "fake-private-value") }
        #expect(Set(texts).count == codes.count)
        for text in texts {
            #expect(text.count <= 160)
            for forbidden in ["observe", "perceive", "look again", "describe_scene", "fake-private-value", "AXPopUpButton"] {
                #expect(!text.lowercased().contains(forbidden.lowercased()))
            }
        }
        #expect(!texts[11].contains("menu"))
    }

    @Test func genericSeatErrorIsNeutral() {
        let outcome = Outcome(gesture: .uncertain, effect: .unknown(.notReadable), recovery: .doNotRepeat)
        #expect(OutcomeText.message(OutcomeKey(outcome: outcome, verb: "click", cause: "seat_error"), label: nil)
            == "The seat reported an error it does not describe.")
    }
}
