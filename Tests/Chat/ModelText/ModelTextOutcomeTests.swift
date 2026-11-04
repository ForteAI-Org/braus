import EngineCore
import Memory
import LocalMCP
import Foundation
import Testing
@testable import AutomationMCP

struct ModelTextOutcomeTests {
    @Test func reviewedOutcomeTextsAreCatalogued() throws {
        for key in ["outcome.protected_path", "outcome.committing_input.consent", "outcome.committing_input.unverifiable",
                    "outcome.choice.read_back_unavailable", "outcome.choice.selected", "outcome.choice.unconfirmed",
                    "outcome.command.observation_failure", "outcome.command.observation_recovery",
                    "outcome.command.windows_changing", "outcome.command.windows_changing_recovery"] {
            let entry = try #require(ModelText.catalogue.first { $0.key.rawValue == key })
            #expect(!entry.legacy)
            #expect(entry.text.count <= entry.budgetCharacters)
        }
    }

    @Test func canonicalOutcomeEntriesKeepTheirCataloguedText() {
        for entry in ModelText.catalogue where entry.key.rawValue.hasPrefix("outcome.") {
            #expect(ModelText.text(entry.key) == entry.text)
        }
    }

    @Test func canonicalWordingAndLegendAreUsed() {
        for entry in ModelText.catalogue where entry.text.contains("acted_unverified") {
            #expect(!ModelText.text(entry.key).contains("acted_unverified"))
        }
        let instructions = ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5"))
        #expect(instructions.components(separatedBy: "Action results start with").count == 2)
    }
}

extension ModelTextOutcomeTests {
    @Test func screenExpectationObservationsBelongToCatalogue() {
        let texts = Set(ModelText.catalogue.map(\.text))
        #expect(texts.contains(ScreenExpectation.window(title: "Export", open: true)
            .judge(windows: ["Export"], scene: nil).observed))
    }
}

extension ModelTextOutcomeTests {
    @Test func schemaProblemMinimizesItsPath() throws {
        let problem = try #require(SchemaValidation.firstProblem(.object(["private-name": .string("value")]),
            schema: .object(["type": .string("object"), "properties": .object([:]),
                "additionalProperties": .bool(false)])))
        let text = ModelText.schemaProblem(problem, minimizing: ValueMinimization(secrets: ["private-name"]))
        #expect(!text.contains("private-name"))
        #expect(text.contains(ValueMinimization.marker))
        #expect(text.hasSuffix("Unknown argument."))
    }
}
