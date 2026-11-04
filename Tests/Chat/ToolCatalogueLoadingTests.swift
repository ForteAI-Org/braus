@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Memory
import SQLiteMemory
import Testing

@MainActor
struct ToolCatalogueLoadingTests {
    @Test func fixedCoreUsesExplicitDiscoveryWithoutNativeLoadingMetadata() {
        for channels: AutomationChannels in [[], [.adapters], .all] {
            let tools = AutomationTools(session: ToolResultSession(), channels: channels)
            #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ToolList.core.map(\.rawValue))
            #expect(!tools.toolDefinitions.contains { $0["_meta"]["anthropic/alwaysLoad"] != .null })
            for name in ["select", "scroll", "windows", "files.list"] {
                #expect(!tools.toolDefinitions.contains { $0["name"].string == name })
            }
            #expect(tools.configurationEvidence["tool_loading"].string == "upfront")
        }
    }

    @Test func observeProfileKeepsOnlyOpeningReadingAndExplicitDiscovery() {
        let tools = AutomationTools(session: ToolResultSession(), channels: [.adapters],
            profile: SessionProfile(attendance: .client, level: .observe, memory: .read, catalogue: .open,
                takeover: false, options: .init(), name: "client"))
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ["open_session", "observe", "find", "call"])
        #expect(tools.effectClass(of: "call", arguments: .object(["name": .string("windows"),
            "arguments": .object([:])])) == .read)
        #expect(tools.effectClass(of: "call", arguments: .object(["name": .string("scroll"),
            "arguments": .object(["direction": .string("down")])])) != .read)
    }

    @Test func registeredCapabilityUsesTheSameDelegatedValidation() async throws {
        let provider = ToolLoadingRead()
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "sample.read" })
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let valid = try #require(await router.handle(request("call", delegated("sample.read", .object(["count": .number(1)])))))
        #expect(valid["result"]["isError"] == .bool(false))
        #expect(await provider.calls == 1)
        let invalid = try #require(await router.handle(request("call", delegated("sample.read", .object(["count": .string("bad")])))))
        #expect(invalid["result"]["isError"] == .bool(true))
        #expect(await provider.calls == 1)
        let direct = try #require(await router.handle(request("sample.read", .object(["count": .number(1)]))))
        #expect(direct["error"]["code"] == .number(-32602))
        #expect(await provider.calls == 1)
    }

    @Test func anUnadvertisedRareToolRequiresCallAndCannotActDirectly() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let args: JSONValue = .object(["control": .string("Mode"), "item": .string("Stereo")])
        let direct = try #require(await router.handle(request("select", args)))
        #expect(direct["error"]["code"] == .number(-32602))
        #expect(session.calls.isEmpty)
        let response = try #require(await router.handle(request("call", delegated("select", args))))
        #expect(response["result"]["isError"] == .bool(false))
        #expect(session.calls == ["select"])
    }

    @Test func repeatedCompositionKeepsTheSameListAndRefusesUnknownNames() async throws {
        let first = AutomationTools(session: ToolResultSession())
        let second = AutomationTools(session: ToolResultSession())
        #expect(first.toolDefinitions == second.toolDefinitions)
        #expect(first.toolDefinitions == ToolCatalogue.definitions(for: ToolList(attendance: .app, level: .actConnectors), channels: []))
        let router = MCPRouter(tools: first.toolDefinitions, instructions: nil, call: first.call)
        let response = try #require(await router.handle(request("select", .object([:]))))
        #expect(response["error"]["message"].string == "Unknown tool.")
    }

    @Test func rareToolKeepsPlanBarrier() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let response = try #require(await router.handle(request("call", delegated("select", .object([
            "control": .string("Mode"), "item": .string("Stereo")])))))
        #expect(response["result"]["isError"] == .bool(true))
        #expect(response["result"]["content"].array?.first?["text"].string?.contains("Call plan first") == true)
        #expect(session.calls == ["open"])
    }

    @Test func rareToolRecordsItsRealName() async throws {
        let directory = URL.temporaryDirectory.appending(path: "tool-loading-record-" + UUID().uuidString)
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session)
        let arguments: JSONValue = .object(["control": .string("Mode"), "item": .string("Stereo")])
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let response = try #require(await router.handle(request("call", delegated("select", arguments))))
        #expect(response["result"]["isError"] == .bool(false))
        _ = try await tools.call("call", delegated("select", arguments))
        let invalid = try #require(await router.handle(request("call", delegated("select", .object(["control": .number(1)])))))
        #expect(invalid["result"]["isError"] == .bool(true))
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

    @Test func delegatedArgumentsAndRowReferencesAreCheckedBeforeEffects() async throws {
        let valid: JSONValue = .object(["control": .string("Mode"), "item": .string("Stereo")])
        let invalid: JSONValue = .object(["control": .number(1)])
        let unknownRow = valid.adding("step", .string("r1"))
        for (arguments, accepted) in [(valid, true), (invalid, false), (unknownRow, false)] {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            let response = try #require(await router.handle(request("call", delegated("select", arguments))))
            #expect(response["result"]["isError"].bool == !accepted)
            #expect(session.calls == (accepted ? ["select"] : []))
        }
    }

    private func delegated(_ name: String, _ arguments: JSONValue) -> JSONValue {
        .object(["name": .string(name), "arguments": arguments])
    }

    private func request(_ name: String, _ arguments: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments])])
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
