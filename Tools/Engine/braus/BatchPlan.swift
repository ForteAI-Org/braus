import AutomationRuntime
import AutomationMCP
import EngineCore
import Foundation

/// BatchPlan validates the whole sequence before any UI work. Shell tokenization preserves labels;
/// this parser never evaluates a shell string. A batch stays in one explicitly named window.
struct BatchPlan {

    let invocation: Invocation
    let application: String
    let steps: [BatchStep]
    let expectations: [ScreenExpectation?]

    init(arguments: [String]) throws {
        guard let boundary = arguments.firstIndex(of: "--") else {
            throw UsageError.missing("-- before the first batch step")
        }
        let header = Array(arguments[..<boundary])
        try Self.validateOptions(header, valued: ["window", "knowledge", "evidence"],
                                 flags: ["seat", "allow-unvalidated-build", "allow-destructive"])
        let invocation = Invocation(arguments: header)
        guard invocation.command == "batch", invocation.positionals.count == 1 else {
            throw UsageError.missing("batch <app> [options] -- <steps>")
        }
        guard invocation.flags.contains("seat") else { throw UsageError.missing("--seat for batch") }
        guard invocation.options["window"] != nil else { throw UsageError.missing("--window <title> for batch") }
        self.invocation = invocation
        application = try invocation.positional(0, "<app>")
        let groups = arguments[(boundary + 1)...].split(separator: "--then", omittingEmptySubsequences: false)
        let decoded = try groups.map { group -> (BatchStep, ScreenExpectation?) in
            let words = Array(group)
            guard let command = words.first, command == "select" || command == "act" else {
                throw UsageError.missing("select <dropdown> <item> or act <target> after -- / --then")
            }
            try Self.validateOptions(words, valued: command == "act" ? ["verb", "value", "section", "expect"] : ["expect"], flags: [])
            let step = Invocation(arguments: words, additionalValueOptions: ["expect"])
            let expectation: ScreenExpectation?
            if let text = step.options["expect"] {
                let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
                expectation = try ToolArguments.expectation(from: value)
            } else { expectation = nil }
            switch command {
                case "select":
                    guard step.positionals.count == 2 else {
                        throw UsageError.missing("select <dropdown> <item> (app is specified once for the batch)")
                    }
                    return (.select(control: step.positionals[0], item: step.positionals[1]), expectation)
                default:
                    guard step.positionals.count == 1 else {
                        throw UsageError.missing("act <target> (app is specified once for the batch)")
                    }
                    let action = try ActArguments(step, targetIndex: 0)
                    guard step.options["value"] == nil || action.verb == .setToggle else {
                        throw UsageError.invalid(option: "value", value: step.options["value"] ?? "",
                                                 expected: "--verb set_toggle")
                    }
                    return (.act(action), expectation)
            }
        }
        steps = decoded.map { $0.0 }
        expectations = decoded.map { $0.1 }
    }

    /// Rejects misspellings, duplicate options, missing values and options in the wrong scope.
    private static func validateOptions(_ words: [String], valued: Set<String>, flags: Set<String>) throws {
        var seen: Set<String> = []
        var index = 0
        while index < words.count {
            let word = words[index]
            guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageError.missing("a nonempty app, window or target")
            }
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                guard valued.contains(name) || flags.contains(name), seen.insert(name).inserted else {
                    throw UsageError.invalid(option: name, value: "", expected: "a supported, non-repeated option in this scope")
                }
                if valued.contains(name) {
                    guard index + 1 < words.count, !words[index + 1].hasPrefix("--"),
                          !words[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw UsageError.missing("value for --\(name)")
                    }
                    index += 1
                }
            }
            index += 1
        }
    }
}

/// BatchStep is one validated operation, without its own Seat or application lifetime.
enum BatchStep {
    case select(control: String, item: String)
    case act(ActArguments)

    var summary: String {
        switch self {
            case .select(let control, let item): "select '\(control)' → '\(item)'"
            case .act(let action): "\(action.verb.rawValue) '\(action.target)'"
        }
    }

    func facts(expectation: ScreenExpectation?) -> BatchPolicy.StepFacts {
        switch self {
        case .select(let control, let item): return .init(kind: .select, target: control, item: item, expectation: expectation)
        case .act(let action):
            return .init(kind: .act, target: action.target, section: action.section,
                         verb: action.verb.rawValue, expectation: expectation)
        }
    }

    func accepts(_ outcome: Outcome) -> Bool {
        outcome.effect == .confirmed
    }

    /// Supplies the request context available to historical no-op readers too.
    func outcome(of result: ActOutcome) -> Outcome {
        var noop: NoopKind?
        if case .act(let action) = self, action.verb == .setToggle { noop = .statePresent }
        return Outcome.converting(result.kind, check: nil, notSent: result.notSent,
                                  noop: noop, sceneAttached: result.scene != nil)
    }
}
