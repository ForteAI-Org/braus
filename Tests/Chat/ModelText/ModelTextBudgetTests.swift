import AutomationRuntime
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

struct ModelTextBudgetTests {
    @Test
    func catalogueBudget() {
        #expect(!ModelText.catalogue.isEmpty)
        #expect(validate(ModelText.catalogue, context: RuleContext()).filter { $0.code == .budget }.isEmpty)
    }
}

extension ModelTextBudgetTests {
    @Test
    func negativeBudgets() {
        #expect(validate([specimen("Read.", budget: 5)], context: RuleContext()).isEmpty)
        #expect(validate([specimen("Read.", budget: 4)], context: RuleContext()).contains { $0.code == .budget })
        #expect(validate([specimen(String(repeating: "a", count: 161), delivery: .toolAnswer(tool: "act"))], context: RuleContext()).contains { $0.code == .budget })
        #expect(validate([specimen(String(repeating: "a", count: 15_001), budget: 16_000)], context: RuleContext()).contains { $0.code == .budget })
    }
}

extension ModelTextBudgetTests {
    @Test
    func encodedDefinitionsCountTowardBudget() {
        let valid = specimen("Read the scene.", delivery: .toolDescription(tool: "observe"))
        #expect(validate([valid], context: RuleContext()).isEmpty)
        let escaped = specimen(String(repeating: "\"", count: 7_500),
                               delivery: .toolDescription(tool: "observe"), budget: 8_000)
        #expect(validate([escaped], context: RuleContext()).contains { $0.code == .budget })
    }

    @Test
    @MainActor
    func renderedFixedPart() throws {
        for bits in 0..<8 {
            var channels: AutomationChannels = []
            if bits & 1 != 0 { channels.insert(.native) }
            if bits & 2 != 0 { channels.insert(.web) }
            if bits & 4 != 0 { channels.insert(.adapters) }
            let instructions = AutomationTools.instructions(for: channels)
            let definitions = try JSONValue.canonicalEncoder().encode(JSONValue.array(AutomationTools.definitions(for: channels)))
            let characters = instructions.count + String(decoding: definitions, as: UTF8.self).count
            print("Legacy fixed text channels=\(bits): \(characters) characters")
            #expect(characters > 0)
        }
    }
}
