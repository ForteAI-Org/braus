import Capabilities
import LocalMCP
import Testing

@Suite
struct InterruptionInheritanceTests {
    @Test func delegatedCallsInheritAndUnknownCallsAreProtected() throws {
        let registry = try CapabilityRegistry(core: [
            demoContract("observe", origin: .core),
            demoContract("act", effect: .write, interruption: .mutating, origin: .core),
            demoContract("find", origin: .core)
        ], registered: [demoContract("demo.read")])
        for name in ["observe", "demo.read", "find"] {
            #expect(registry.interruptionClass(of: "call", arguments: .object(["name": .string(name)])) == .readOnly)
        }
        for name in ["act", "unknown", "call"] {
            #expect(registry.interruptionClass(of: "call", arguments: .object(["name": .string(name)])) == .mutating)
        }
        #expect(registry.interruptionClass(of: "call", arguments: .null) == .mutating)
        #expect(registry.interruptionClass(of: "find", arguments: .null) == .readOnly)
        #expect(registry.effectClass(of: "call", arguments: .object(["name": .string("observe")])) == .read)
    }
}

@Suite
struct ChannelKeyTests {
    @Test func keysMatchTheStoredCallArguments() throws {
        let registry = try CapabilityRegistry(core: [
            demoContract("act", origin: .core),
            demoContract("demo.create_event", origin: .adapter("demo"))
        ], registered: [demoContract("other.read", origin: .registered(provider: "other"))])
        #expect(registry.channelKey(of: CapabilityID(rawValue: "act")) == "act")
        #expect(registry.channelKey(of: CapabilityID(rawValue: "demo.create_event")) == "app_call:create_event")
        #expect(registry.channelKey(of: CapabilityID(rawValue: "other.read")) == "other.read")
        #expect(registry.channelKeys == ["act", "app_call:create_event", "other.read"])
    }
}

@Suite
struct RegistryValidationTests {
    @Test func duplicateAndReservedNamesAreRejected() throws {
        let core = [demoContract("act", origin: .core), demoContract("demo.read", origin: .adapter("demo"))]
        for name in ["act", "find", "call", "plan", "end", "ask_person", "demo.x"] {
            #expect(throws: CapabilityRegistry.RegistryError.reservedName(CapabilityID(rawValue: name))) {
                try CapabilityRegistry(core: core, registered: [demoContract(name)])
            }
        }
        #expect(throws: CapabilityRegistry.RegistryError.duplicate(CapabilityID(rawValue: "other.read"))) {
            try CapabilityRegistry(core: core, registered: [demoContract("other.read"), demoContract("other.read")])
        }
    }

    @Test func stableOrderingKeepsCoreFirst() throws {
        let registry = try CapabilityRegistry(core: [demoContract("z", origin: .core)], registered: [
            demoContract("demo.write"), demoContract("demo.read")
        ])
        #expect(registry.all.map(\.id.rawValue) == ["z", "demo.read", "demo.write"])
    }
}

@Suite
struct CapabilityResolutionTests {
    @Test func adapterEffectsAndDelegationUseTheNamedVerb() throws {
        let registry = try CapabilityRegistry(core: [
            demoContract("app_call", effect: .write, interruption: .mutating, origin: .core),
            demoContract("demo.remove", effect: .irreversible, interruption: .mutating, origin: .adapter("demo"))
        ], registered: [])
        let arguments: JSONValue = .object(["app": .string("demo"), "verb": .string("remove")])
        #expect(registry.effectClass(of: "app_call", arguments: arguments) == .irreversible)
        #expect(registry.effectClass(of: "call", arguments: .object([
            "name": .string("app_call"), "arguments": arguments
        ])) == .irreversible)
        #expect(registry.effectClass(of: "app_call", arguments: .object([
            "verb": .string("demo.remove")
        ])) == .irreversible)
        #expect(registry.effectClass(of: "app_call", arguments: .object([
            "verb": .string("unknown")
        ])) == .write)
        #expect(registry.effectClass(of: "call", arguments: .object(["name": .string("call")])) == .write)
    }

    @Test func onlyExplicitContractsAllowParallelCalls() throws {
        let registry = try CapabilityRegistry(core: [], registered: [
            demoContract("demo.read", parallelSafe: true), demoContract("demo.write", effect: .write)
        ])
        #expect(registry.isParallelSafe("demo.read", arguments: .null))
        #expect(registry.isParallelSafe("call", arguments: .object(["name": .string("demo.read")])))
        #expect(!registry.isParallelSafe("demo.write", arguments: .null))
        #expect(!registry.isParallelSafe("unknown", arguments: .null))
        #expect(!registry.isParallelSafe("call", arguments: .object(["name": .string("call")])))
    }

    @Test func duplicateCoreIdentifiersAreRejected() {
        #expect(throws: CapabilityRegistry.RegistryError.duplicate(CapabilityID(rawValue: "act"))) {
            try CapabilityRegistry(core: [demoContract("act", origin: .core), demoContract("act", origin: .core)],
                                   registered: [])
        }
    }
}
