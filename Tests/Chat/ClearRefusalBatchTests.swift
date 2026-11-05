@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@MainActor
struct ClearRefusalBatchTests {
    @Test(arguments: ["Cancella", "Clear all"])
    func realRouterBatchRefusesUnqualifiedClear(_ label: String) async throws {
        let session = ToolResultSession()
        let clear = SceneElement(id: "clear", kind: .control, label: label, bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), role: "AXButton")
        let next = SceneElement(id: "next", kind: .control, label: "Next", bounds: .init(x: 0.3, y: 0.1, width: 0.1, height: 0.1), role: "AXButton")
        session.scene.elements = [clear, next]
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let args: JSONValue = .object(["steps": .array([
            .object(["operation": .string("act"), "target": .string(label)]),
            .object(["operation": .string("act"), "target": .string("Next")])])])
        let result = try #require(await router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("batch"), "arguments": args])])))["result"]
        #expect(result["isError"].bool == false)
        #expect(!session.calls.contains(label) && !session.calls.contains("Next"))
    }
}
