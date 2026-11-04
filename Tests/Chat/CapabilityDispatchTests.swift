@testable import AutomationMCP
import AutomationRuntime
import ChatCore
import Capabilities
import Foundation
import LocalMCP
import Memory
import SQLiteMemory
import Testing

@MainActor
struct CapabilityDispatchTests {
    @Test func fixedListAndDiscovery() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ToolList.core.map(\.rawValue))
        let answer = try await tools.call("find", .object(["query": .string("scorri la lista")]))
        let text = try #require(answer["content"].array?.first?["text"].string)
        #expect(text.contains("scroll"))
        #expect(text.contains("inputSchema"))
    }

    @Test func delegatedCallEmitsOneRealNameFact() async throws {
        let provider = DispatchRead()
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        let arguments: JSONValue = .object(["name": .string("demo.read"),
            "arguments": .object(["count": .number(1)])])
        let observed = try await tools.call("call", arguments)
        #expect(inputs.map(\.fact) == [.callFinished(tool: "demo.read", subject: nil, outcome: nil)])
        #expect(inputs.map(\.sequence) == [1])
        tools.observeTaskState(nil)
        #expect(try await tools.call("call", arguments) == observed)
    }

    @Test func findEmitsDeliveredSchemasInline() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        let answer = try await tools.call("find", .object(["query": .string("scroll down the list")]))
        let text = try #require(answer["content"].array?.first?["text"].string)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let names = try #require(payload["capabilities"].array).compactMap { $0["name"].string }
        #expect(!names.isEmpty)
        let loaded = inputs.compactMap { input -> String? in
            if case .loaded(.schema(capability: let name)) = input.fact { return name }
            return nil
        }
        #expect(loaded == names)
        #expect(inputs.allSatisfy { $0.sequence == 1 })
        #expect(Set(inputs.map(\.key)).count == inputs.count)
    }

    @Test func cancelledFindDoesNotEmitTranscript() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        var lines: [String] = []
        tools.record = { lines.append($0) }
        let task = Task { try await tools.call("find", .object(["query": .string("scroll")])) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(lines.isEmpty)
    }

    @Test func findReturnsCompleteContractSchemas() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        let answer = try await tools.call("find", .object(["query": .string("list application press scroll drag")]))
        let text = try #require(answer["content"].array?.first?["text"].string)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let entries = try #require(payload["capabilities"].array)
        #expect((3...5).contains(entries.count))
        let contracts = ToolCatalogue.contracts(for: [])
        for entry in entries {
            let contract = try #require(contracts.first { $0.id.rawValue == entry["name"].string })
            #expect(entry["inputSchema"] == contract.inputSchema)
        }
    }

    @Test func delegatedScrollUsesItsRealNameAndOneArchiveCall() async throws {
        let directory = URL.temporaryDirectory.appending(path: "capability-scroll-" + UUID().uuidString)
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session)
        var lines: [String] = []
        tools.record = { lines.append($0) }
        _ = try await tools.call("call", .object(["name": .string("scroll"),
            "arguments": .object(["direction": .string("down"), "lines": .number(3)])]))
        #expect(session.inputs.count == 1)
        #expect(lines.contains { $0.hasPrefix("→ scroll") })
        #expect(!lines.contains { $0.hasPrefix("→ call") })
        let memory = MemoryService.shared(for: directory)
        let records = try await memory.perform { repositories in
            try await repositories.store.read { try $0.query("SELECT tool_kind FROM memory_agent_actions") { try $0.text(0) } }
        }
        #expect(records == ["scroll"])
        await memory.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func tripleClickCannotBypassCapabilityRecordingThroughAct() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("act", .object(["target": .string("Synthetic"), "verb": .string("triple_click")]))
        }
        #expect(session.calls.isEmpty)
    }

    @Test func unadvertisedRegisteredCallsCannotBypassDelegatedValidation() async throws {
        let provider = DispatchRead()
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("demo.read", .object(["count": .number(1)]))
        }
        #expect(await provider.calls == 0)
        do {
            _ = try await tools.call("call", .object(["name": .string("demo.read"),
                "arguments": .object(["count": .string("wrong")])]))
            Issue.record("Invalid delegated arguments reached the provider")
        } catch {
            #expect(String(describing: error).contains("$.count"))
        }
        #expect(await provider.calls == 0)
    }

    @Test func delegatedCallUsesRealName() async throws {
        let provider = DispatchRead()
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        var lines: [String] = []
        tools.record = { lines.append($0) }
        _ = try await tools.call("call", .object(["name": .string("demo.read"),
            "arguments": .object(["count": .number(1)])]))
        #expect(await provider.calls == 1)
        #expect(lines.contains { $0.contains("→ demo.read") })
        #expect(!lines.contains { $0.contains("→ call") })
    }

    @Test func observeLevelAndConnectionStayFixed() async throws {
        let tools = AutomationTools(session: ToolResultSession(), profile: SessionProfile(attendance: .client, level: .observe, memory: .read, catalogue: .open, takeover: false, options: .init(), name: "client"))
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ["open_session", "observe", "find", "call"])
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        let before = await router.handle(request)
        let definitions = tools.toolDefinitions
        #expect(tools.toolDefinitions == definitions)
        let answer = try await tools.call("find", .object(["query": .string("scroll down the list")]))
        let payload = try JSONDecoder().decode(JSONValue.self,
            from: Data((answer["content"].array?.first?["text"].string ?? "").utf8))
        #expect(payload["capabilities"].array?.allSatisfy { $0["name"].string != "scroll" } == true)
        #expect(await router.handle(request) == before)
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("scroll", .object(["direction": .string("down")]))
        }
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("call", .object(["name": .string("scroll"), "arguments": .object(["direction": .string("down")])]))
        }
    }

    @Test func actLevelExcludesConnectorsInDiscoveryAndCalls() async throws {
        for level: ToolList.Level in [.act, .actConnectors] {
            let provider = DispatchRead(channel: .connector)
            let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider],
                profile: SessionProfile(attendance: .client, level: level, memory: .read, catalogue: .openAndPrivate, takeover: false, options: .init(), name: "client"))
            let found = try await tools.call("find", .object(["query": .string("count")]))
            #expect(found["content"].array?.first?["text"].string?.contains("demo.read") == (level == .actConnectors))
            let arguments: JSONValue = .object(["count": .number(1)])
            if level == .act {
                await #expect(throws: AutomationFailure.self) { try await tools.call("demo.read", arguments) }
                await #expect(throws: AutomationFailure.self) {
                    try await tools.call("call", .object(["name": .string("demo.read"), "arguments": arguments]))
                }
                #expect(await provider.calls == 0)
            } else {
                await #expect(throws: AutomationFailure.self) { try await tools.call("demo.read", arguments) }
                _ = try await tools.call("call", .object(["name": .string("demo.read"), "arguments": arguments]))
                #expect(await provider.calls == 1)
            }
        }
    }

    @Test func catalogueSchemasAndGroupsAreComplete() throws {
        let registry = try CapabilityRegistry(core: ToolCatalogue.contracts(for: [.adapters]), registered: [])
        let entries = ToolCatalogue.catalogue(channels: [.adapters], registry: registry)
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.contract.inputSchema["additionalProperties"] == .bool(false))
            #expect(entry.exampleQuestions.count == 2)
            #expect((3...4).contains(entry.contract.description.split(separator: ".").count))
        }
        #expect(ToolCatalogue.groupIndex(entries).split(separator: "\n").map(String.init)
            == Set(entries.map { $0.contract.group }).sorted())
    }

    @Test func readRejectsUndeclaredStepAndKeepsDeclaredBusinessStep() async throws {
        let provider = DispatchRead()
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider])
        await #expect(throws: AutomationFailure.self) {
            let invalid: JSONValue = .object(["count": .number(1), "step": .string("r1")])
            try await tools.call("call", .object(["name": .string("demo.read"), "arguments": invalid]))
        }
        #expect(await provider.calls == 0)
        let business = DispatchRead(countField: "step")
        let declared = AutomationTools(session: ToolResultSession(), capabilities: [business])
        _ = try await declared.call("call", .object(["name": .string("demo.read"),
            "arguments": .object(["step": .number(1)])]))
        #expect(await business.calls == 1)
        #expect(await business.received?["step"] == .number(1))
    }

    @Test func humanStepRefusesBeforeSession() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "human_step" })
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("human_step", .object(["steps": .string("1")]))
        }
    }
}

