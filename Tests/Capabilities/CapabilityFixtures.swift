import AutomationMCP
import AppAdapters
import Capabilities
import Foundation
import LocalMCP
import Testing

func demoContract(
    _ name: String,
    effect: EffectClass = .read,
    interruption: InterruptionClass = .readOnly,
    parallelSafe: Bool = false,
    origin: Origin = .registered(provider: "demo")
) -> CapabilityContract {
    CapabilityContract(
        id: CapabilityID(rawValue: name),
        group: "demo",
        description: "Demo capability",
        inputSchema: .object(["type": .string("object")]),
        effect: effect,
        interruption: interruption,
        verification: .none(reason: "Result only"),
        channel: .braus,
        origin: origin,
        memory: .capabilityStep,
        takesSession: false,
        parallelSafe: parallelSafe
    )
}

struct DemoAdapter: AppAdapting {
    let name = "demo"
    let appNames: [String] = []
    let bundleIDs: Set<String> = []
    let safeties: [AdapterVerb.Safety]

    var verbs: [AdapterVerb] {
        safeties.map { AdapterVerb("inspect", "Inspect", safety: $0, readBack: "Result") }
    }

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        throw AdapterFailure("Not used by contract tests")
    }
}

func decodedCapabilityResult(_ result: JSONValue) throws -> JSONValue {
    let text = try #require(result["content"].array?.first?["text"].string)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// Routes a registered capability through the compact facade; only writes carry a plan row.
func capabilityArguments(_ name: String) -> JSONValue {
    .object(["name": .string(name), "arguments": .object(name == "demo.write" ? ["step": .string("r1")] : [:])])
}

@MainActor
func beginCapabilityPlan(_ tools: AutomationTools) async throws {
    let result = try await tools.call("plan", .object([
        "request": .string("Exercise the synthetic registered capability"),
        "rows": .array([.object(["title": .string("Run the capability")])])
    ]))
    #expect(result["isError"] != .bool(true), "\(result)")
    #expect(tools.openTask != nil)
}
