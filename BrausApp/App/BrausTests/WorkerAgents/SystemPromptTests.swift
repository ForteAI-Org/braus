import AutomationRuntime
import LocalMCP
import AutomationMCP
import Testing
import Turn
@testable import Braus

@MainActor
@Suite("SystemPrompt worker composition")
struct WorkerSystemPromptTests {
    @Test func workerLoopUsesTheRunnerComposition() {
        let lists = [[], ["observe"], ["plan", "end"],
            AutomationTools.definitions(for: .all).compactMap { $0["name"].string }]
        for names in lists {
            let tools = AutomationTools.instructions
            let actual = WorkerLoopInstructions(toolNames: names).systemText(
                role: "Help with care.", hasTools: true, tools: tools)
            let expected = TurnRunner.systemPrompt(role: "Help with care.", tools: tools, toolNames: names)
            #expect(actual == expected)
            #expect(WorkerAgentHost.instructions(role: "Help with care.", tools: tools, toolNames: names) == expected)
            #expect(actual.contains("## Identity"))
            #expect(!actual.contains("memory_task"))
        }
    }
}