private actor DispatchRead: CapabilityProviding {
    nonisolated let family = "demo"
    var calls = 0
    var received: JSONValue?
    nonisolated let channel: Channel
    nonisolated let countField: String
    init(channel: Channel = .braus, countField: String = "count") {
        self.channel = channel
        self.countField = countField
    }
    nonisolated var contracts: [CapabilityContract] {
        [.init(id: .init(rawValue: "demo.read"), group: "inspection", description: "Read a count.",
            inputSchema: .object(["type": .string("object"), "properties": .object([
                countField: .object(["type": .string("integer")])]),
                "required": .array([.string(countField)]), "additionalProperties": .bool(false)]),
            effect: .read, interruption: .readOnly, verification: .none(reason: "read only"),
            channel: channel, origin: .registered(provider: "demo"), memory: .capabilityStep, takesSession: false)]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        calls += 1
        received = arguments
        return .object(["count": arguments[countField]])
    }
}

extension CapabilityDispatchTests {
    @Test func wrappersOutsideCatalogueAreRefused() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, channels: [.adapters])
        for name in ["app_call", "app_capabilities"] {
            do {
                _ = try tools.resolvedCall("call", arguments: .object(["name": .string(name),
                    "arguments": .object([:])]))
                Issue.record("An adapter wrapper was callable through discovery")
            } catch let failure as AutomationFailure {
                #expect(failure.cause == "unknown_tool")
            }
        }
        #expect(session.calls.isEmpty)
    }

    @Test func rareDirectNameIsRefusedInFixedList() async throws {
        let tools = AutomationTools(session: ToolResultSession())
        await #expect(throws: AutomationFailure.self) { try await tools.call("status", .object([:])) }
        _ = try await tools.call("call", .object(["name": .string("status"), "arguments": .object([:])]))
    }
}

