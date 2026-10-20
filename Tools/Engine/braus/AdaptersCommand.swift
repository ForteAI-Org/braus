import AppAdapters
import EngineCore
import Foundation
import LocalMCP

/// AdaptersCommand lists the app adapters and runs one verb, the way `app_capabilities` and `app_call`
/// do for an agent, without a session or the memory.
///
///   braus adapters                            every adapter, its availability and its verbs
///   braus adapters <app> [<query>]            one adapter's verbs with their arguments, as JSON
///   braus adapters call <adapter.verb> [<json>]
///   braus adapters grant [<app>]              asks the permissions the adapters need, with the
///                                             system's prompts; they go to the app this runs in
enum AdaptersCommand {

    static func run(_ invocation: Invocation) async throws {
        let adapters = AppAdapters.standard()
        switch invocation.positionals.first {
            case nil:
                for (adapter, availability) in await adapters.listing() {
                    print("\(adapter.name) (\(adapter.appNames.joined(separator: ", "))): \(describe(availability))")
                    for verb in adapter.verbs { print("  \(adapter.name).\(verb.name) [\(verb.safety.rawValue)] \(verb.summary)") }
                }
            case "grant":
                let app = invocation.positionals.count > 1 ? invocation.positionals[1] : nil
                for (adapter, availability) in await adapters.requestPermissions(for: app) {
                    print("\(adapter.name): \(describe(availability))")
                }
            case "call":
                let qualified = try invocation.positional(1, "<adapter.verb>")
                guard let dot = qualified.firstIndex(of: ".") else {
                    throw UsageError.invalid(option: "call", value: qualified, expected: "<adapter>.<verb>")
                }
                let text = invocation.positionals.count > 2 ? invocation.positionals[2] : "{}"
                guard let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
                    throw UsageError.invalid(option: "call", value: text, expected: "a JSON object of arguments")
                }
                let outcome = try await adapters.call(app: String(qualified[..<dot]),
                                                      verb: String(qualified[qualified.index(after: dot)...]),
                                                      arguments: arguments)
                print(try render(outcome.json))
                if outcome.kind == .refused || outcome.kind == .honestMiss || outcome.kind == .actedUnverified { exit(1) }
            case let app?:
                let query = invocation.positionals.count > 1 ? invocation.positionals[1] : nil
                print(try render(await adapters.capabilities(of: app, query: query).json))
        }
    }

    private static func describe(_ availability: AdapterAvailability) -> String {
        switch availability {
            case .ready                      : "ready"
            case .needsPermission(let reason): "needs permission: \(reason)"
            case .unavailable(let reason)    : "unavailable: \(reason)"
            case .unknown(let reason)        : "unknown: \(reason)"
        }
    }

    private static func render(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
