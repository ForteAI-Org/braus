import Testing
@testable import AutomationMCP

struct LegendTextsTests {
    @Test
    func pastTheEdgeExplained() {
        let entries = ModelText.catalogue.filter { $0.delivery == .legend }
            .filter { $0.key.rawValue.contains("sceneLegend") || $0.key.rawValue.contains("changesLegend") }
        let text = entries.map(\.text).joined()
        for phrase in ["## past the window's edge (read only, not visible)", "no id", "never a target",
                       "selection or caret", "shared id and count", "… N more · observe section \"X\""] {
            #expect(text.contains(phrase))
        }
        #expect(text.count <= 900)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { !$0.legacy && $0.owner == "perception" })
        #expect(validate(entries, context: RuleContext()).isEmpty)
    }
}