extension CapabilityDispatchTests {
    @Test func modelCatalogueOwnsDiscoveryVocabulary() {
        let texts = Set(ModelText.catalogue.map(\.text))
        for value in ["inspection", "interaction", "session", "integration", "strict", "capabilities", "groups"] {
            #expect(texts.contains(value))
        }
    }
}


extension CapabilityDispatchTests {
    @Test func actSchemasAgreeAndTripleClickRemainsADiscoveredCapability() throws {
        let declared = try #require(ToolCatalogue.availableDefinitions(for: []).first { $0["name"].string == "act" })
        let served = try #require(AutomationTools.definitions.first { $0["name"].string == "act" })
        let contracts = ToolCatalogue.contracts(for: [])
        let registered = try #require(contracts.first { $0.id.rawValue == "act" })
        let verbs = declared["inputSchema"]["properties"]["verb"]["enum"]
        #expect(verbs == served["inputSchema"]["properties"]["verb"]["enum"])
        #expect(verbs == registered.inputSchema["properties"]["verb"]["enum"])
        #expect(!(verbs.array ?? []).contains(.string("triple_click")))
        let registry = try CapabilityRegistry(core: contracts, registered: [])
        let entries = ToolCatalogue.catalogue(channels: [], registry: registry)
        let triple = try #require(entries.first { $0.contract.id.rawValue == "triple_click" })
        #expect(triple.contract.inputSchema["required"].array?.contains(.string("target")) == true)
        #expect(!AutomationTools.definitions.contains { $0["name"].string == "triple_click" })
    }
}
