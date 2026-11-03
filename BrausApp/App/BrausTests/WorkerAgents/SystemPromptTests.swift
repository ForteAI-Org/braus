import AutomationRuntime
import LocalMCP
import AutomationMCP
import Switches
import Testing
import Turn
@testable import Braus

@MainActor
@Suite("SystemPrompt worker composition")
struct WorkerSystemPromptTests {
    @Test func workerLoopUsesTheRunnerComposition() {
        for version in ["v1", "v2"] {
            SwitchBoard.$testing.withValue(SwitchBoard(values: ["prompt": version, "tool_surface": "v2"])) {
                let lists = [[], ["observe"], ["memory_task"], ["plan", "end"],
                    AutomationTools.definitions(for: .all).compactMap { $0["name"].string }]
                for names in lists {
                    let tools = AutomationTools.instructions
                    let actual = WorkerLoopInstructions(toolNames: names).systemText(
                        role: "Help with care.", hasTools: true, tools: tools)
                    let expected = TurnRunner.systemPrompt(role: "Help with care.", tools: tools, toolNames: names)
                    #expect(actual == expected)
                    #expect(WorkerAgentHost.instructions(role: "Help with care.", tools: tools,
                        toolNames: names) == expected)
                    if version == "v1" {
                        #expect(actual == TurnInstructions.compose(role: "Help with care.", tools: tools))
                    } else {
                        #expect(actual.contains("## Identity"))
                    }
                }
            }
        }
    }
}
