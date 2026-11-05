import AppAdapters
import AutomationRuntime
@testable import AutomationMCP
import Capabilities
import LocalMCP
import Testing

@Suite
@MainActor
struct CapabilityContractTests {
    @Test func policyNamesEqualAllServedDefinitions() {
        let names = Set(AutomationTools.definitions(for: [.native, .web, .adapters]).compactMap { $0["name"].string })
        #expect(names.isSubset(of: Set(ToolCatalogue.policyRegistry.all.map(\.id.rawValue))))
        #expect(!ToolCatalogue.policyRegistry.all.contains { $0.id.rawValue == "human_step" })
    }

    @Test func everyServedToolHasAnExplicitContract() throws {
        let definitions = ToolCatalogue.availableDefinitions(for: [.native, .web, .adapters])
        let contracts = ToolCatalogue.contracts(for: [.native, .web, .adapters])
        let core = contracts.filter { $0.origin == .core }
        #expect(core.count == 27)
        #expect(AutomationTools.definitions(for: [.native, .web, .adapters]).count == 11)
        #expect(core.map(\.id.rawValue) == definitions.compactMap { $0["name"].string } + ["find", "call", "triple_click", "reconcile_call"])
        for definition in definitions {
            let contract = try #require(core.first { $0.id.rawValue == definition["name"].string })
            let expected = ToolCatalogue.catalogueNames.contains(contract.id.rawValue)
                ? ModelText.text(.init(rawValue: "catalogue." + contract.id.rawValue)) : definition["description"].string
            #expect(contract.description == expected)
            #expect(contract.inputSchema == definition["inputSchema"])
            #expect(contract.interruption == AutomationTools.interruptionPolicy(for: contract.id.rawValue))
        }
    }

}

@Suite
@MainActor
struct CoreEffectClassTests {
    @Test func coreEffectClassesAndSessions() throws {
        let contracts = ToolCatalogue.contracts(for: [.native, .web, .adapters])
        let registry = try CapabilityRegistry(core: contracts, registered: [])
        let reads: Set<String> = ["status", "windows", "apps", "observe", "app_capabilities", "find", "plan", "end", "canvas"]
        let noSession: Set<String> = ["status", "windows", "apps", "open_session", "app_capabilities",
                                      "app_call", "plan", "end", "find", "call", "reconcile_call", "canvas"]
        for contract in contracts where contract.origin == .core {
            let name = contract.id.rawValue
            let channel: Channel = ["status", "windows", "apps", "plan", "end", "find", "close_session", "reconcile_call"].contains(name)
                ? .braus : (["app_call", "app_capabilities"].contains(name) ? .adapter
                    : (name == "collect_posts" ? .web : .seat))
            #expect(contract.channel == channel)
            if ["plan", "end", "find", "call", "reconcile_call", "canvas"].contains(name) {
                guard case .notRecorded = contract.memory else {
                    Issue.record("The interaction cycle owns its own record")
                    continue
                }
            } else if name == "triple_click" {
                #expect(contract.memory == .capabilityStep)
            } else {
                #expect(contract.memory == .agentCall(tool: name))
            }
            #expect(contract.effect == (reads.contains(contract.id.rawValue) ? .read : .write))
            #expect(contract.takesSession == !noSession.contains(contract.id.rawValue))
        }
        for name in ["plan", "end"] {
            let contract = try #require(contracts.first { $0.id.rawValue == name })
            #expect(contract.interruption == .mutating)
            let definition = try #require(ToolCatalogue.availableDefinitions(for: []).first { $0["name"].string == name })
            #expect(definition["annotations"]["readOnlyHint"] == .bool(false))
        }
        let recovery = try #require(contracts.first { $0.id.rawValue == "reconcile_call" })
        #expect(recovery.effect == .write && recovery.interruption == .mutating && recovery.channel == .braus)
        #expect(!recovery.takesSession && recovery.inputSchema["properties"]["step"] == .null)
        #expect(registry.effectClass(of: "unknown", arguments: .null) == .write)
        #expect(registry.effectClass(of: "app_call", arguments: .null) == .write)
    }

}

