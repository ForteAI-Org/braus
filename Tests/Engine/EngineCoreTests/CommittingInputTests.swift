import EngineCore
import PerceptionCore
import Testing

struct CommittingInputTests {
    private func field(_ label: String, role: String = "AXTextField") -> SceneElement {
        SceneElement(id: "field", kind: .control, label: label,
                     bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), role: role)
    }

    @Test(arguments: [
        ("Message", "AXTextField", true, true),
        ("Message", "AXSearchField", true, false),
        ("Search mail", "AXTextField", true, false),
        ("Reply", "AXTextArea", false, true),
        ("Name", "AXTextField", false, false),
        ("Message", "AXButton", true, false),
        ("Find message", "AXTextField", true, false),
        ("Cerca messaggio", "AXTextField", true, false),
        ("Filter", "AXComboBox", true, false),
        ("Commentary", "AXTextField", false, false),
        ("Messaggio", "AXTextField", false, true),
    ])
    func fields(label: String, role: String, surface: Bool, expected: Bool) {
        let target = field(label, role: role)
        #expect(ComposeField.isCompose(target, onCorrespondenceSurface: surface) == expected)
        #expect(CommittingInput.commits(.pressKey(KeyChord(.return), times: 1), into: .field(target),
                                       onCorrespondenceSurface: surface) == expected)
    }

    @Test func committingAndNoncommittingInputs() {
        let target = CommittingInput.Target.field(field("Reply"))
        for input in [.pressKey(KeyChord(.return, modifiers: .command), times: 1),
                                         .typeText("hello\n", into: "Reply", replacing: false),
                                         .insertText("hello\r")] as [InputRequest.Input] {
            #expect(CommittingInput.commits(input, into: target, onCorrespondenceSurface: false))
        }
        for input in [.pressKey(KeyChord(.return, modifiers: .shift), times: 1),
                                         .pressKey(KeyChord(.tab), times: 1), .insertText("hello")] as [InputRequest.Input] {
            #expect(!CommittingInput.commits(input, into: target, onCorrespondenceSurface: true))
        }
        let enter = InputRequest.Input.pressKey(KeyChord(.return), times: 1)
        #expect(CommittingInput.commits(enter, into: .unidentified, onCorrespondenceSurface: true))
        #expect(!CommittingInput.commits(enter, into: .unidentified, onCorrespondenceSurface: false))
    }
}
