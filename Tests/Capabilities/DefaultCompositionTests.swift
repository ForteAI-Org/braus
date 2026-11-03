import AutomationMCP
import AutomationRuntime
import Testing

@Suite
@MainActor
struct DefaultCompositionTests {
    @Test func allChannelsPreserveDefinitionsAndInstructions() {
        let channels: AutomationChannels = [.native, .web, .adapters]
        let tools = AutomationTools(session: DemoSession(), channels: channels)
        #expect(tools.toolDefinitions == AutomationTools.definitions(for: channels))
        #expect(tools.instructions == AutomationTools.instructions(for: channels))
    }

    @Test func defaultRegistrationPreservesDefinitionsAndInstructions() {
        let tools = AutomationTools(session: DemoSession())
        #expect(tools.toolDefinitions == AutomationTools.definitions)
        #expect(tools.instructions == AutomationTools.instructions)
    }
}
