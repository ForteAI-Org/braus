@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import LocalMCP
import Switches
import Testing

@MainActor
struct GestureExpectSchemaTests {
    @Test func offIsIdenticalToDefaultAndMenuPressNeverOfferExpect() throws {
        let defaults = SwitchBoard.$testing.withValue(SwitchBoard()) { AutomationTools.definitions }
        let off = SwitchBoard.$testing.withValue(SwitchBoard(values: ["expect": "off"])) { AutomationTools.definitions }
        #expect(defaults == off)
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["expect": "off"])) {
            #expect(throws: (any Error).self) {
                _ = try ToolArguments.Step("act", .object(["target": .string("Save"), "expect": .object(["window": .string("Export")])]))
            }
        }
        for arm in ["off", "on"] {
            SwitchBoard.$testing.withValue(SwitchBoard(values: ["expect": arm])) {
                for definition in AutomationTools.definitions {
                    let name = definition["name"].string ?? ""
                    if ["menu", "press"].contains(name) {
                        #expect(definition["inputSchema"]["properties"]["expect"] == .null)
                    }
                    if ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu"].contains(name) {
                        #expect((definition["inputSchema"]["properties"]["expect"] != .null) == (arm == "on"))
                    }
                }
            }
        }
    }

    @Test func publicDecoderWorksWithoutTheSchemaArm() throws {
        #expect(try ToolArguments.expectation(from: ["element": "Display", "value": "123"])
            == .element(label: "Display", expect: .value("123")))
        #expect(try ToolArguments.expectation(from: ["window": "Export", "open": false])
            == .window(title: "Export", open: false))
        #expect(throws: AutomationFailure.self) {
            _ = try ToolArguments.expectation(from: ["file_written": "/tmp/output"])
        }
    }
}
