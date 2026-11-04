import AppAdapters
import AutomationRuntime
import Capabilities
import ChatCore
import Foundation
import LocalMCP

extension ToolCatalogue {
    static let catalogueNames: Set<String> = ["select", "scroll", "drag", "context_menu", "insert_text", "press",
        "triple_click", "status", "windows", "apps", "collect_posts", "close_session"]

    static var findDefinition: JSONValue {
        discoveryDefinition("find", properties: [
            "query": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer"), "minimum": .number(3), "maximum": .number(5)])
        ], required: ["query"], readOnly: true)
    }

    static var callDefinition: JSONValue {
        discoveryDefinition("call", properties: [
            "name": .object(["type": .string("string")]),
            "arguments": .object(["type": .string("object")])
        ], required: ["name", "arguments"], readOnly: false)
    }

    static var tripleClickDefinition: JSONValue {
        discoveryDefinition("triple_click", properties: [
            "target": .object(["type": .string("string"), "minLength": .number(1)]),
            "section": .object(["type": .string("string"), "minLength": .number(1)])
        ], required: ["target"], readOnly: false)
    }

    static var reconcileCallDefinition: JSONValue {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        return discoveryDefinition("reconcile_call", properties: [
            "call": text,
            "finding": .object(["type": .string("string"), "enum": .array([.string("happened"), .string("not_happened")])]),
            "evidence": text, "note": text
        ], required: ["call", "finding", "evidence"], readOnly: false)
    }

    private static func discoveryDefinition(_ name: String, properties: [String: JSONValue],
                                            required: [String], readOnly: Bool) -> JSONValue {
        .object(["name": .string(name), "description": .string(ModelText.text(.init(rawValue: "catalogue." + name))),
            "inputSchema": schema(properties, required),
            "annotations": .object(["readOnlyHint": .bool(readOnly)])])
    }

    static func definitions(for list: ToolList, channels: AutomationChannels) -> [JSONValue] {
        let available = availableDefinitions(for: channels, surface: .tagged) + [findDefinition, callDefinition]
        return ToolList.names(attendance: list.attendance, level: list.level).compactMap { id in
            guard var definition = available.first(where: { $0["name"].string == id.rawValue })?.object else { return nil }
            definition["inputSchema"] = composedSchema(definition["inputSchema"] ?? .null,
                name: id.rawValue, effect: policyRegistry.effectClass(of: id.rawValue, arguments: .null), surface: .tagged)
            return .object(definition)
        }
    }

    /// Composes protocol fields once; providers receive their business arguments after routing consumes the step.
    static func composedContract(_ contract: CapabilityContract) -> CapabilityContract {
        let schema = composedSchema(contract.inputSchema, name: contract.id.rawValue,
            effect: contract.effect, surface: currentSurface)
        guard schema != contract.inputSchema else { return contract }
        return CapabilityContract(id: contract.id, group: contract.group, description: contract.description,
            inputSchema: schema, effect: contract.effect, interruption: contract.interruption,
            verification: contract.verification, channel: contract.channel, origin: contract.origin,
            memory: contract.memory, takesSession: contract.takesSession, parallelSafe: contract.parallelSafe)
    }

    private static func composedSchema(_ value: JSONValue, name: String, effect: EffectClass,
                                       surface: ToolSurface) -> JSONValue {
        guard var schema = value.object,
              var fields = schema["properties"]?.object else { return value }
        if effect != .read, !["open_session", "close_session", "call", "reconcile_call"].contains(name), fields["step"] == nil {
            fields["step"] = .object(["type": .string("string"), "pattern": .string("^r[1-9][0-9]*$")])
        }
        schema["properties"] = .object(fields)
        return .object(schema)
    }

    static func catalogue(channels: AutomationChannels, registry: CapabilityRegistry) -> [CatalogueEntry] {
        let excluded = Set(ToolList.core.map(\.rawValue) + ["human_step", "memory_task", "ask_person", "app_call", "app_capabilities"])
        return registry.all.filter { !excluded.contains($0.id.rawValue) }.map { contract in
            let core = contract.origin == .core && contract.id.rawValue != "read_guide"
            let key = core ? "catalogue." + contract.id.rawValue : "catalogue.generic"
            return CatalogueEntry(contract: contract, exampleQuestions: [
                ModelText.text(.init(rawValue: key + ".en")), ModelText.text(.init(rawValue: key + ".it"))])
        }.sorted { $0.contract.id.rawValue < $1.contract.id.rawValue }
    }

    static func groupIndex(_ entries: [CatalogueEntry]) -> String {
        Set(entries.map { $0.contract.group }).sorted().joined(separator: "\n")
    }
}
