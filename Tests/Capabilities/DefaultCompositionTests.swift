import AutomationMCP
import Testing

@Suite
@MainActor
struct DefaultCompositionTests {
    @Test func defaultRegistrationPreservesDefinitionsAndInstructions() {
        let tools = AutomationTools(session: DemoSession())
        #expect(tools.toolDefinitions == AutomationTools.definitions)
        #expect(tools.instructions == AutomationTools.instructions)
    }
}
