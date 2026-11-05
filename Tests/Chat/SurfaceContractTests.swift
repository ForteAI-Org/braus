@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Testing

@MainActor
struct SurfaceContractTests {
    @Test func measuredCatalogueParts() throws {
        for tool in AutomationTools.definitions(for: .all) {
            print("CONTRACT_PART \(tool["name"].string ?? "unknown") \(try JSONValue.canonicalEncoder().encode(tool).count)")
        }
    }

    @Test func observeInstructionsPrescribeOnlyAvailableTools() {
        let tools = AutomationTools(session: ToolResultSession(), profile: .init(attendance: .client,
            level: .observe, memory: .read, catalogue: .open, takeover: false, options: .init(), name: "client"))
        let prompt = ModelText.systemPrompt(toolNames: tools.toolDefinitions.compactMap { $0["name"].string },
            groupIndex: tools.groupIndex, searchesWeb: false, role: nil)
        for name in ["plan", "end", "step"] {
            #expect(!prompt.contains("`\(name)`"))
            #expect(!tools.clientInstructions(.full).contains(name))
        }
    }

    @Test func batchRequiresTheArgumentsOfItsOperation() throws {
        let tools = AutomationTools(session: ToolResultSession())
        let definition = try #require(tools.toolDefinitions.first { $0["name"].string == "batch" })
        var fields = try #require(definition["inputSchema"].object)
        var properties = try #require(fields["properties"]?.object)
        properties.removeValue(forKey: "step")
        fields["properties"] = .object(properties)
        let schema = JSONValue.object(fields)
        let valid: JSONValue = .object(["steps": .array([.object(["operation": .string("act"), "target": .string("Public")])])])
        #expect(SchemaValidation.firstProblem(valid, schema: schema) == nil)
        for op in ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu", "menu"] {
            let args: JSONValue = .object(["steps": .array([.object(["operation": .string(op)])])])
            #expect(SchemaValidation.firstProblem(args, schema: schema) != nil)
        }
        let bad: JSONValue = .object(["steps": .array([.object(["operation": .string("act"), "target": .string("Public"),
            "expect": .object(["window": .string("Public"), "open": .string("false")])])])])
        #expect(SchemaValidation.firstProblem(bad, schema: schema) != nil)
    }
}
