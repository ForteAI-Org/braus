import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionStringsTests {
    private typealias Token = HumanInterventionStrings.Token

    @Test func operatorsAndOverlappingNamesAreNeverReplacedAsSubstrings() {
        let tokens: [[Token]] = [
            [.operand("→ Piano 1"), .literal(" → "), .operand("Piano 1")],
            [.operand("A very long Piano 1 name"), .literal(" → "), .operand("Piano 1")],
            [.operand("A very long Piano 1 name")]
        ]
        let strings = HumanInterventionStrings(tokens: tokens)
        let text = strings.render(tokens)
        #expect(text.contains("→ Piano 1 → Piano 1"))
        #expect(!text.contains("§3 §3"))
        #expect(text.contains("§1 → Piano 1"))
    }

    @Test func literalSectionSignsAreNotReferences() {
        let tokens: [[Token]] = [[.literal("§1 is literal")], [.operand("A repeated long operand")], [.operand("A repeated long operand")]]
        let strings = HumanInterventionStrings(tokens: tokens)
        #expect(strings.render([[.literal("§1 is literal")]]) == "§1 is literal")
        #expect(!strings.render([[.literal("§1 is literal")]]).contains("="))
    }

    @Test func quotingNewlinesAndEmojiStayInOperandDefinitions() {
        let label = "Name \"Quoted\"\n🎹🎹🎹🎹"
        let tokens: [[Token]] = [[.operand(label)], [.operand(label)], [.operand(label)]]
        let strings = HumanInterventionStrings(tokens: tokens)
        let rendered = strings.render(tokens)
        #expect(rendered.contains(String(reflecting: label)))
        #expect(strings.value("§1") == label)
        #expect(strings.render([[.literal("Nothing repeated")]]) == "Nothing repeated")
    }
}