@Suite
@MainActor
struct AdapterContractTests {
    @Test func duplicateAdapterVerbsKeepTheFirstContract() {
        let adapters = AppAdapters([DemoAdapter(safeties: [.read, .write]), DemoAdapter(safeties: [.irreversible])])
        let tools = AutomationTools(session: DemoSession(), adapters: adapters)
        let contracts = ToolCatalogue.contracts(for: [.adapters], adapters: adapters)
            .filter { $0.id.rawValue == "demo.inspect" }
        #expect(contracts.count == 1)
        #expect(contracts.first?.effect == .read)
        #expect(tools.effectClass(of: "app_call", arguments: .object([
            "app": .string("demo"), "verb": .string("inspect")
        ])) == .read)
    }

    @Test func adapterCompositionsServeTheirOwnEffects() throws {
        let businessArguments: JSONValue = .object(["app": .string("demo"), "verb": .string("inspect")])
        let callArguments: JSONValue = .object(["name": .string("demo.inspect"), "arguments": .object([:])])
        for safety in [AdapterVerb.Safety.read, .write, .irreversible] {
            let tools = AutomationTools(session: DemoSession(), adapters: AppAdapters([DemoAdapter(safeties: [safety])]))
            let expected = try #require(EffectClass(rawValue: safety.rawValue))
            #expect(tools.effectClass(of: "app_call", arguments: businessArguments) == expected)
            #expect(tools.effectClass(of: "call", arguments: callArguments) == expected)
            let entry = try #require(tools.dispatcher.entries.first { $0.contract.id.rawValue == "demo.inspect" })
            #expect(entry.contract.effect == expected)
            #expect(!tools.toolDefinitions.contains { $0["name"].string == "app_call" })
        }
        let withoutAdapters = AutomationTools(session: DemoSession())
        #expect(withoutAdapters.effectClass(of: "app_call", arguments: businessArguments) == .write)
        #expect(!withoutAdapters.dispatcher.entries.contains { $0.contract.id.rawValue == "demo.inspect" })
    }

    @Test func adapterContractsPreserveTheirDeclarations() throws {
        let adapters = AppAdapters.standard()
        let contracts = ToolCatalogue.contracts(for: [.adapters], adapters: adapters)
        for adapter in adapters.adapters {
            for verb in adapter.verbs {
                let contract = try #require(contracts.first { $0.id.rawValue == "\(adapter.name).\(verb.name)" })
                #expect(contract.effect.rawValue == verb.safety.rawValue)
                #expect(contract.verification == (verb.confirmation == .readBack
                    ? .readBack(description: verb.readBack) : .none(reason: "no read-back")))
                #expect(contract.channel == .adapter)
                #expect(contract.origin == .adapter(adapter.name))
                var actualSchema = try #require(contract.inputSchema.object)
                var actualProperties = try #require(actualSchema["properties"]?.object)
                let step = actualProperties.removeValue(forKey: "step")
                actualSchema["properties"] = .object(actualProperties)
                #expect(JSONValue.object(actualSchema) == verb.schema)
                #expect(step == (verb.safety == .read ? nil : .object([
                    "type": .string("string"), "pattern": .string("^r[1-9][0-9]*$")
                ])))
                #expect(contract.memory == .agentCall(tool: "app_call"))
                #expect(contract.interruption == .mutating)
                #expect(!contract.parallelSafe)
                #expect(!contract.takesSession)
            }
        }
        let registry = try CapabilityRegistry(core: contracts, registered: [])
        for contract in contracts where contract.effect == .irreversible {
            guard case .adapter(let app) = contract.origin else { continue }
            let verb = String(contract.id.rawValue.dropFirst(app.count + 1))
            for name in [verb, contract.id.rawValue] {
                #expect(registry.effectClass(of: "app_call", arguments: .object([
                    "app": .string(app), "verb": .string(name)
                ])) == .irreversible)
            }
        }
    }
}

@Suite
@MainActor
struct ParallelSafetyContractTests {
    @Test func coreAndAdapterCallsStaySerial() throws {
        let registry = try CapabilityRegistry(
            core: ToolCatalogue.contracts(for: [.native, .web, .adapters]),
            registered: [demoContract("demo.read", parallelSafe: true)]
        )
        #expect(registry.all.filter { $0.origin != .registered(provider: "demo") }.allSatisfy { !$0.parallelSafe })
        #expect(!registry.isParallelSafe("unknown", arguments: .null))
        #expect(!registry.isParallelSafe("call", arguments: .null))
        #expect(registry.isParallelSafe("call", arguments: .object(["name": .string("demo.read")])))
        #expect(!registry.isParallelSafe("call", arguments: .object(["name": .string("observe")])))
    }
}

