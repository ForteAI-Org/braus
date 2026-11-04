import AutomationMCP
import AutomationRuntime
import Testing

@MainActor
struct SeatTaskFactsTests {
    @Test func taskFactsAreReadOnlyAndLeaveUnknownCountsAbsent() async {
        let tools = AutomationTools(session: ToolResultSession())
        let first = await tools.taskFacts(for: "org.example")
        #expect(first == SeatTaskFacts())
        #expect(await tools.taskFacts(for: nil) == first)
        #expect(tools.openTask == nil)
        #expect(tools.takeStoppedTaskNotice() == nil)
    }

    @Test func structuredInstructionsAreUsedForEveryChannelSet() {
        for bits in 0..<8 {
            var channels: AutomationChannels = []
            if bits & 1 != 0 { channels.insert(.native) }
            if bits & 2 != 0 { channels.insert(.web) }
            if bits & 4 != 0 { channels.insert(.adapters) }
            let text = AutomationTools.instructions(for: channels)

            #expect(!text.contains("call status and observe"))
            #expect(!text.contains("windows, then open_session"))
            #expect(text.contains("plan") && text.contains("end"))
        }
    }
}
