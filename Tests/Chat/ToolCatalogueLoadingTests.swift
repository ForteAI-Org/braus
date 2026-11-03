@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Memory
import SQLiteMemory
import Switches
import Testing

@MainActor
struct ToolCatalogueLoadingTests {
    private func board(_ loading: String? = nil) -> SwitchBoard {
        var values = ["tool_surface": "v2", "task_cycle": "v2"]
        values["tool_loading"] = loading
        return SwitchBoard(values: values)
    }

    @Test func coreToolsCarryAlwaysLoad() throws {
        try SwitchBoard.$testing.withValue(board("harnessSearch")) {
            let tools = AutomationTools(session: ToolResultSession(), channels: [.adapters])
            let definitions = tools.toolDefinitions
            let names = definitions.compactMap { $0["name"].string }
            #expect(!names.contains("find"))
            #expect(!names.contains("call"))
            let registry = try CapabilityRegistry(core: ToolCatalogue.contracts(for: [.adapters]), registered: [])
            let entries = ToolCatalogue.catalogue(channels: [.adapters], registry: registry)
            for definition in definitions {
                let name = try #require(definition["name"].string)
                if ToolList.core.contains(.init(rawValue: name)) {
                    #expect(definition["_meta"]["anthropic/alwaysLoad"] == .bool(true))
                } else {
                    let entry = try #require(entries.first { $0.contract.id.rawValue == name })
                    #expect(definition["inputSchema"] == entry.contract.inputSchema)
                    #expect(definition["description"] == .string(entry.contract.description))
                    #expect(definition["_meta"] == .null)
                }
            }
            for name in ["select", "scroll", "windows", "files.list"] {
                #expect(names.contains(name))
            }
            SwitchBoard.$testing.withValue(board()) { #expect(tools.toolDefinitions == definitions) }
        }
    }

    @Test func harnessSearchListsRareToolsDeferredAtObserveLevel() {
        SwitchBoard.$testing.withValue(board("harnessSearch")) {
            let tools = AutomationTools(session: ToolResultSession(), channels: [.adapters],
                list: .init(attendance: .client, level: .observe))
            let definitions = tools.toolDefinitions
            #expect(definitions.contains { $0["name"].string == "windows" })
            #expect(!definitions.contains { ["select", "scroll", "find", "call"].contains($0["name"].string ?? "") })
            for definition in definitions where definition["name"].string != "open_session" {
                #expect(definition["annotations"]["readOnlyHint"] == .bool(true))
            }
        }
    }

    @Test func registeredCapabilityUsesTheSameCallValidation() async throws {
        try await SwitchBoard.$testing.withValue(board("harnessSearch")) {
            let provider = ToolLoadingRead()
            let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
            #expect(tools.toolDefinitions.contains { $0["name"].string == "sample.read" })
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            _ = await router.handle(request("sample.read", .object(["count": .number(1)])))
            #expect(await provider.calls == 1)
            let invalid = try #require(await router.handle(request("sample.read", .object(["count": .string("bad")]))))
            #expect(invalid["result"]["isError"] == .bool(true))
            #expect(await provider.calls == 1)
        }
    }

    @Test func legacySurfaceKeepsItsExistingCallPath() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_loading": "harnessSearch"])) {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            let sessionID = try #require(session.id)
            let response = try #require(await router.handle(request("select", .object([
                "session": .string(sessionID.uuidString),
                "control": .string("Mode"), "item": .string("Stereo")]))))
            #expect(response["result"]["isError"] == .bool(false))
            #expect(session.calls == ["select"])
        }
    }

    @Test func upfrontListAndArgvAreIdentical() async throws {
        let implicit = SwitchBoard.$testing.withValue(board()) { AutomationTools(session: ToolResultSession()) }
        let explicit = SwitchBoard.$testing.withValue(board("upfront")) { AutomationTools(session: ToolResultSession()) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(implicit.toolDefinitions) == encoder.encode(explicit.toolDefinitions))
        let baseline = SwitchBoard.$testing.withValue(board()) {
            ToolCatalogue.definitions(for: ToolList(attendance: .app, level: .actConnectors), channels: [])
        }
        #expect(try encoder.encode(explicit.toolDefinitions) == encoder.encode(baseline))
        let router = MCPRouter(tools: explicit.toolDefinitions, instructions: nil, call: explicit.call)
        let response = try #require(await router.handle(request("select", .object([:]))))
        #expect(response["error"]["message"].string == "Unknown tool.")
    }

    private func request(_ name: String, _ arguments: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments])])
    }

    @Test func rareToolKeepsPlanBarrier() async throws {
        let session = ToolResultSession()
        let tools = SwitchBoard.$testing.withValue(board("harnessSearch")) { AutomationTools(session: session) }
        _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let response = try #require(await router.handle(request("select", .object([
            "control": .string("Mode"), "item": .string("Stereo")]))))
        #expect(response["result"]["isError"] == .bool(true))
        #expect(response["result"]["content"].array?.first?["text"].string?.contains("Call plan first") == true)
        #expect(session.calls == ["open"])
    }

    @Test func rareToolRecordsItsRealName() async throws {
        let directory = URL.temporaryDirectory.appending(path: "tool-loading-record-" + UUID().uuidString)
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let direct = SwitchBoard.$testing.withValue(board("harnessSearch")) { AutomationTools(session: session) }
        let delegated = SwitchBoard.$testing.withValue(board()) { AutomationTools(session: session) }
        let arguments: JSONValue = .object(["control": .string("Mode"), "item": .string("Stereo")])
        let router = MCPRouter(tools: direct.toolDefinitions, instructions: nil, call: direct.call)
        let response = try #require(await router.handle(request("select", arguments)))
        #expect(response["result"]["isError"] == .bool(false))
        _ = try await delegated.call("call", .object(["name": .string("select"), "arguments": arguments]))
        _ = await router.handle(request("select", .object(["control": .number(1)])))
        let memory = MemoryService.shared(for: directory)
        let records = try await memory.perform { repositories in
            try await repositories.store.read {
                try $0.query("SELECT tool_kind FROM memory_agent_actions") { try $0.text(0) }
            }
        }
        #expect(records == ["select", "select"])
        #expect(session.calls == ["select", "select"])
        await memory.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func rareToolRunsLikeCall() async throws {
        for arguments: JSONValue in [.object(["control": .string("Mode"), "item": .string("Stereo")]),
                                     .object(["control": .number(1)]),
                                     .object(["control": .string("Mode"), "item": .string("Stereo"), "step": .string("r1")])] {
            let directSession = ToolResultSession()
            let callSession = ToolResultSession()
            callSession.id = directSession.id
            let direct = SwitchBoard.$testing.withValue(board("harnessSearch")) { AutomationTools(session: directSession) }
            let delegated = SwitchBoard.$testing.withValue(board()) { AutomationTools(session: callSession) }
            var directLines: [String] = []
            var callLines: [String] = []
            direct.record = { directLines.append($0) }
            delegated.record = { callLines.append($0) }
            var directFacts: [TaskStateInput.Fact] = []
            var callFacts: [TaskStateInput.Fact] = []
            direct.observeTaskState { directFacts.append($0.fact) }
            delegated.observeTaskState { callFacts.append($0.fact) }
            let router = MCPRouter(tools: direct.toolDefinitions, instructions: nil, call: direct.call)
            let other = MCPRouter(tools: delegated.toolDefinitions, instructions: nil, call: delegated.call)
            let first = await router.handle(request("select", arguments))
            let second = await other.handle(request("call", .object(["name": .string("select"), "arguments": arguments])))
            #expect(first == second)
            #expect(try ToolGolden.normalized(.array(directLines.map(JSONValue.string)))
                == ToolGolden.normalized(.array(callLines.map(JSONValue.string))))
            #expect(directFacts == callFacts)
            #expect(directSession.calls.count == callSession.calls.count)
            #expect(directSession.inputs.count == callSession.inputs.count)
        }
    }
}

private actor ToolLoadingRead: CapabilityProviding {
    nonisolated let family = "sample"
    var calls = 0
    nonisolated var contracts: [CapabilityContract] {
        [.init(id: .init(rawValue: "sample.read"), group: "inspection", description: "Read a count.",
            inputSchema: .object(["type": .string("object"), "properties": .object([
                "count": .object(["type": .string("integer")])]),
                "required": .array([.string("count")]), "additionalProperties": .bool(false)]),
            effect: .read, interruption: .readOnly, verification: .none(reason: "read only"),
            channel: .braus, origin: .registered(provider: "sample"), memory: .capabilityStep, takesSession: false)]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        calls += 1
        return .object(["count": arguments["count"]])
    }
}
