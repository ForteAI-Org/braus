import LocalMCP

/// CapabilityRegistry freezes contracts without retaining providers, sessions or storage.
/// Core order is preserved; registered contracts follow in family and identifier order.
public struct CapabilityRegistry: Sendable {
    public static let reservedCoreNames: Set<String> = ["find", "call", "plan", "end", "ask_person"]

    public let all: [CapabilityContract]
    private let contracts: [CapabilityID: CapabilityContract]

    /// Rejects duplicate identifiers and registered identifiers owned or reserved by the core or an adapter.
    public init(core: [CapabilityContract], registered: [CapabilityContract]) throws(RegistryError) {
        var contracts: [CapabilityID: CapabilityContract] = [:]
        var adapterNames: Set<String> = []
        for contract in core {
            guard contracts[contract.id] == nil else { throw .duplicate(contract.id) }
            contracts[contract.id] = contract
            if case .adapter(let name) = contract.origin { adapterNames.insert(name) }
        }
        let coreNames = Set(core.map(\.id.rawValue)).union(Self.reservedCoreNames)
        for contract in registered {
            let family = contract.id.rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            guard !coreNames.contains(contract.id.rawValue), !adapterNames.contains(family) else {
                throw .reservedName(contract.id)
            }
            guard contracts[contract.id] == nil else { throw .duplicate(contract.id) }
            contracts[contract.id] = contract
        }
        self.contracts = contracts
        self.all = core + registered.sorted {
            func family(_ contract: CapabilityContract) -> String {
                if case .registered(let provider) = contract.origin { return provider }
                return contract.id.rawValue
            }
            return (family($0), $0.id.rawValue) < (family($1), $1.id.rawValue)
        }
    }

    public func contract(for id: CapabilityID) -> CapabilityContract? { contracts[id] }

    /// Inherits a delegated call's interruption class; unknown or malformed names stay protected.
    public func interruptionClass(of tool: String, arguments: JSONValue) -> InterruptionClass {
        resolvedContract(tool, arguments: arguments)?.interruption ?? .mutating
    }

    /// Inherits the named adapter verb's or delegated capability's effect; unknown names may write.
    public func effectClass(of tool: String, arguments: JSONValue) -> EffectClass {
        if tool == "call" {
            guard let name = arguments["name"].string, name != "call" else { return .write }
            return effectClass(of: name, arguments: arguments["arguments"])
        }
        if tool == "app_call" {
            guard let verb = arguments["verb"].string else { return .write }
            let id = verb.contains(".") ? verb : (arguments["app"].string.map { "\($0).\(verb)" } ?? verb)
            guard let contract = contracts[CapabilityID(rawValue: id)], case .adapter = contract.origin else {
                return .write
            }
            return contract.effect
        }
        return resolvedContract(tool, arguments: arguments)?.effect ?? .write
    }

    /// Allows parallel execution only when the resolved contract explicitly promises it.
    public func isParallelSafe(_ tool: String, arguments: JSONValue) -> Bool {
        resolvedContract(tool, arguments: arguments)?.parallelSafe ?? false
    }

    /// Returns the key used to compare a served channel with saved call arguments.
    public func channelKey(of id: CapabilityID) -> String {
        guard let contract = contracts[id], case .adapter(let name) = contract.origin else { return id.rawValue }
        return "app_call:" + id.rawValue.dropFirst(name.count + 1)
    }

    public var channelKeys: Set<String> { Set(all.map { channelKey(of: $0.id) }) }

    private func resolvedContract(_ tool: String, arguments: JSONValue) -> CapabilityContract? {
        let name: String
        if tool == "call" {
            guard let target = arguments["name"].string, target != "call" else { return nil }
            name = target
        } else {
            name = tool
        }
        return contracts[CapabilityID(rawValue: name)]
    }

    /// RegistryError identifies a conflicting identifier without changing the supplied composition.
    public enum RegistryError: Error, Equatable {
        case duplicate(CapabilityID)
        case reservedName(CapabilityID)
    }
}
