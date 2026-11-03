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

    @Test func instructionSwitchDefaultsToLegacyForEveryChannelSet() {
        for bits in 0..<8 {
            var channels: AutomationChannels = []
            if bits & 1 != 0 { channels.insert(.native) }
            if bits & 2 != 0 { channels.insert(.web) }
            if bits & 4 != 0 { channels.insert(.adapters) }
            let original = AutomationTools.instructions(for: channels)
            #expect(AutomationTools.instructions(for: channels, seatLine: .v1) == original)
            let changed = AutomationTools.instructions(for: channels, seatLine: .v2)
            #expect(!changed.contains("call status and observe"))
            #expect(!changed.contains("windows, then open_session"))
            #expect(original.contains("call status and observe"))
        }
    }
}
