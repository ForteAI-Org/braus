@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import LocalMCP
import Testing

@MainActor
struct GestureExpectSchemaTests {
    @Test func individualGesturesExcludeExpectAndRejectItBeforeExecution() throws {
        for definition in ToolCatalogue.availableDefinitions(for: []) {
            let name = definition["name"].string ?? ""
            if ["act", "select", "menu", "press", "type_text", "insert_text", "press_key",
                "scroll", "drag", "context_menu"].contains(name) {
                #expect(definition["inputSchema"]["properties"]["expect"] == .null)
            }
        }
        #expect(throws: AutomationFailure.self) {
            _ = try ToolArguments.Step("act", .object(["target": .string("Save"),
                "expect": .object(["window": .string("Export")])]))
        }
        _ = try ToolArguments.Step("act", .object(["target": .string("Save"),
            "expect": .object(["window": .string("Export")])]), inBatch: true)
    }

    @Test func sharedBatchDecoderKeepsPredicates() throws {
        #expect(try ToolArguments.expectation(from: ["element": "Display", "value": "123"])
            == .element(label: "Display", expect: .value("123")))
        #expect(try ToolArguments.expectation(from: ["window": "Export", "open": false])
            == .window(title: "Export", open: false))
        #expect(throws: AutomationFailure.self) {
            _ = try ToolArguments.expectation(from: ["file_written": "/tmp/output"])
        }
    }
}
