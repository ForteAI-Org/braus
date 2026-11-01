import Foundation
import Switches
import Testing
@testable import AutomationMCP

struct ModelTextOutcomeTests {
    @Test func v1KeepsEveryEntry() {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v1"])) {
            for entry in ModelText.catalogue {
                #expect(ModelText.text(entry.key) == entry.text)
            }
        }
    }

    @Test func v2UsesOutcomeWordingAndOneLegend() {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            for entry in ModelText.catalogue where entry.text.contains("acted_unverified") {
                #expect(!ModelText.text(entry.key).contains("acted_unverified"))
            }
            let instructions = ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5"))
            #expect(instructions.components(separatedBy: "Action results start with").count == 2)
        }
    }
}
