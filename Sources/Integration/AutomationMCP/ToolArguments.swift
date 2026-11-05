import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// ToolArguments decodes a complete call before any effects begin.
public enum ToolArguments {
    public enum ExpectationError: Error, Sendable, Equatable { case invalidShape }
    private static var invalidExpectation: AutomationFailure {
        AutomationFailure(ModelText.text(.init(rawValue: "expect.invalidShape")), cause: "invalid_arguments", beforeDispatch: true)
    }

    /// Decodes a screen predicate for batch steps and host execution.
    /// Batch steps and command-line callers use this same decoder with JSON-compatible input.
    public static func expectation(from value: Any?) throws -> ScreenExpectation? {
        guard let value else { return nil }
        let json: JSONValue
        if let supplied = value as? JSONValue { json = supplied }
        else {
            guard JSONSerialization.isValidJSONObject(value) else { throw invalidExpectation }
            do { json = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)) }
            catch { throw invalidExpectation }
        }
        if json == .null { throw invalidExpectation }
        guard let fields = json.object else { throw invalidExpectation }
        if let title = json["window"].string, !title.isEmpty {
            guard Set(fields.keys).isSubset(of: ["window", "open"]),
                  fields["open"] == nil || json["open"].bool != nil else { throw invalidExpectation }
            return .window(title: title, open: json["open"].bool ?? true)
        }
        if let label = json["element"].string, !label.isEmpty {
            guard Set(fields.keys).isSubset(of: ["element", "value", "state", "present"]),
                  ["value", "state", "present"].filter({ fields[$0] != nil }).count <= 1 else {
                throw invalidExpectation
            }
            let expected: ElementExpectation
            if fields["value"] != nil {
                guard let value = json["value"].string else { throw invalidExpectation }
                expected = .value(value)
            } else if fields["state"] != nil {
                guard let word = json["state"].string, let state = ControlState(rawValue: word), state != .unknown else {
                    throw invalidExpectation
                }
                expected = .state(state)
            } else {
                guard fields["present"] == nil || json["present"].bool != nil else { throw invalidExpectation }
                expected = json["present"].bool == false ? .absent : .present
            }
            return .element(label: label, expect: expected)
        }
        throw invalidExpectation
    }

    /// Individual gestures do not accept expectations; plans and batches own them.
    static func rejectGestureExpectation(in arguments: JSONValue) throws {
        if arguments.object?["expect"] != nil { throw invalidExpectation }
    }

    static func step(in arguments: JSONValue) throws -> TodoRowID? {
        guard let value = try optionalString(arguments, "step") else { return nil }
        let suffix = value.dropFirst()
        guard value.first == "r", suffix.first != "0", !suffix.isEmpty,
              suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw invalid(ModelText.text(.init(rawValue: "task_cycle.step_id.v2")))
        }
        return TodoRowID(rawValue: value)
    }

    private static func invalid(_ message: String) -> AutomationFailure {
        AutomationFailure(message, cause: "invalid_arguments", beforeDispatch: true)
    }

    /// The request of a call as the contract keeps it, from the arguments `answer` will decode the
    /// same way; it throws for arguments the call itself would refuse.
    static func callRequest(_ name: String, _ arguments: JSONValue) throws -> AgentCallRequest {
        switch name {
            case "status"       : return .status
            case "windows"      : return .windows(app: try optionalString(arguments, "app"))
            case "apps"         : return .apps(query: try optionalString(arguments, "query"))
            case "open_session" : return .openSession(app: try requiredString(arguments, "app"), window: try windowTitle(arguments))
            case "observe"      : return .observe(full: arguments["full"].bool == true)
            case "menu"         : return .menu(path: try requiredString(arguments, "path"))
            case "press"        : return .press(button: try requiredString(arguments, "button"))
            case "batch"        : return .batch
            case "close_session": return .closeSession
            case "collect_posts":
                let target = try whole(arguments, "target", PostCollectionRequest.targets, default: 1)
                let scrolls = try whole(arguments, "max_scrolls", PostCollectionRequest.scrolls, default: 30)
                let seconds = try whole(arguments, "seconds", PostCollectionRequest.wholeSeconds, default: 60)
                return .collectPosts(target: target, maxScrolls: scrolls, seconds: seconds)
            case "app_capabilities":
                return .appCapabilities(app: try requiredString(arguments, "app"), query: try optionalString(arguments, "query"))
            case "app_call":
                return .appCall(app: try requiredString(arguments, "app"), verb: try requiredString(arguments, "verb"),
                                arguments: try ResultFormatter.canonical(arguments["arguments"]))
            default             : return try Step(name, arguments).callRequest
        }
    }

    static func requiredString(_ object: JSONValue, _ key: String) throws -> String {
        guard let value = object[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArguments.invalid("\(key) must be a nonempty string.")
        }
        return value
    }

    static func optionalString(_ object: JSONValue, _ key: String) throws -> String? {
        object.object?[key] == nil ? nil : try requiredString(object, key)
    }

    /// The element a target names when the model copied the scene's id mark: the id between the quotes of a
    /// trailing `id:'…'`, with or without what the scene printed before it (`[field] Name id:'control|name'`,
    /// an unlabeled icon's `id:'?|@4,0'`). The scene resolves a target by its exact id or by its label, never by
    /// the two written together, so the copied line named nothing. Any other target is returned as written.
    nonisolated static func elementReference(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("'"), let mark = trimmed.range(of: "id:'", options: .backwards) else { return target }
        let before = trimmed[..<mark.lowerBound]
        guard before.isEmpty || before.last?.isWhitespace == true else { return target }
        let id = trimmed[mark.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard !id.isEmpty, !id.contains("'") else { return target }
        return String(id)
    }

    private static func reference(_ object: JSONValue, _ key: String) throws -> String {
        elementReference(try requiredString(object, key))
    }

    private static func optionalReference(_ object: JSONValue, _ key: String) throws -> String? {
        try optionalString(object, key).map(elementReference)
    }

    /// A supplied title is exact, including an empty native title; omission requests the main window.
    static func windowTitle(_ object: JSONValue) throws -> String? {
        guard let supplied = object.object?["window"] else { return nil }
        guard let title = supplied.string else { throw ToolArguments.invalid("window must be a string.") }
        return title
    }

    // ponytail: apps lists 60 candidates at most, so a listing without a query stays short;
    // the rest are only counted, and a query reaches them.
    static let applicationLimit = 60

    static func candidate(_ app: ApplicationCandidate) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(app.name), "bundleID": .string(app.bundleID),
                                           "running": .bool(app.isRunning)]
        if let version = app.version { fields["version"] = .string(version) }
        if let location = app.location { fields["location"] = .string(location) }
        if app.isDefaultBrowser { fields["defaultBrowser"] = .bool(true) }
        return .object(fields)
    }

    /// The tools that deliver an input through the engine, in the order they are listed.
    static let inputTools = ["type_text", "insert_text", "press_key", "scroll", "drag", "context_menu"]

    /// The largest drag offset, in points, on either axis: more than any display is wide.
    static let maximumOffset = 5000.0

    /// A whole number within `range`, or `fallback` when the argument is absent.
    static func whole(_ object: JSONValue, _ key: String, _ range: ClosedRange<Int>,
                              default fallback: Int) throws -> Int {
        guard object.object?[key] != nil else { return fallback }
        guard case .number(let value) = object[key], value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw ToolArguments.invalid("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(value)
    }

    /// A drag offset in points, zero when the argument is absent.
    private static func offset(_ object: JSONValue, _ key: String) throws -> Double {
        guard object.object?[key] != nil else { return 0 }
        guard case .number(let value) = object[key], abs(value) <= maximumOffset else {
            throw ToolArguments.invalid("\(key) must be a number of points within ±\(Int(maximumOffset)).")
        }
        return value
    }

    enum Step {
        case act(String, ActionVerb, String?, ControlState?)
        case select(String, String)
        case input(InputRequest.Input, section: String?)
        case menu(path: String)

        var isToggle: Bool {
            if case .act(_, .setToggle, _, _) = self { true } else { false }
        }

        /// The texts the step types: a typed text, an inserted one and its expected value.
        var texts: [String] {
            guard case .input(let input, _) = self else { return [] }
            return switch input {
                case .typeText(let text, _, _)          : [text]
                case .insertText(let text, let expected): [text] + (expected.map { [$0] } ?? [])
                default                                 : []
            }
        }

        /// The section and the target the step names, which a budgeted scene after it keeps first.
        var aim: (section: String?, target: String?) {
            switch self {
                case .act(let target, _, let section, _): (section, target)
                case .select(let control, _)            : (nil, control)
                case .menu                              : (nil, nil)
                case .input(let input, let section):
                    switch input {
                        case .typeText(_, let target, _)  : (section, target)
                        case .scroll(_, let target)       : (section, target)
                        case .drag(let target, _)         : (section, target)
                        case .contextMenu(let target, _)  : (section, target)
                        case .insertText, .pressKey       : (section, nil)
                    }
            }
        }

        /// The step as the call contract keeps it.
        var callRequest: AgentCallRequest {
            switch self {
                case .act(let target, let verb, let section, let state):
                    .act(target: target, verb: verb, value: state, section: section)
                case .select(let control, let item):
                    .select(control: control, item: item)
                case .menu(let path): .menu(path: path)
                case .input(let input, let section):
                    .input(input, section: section)
            }
        }

        init(_ name: String, _ args: JSONValue, inBatch: Bool = false) throws {
            let available = ToolCatalogue.availableDefinitions(for: [], surface: ToolCatalogue.currentSurface)
            guard (["act", "select"] + inputTools + (inBatch ? ["menu"] : [])).contains(name),
                  let definition = available.first(where: { $0["name"].string == name }) else {
                throw ToolArguments.invalid("batch supports act, select, type_text, insert_text, press_key, scroll, drag and "
                                        + "context_menu only.")
            }
            let permitted = Set(definition["inputSchema"]["properties"].object?.keys.map { $0 } ?? [])
                .union(["operation"])
                .union(inBatch ? ["expect"] : [])
                .subtracting(inBatch ? ["then"] : [])
            guard let object = args.object, Set(object.keys).isSubset(of: permitted) else {
                throw ToolArguments.invalid("Unknown step argument.")
            }
            if inBatch { _ = try expectation(from: args.object?["expect"]) }
            else { try rejectGestureExpectation(in: args) }
            let section = try optionalString(args, "section")
            switch name {
            case "menu": self = .menu(path: try requiredString(args, "path"))
            case "type_text":
                guard let text = args["text"].string, !text.isEmpty else {
                    throw ToolArguments.invalid("text must be a nonempty string.")
                }
                if object["replace"] != nil, args["replace"].bool == nil {
                    throw ToolArguments.invalid("replace must be true or false.")
                }
                self = .input(.typeText(text, into: try reference(args, "target"),
                                        replacing: args["replace"].bool ?? true), section: section)
            case "insert_text":
                guard let text = args["text"].string, !text.isEmpty else {
                    throw ToolArguments.invalid("text must be a nonempty string.")
                }
                self = .input(.insertText(text, expecting: try optionalString(args, "expected_value")), section: nil)
            case "press_key":
                guard let key = KeyChord.Name(try requiredString(args, "key")) else {
                    throw ToolArguments.invalid("key must be return, tab, escape, space, delete, an arrow, a letter, a digit, / or ~.")
                }
                var modifiers: KeyModifiers = []
                if object["modifiers"] != nil {
                    guard let tokens = args["modifiers"].array else {
                        throw ToolArguments.invalid("modifiers must be a list of cmd, shift, opt and ctrl.")
                    }
                    for token in tokens {
                        switch token.string {
                        case "cmd"  : modifiers.insert(.command)
                        case "shift": modifiers.insert(.shift)
                        case "opt"  : modifiers.insert(.option)
                        case "ctrl" : modifiers.insert(.control)
                        default     : throw ToolArguments.invalid("modifiers must be a list of cmd, shift, opt and ctrl.")
                        }
                    }
                }
                let count = try whole(args, "count", 1...InputRequest.maximumKeyPresses, default: 1)
                self = .input(.pressKey(KeyChord(key, modifiers: modifiers), times: count), section: nil)
            case "scroll":
                let direction = try requiredString(args, "direction")
                guard direction == "up" || direction == "down" else {
                    throw ToolArguments.invalid("direction must be up or down.")
                }
                let lines = try whole(args, "lines", 1...InputRequest.maximumScrollLines, default: 3)
                self = .input(.scroll(lines: direction == "up" ? lines : -lines, over: try optionalReference(args, "target")),
                              section: section)
            case "drag":
                let hasOffset = object["dx"] != nil || object["dy"] != nil
                let end: InputRequest.DragEnd
                if let target = try optionalReference(args, "to") {
                    guard !hasOffset else { throw ToolArguments.invalid("drag takes to or dx/dy, not both.") }
                    end = .target(target)
                } else {
                    guard hasOffset else { throw ToolArguments.invalid("drag needs to, or dx and dy.") }
                    end = .offset(dx: try offset(args, "dx"), dy: try offset(args, "dy"))
                }
                self = .input(.drag(from: try reference(args, "from"), to: end), section: section)
            case "context_menu":
                self = .input(.contextMenu(on: try reference(args, "target"), item: try requiredString(args, "item")),
                              section: section)
            case "select":
                self = .select(try reference(args, "control"), try requiredString(args, "item"))
            default:
                let rawVerb = object["verb"] == nil ? "click" : try requiredString(args, "verb")
                guard let verb = ActionVerb(rawValue: rawVerb) else { throw ToolArguments.invalid("Unsupported action verb.") }
                let state: ControlState?
                if object["value"] != nil {
                    guard let value = ControlState(rawValue: try requiredString(args, "value")),
                          value == .on || value == .off else { throw ToolArguments.invalid("value must be on or off.") }
                    state = value
                } else { state = nil }
                if verb == .setToggle, state == nil { throw ToolArguments.invalid("set_toggle requires value on or off.") }
                if verb != .setToggle, state != nil { throw ToolArguments.invalid("value is only valid for set_toggle.") }
                self = .act(try reference(args, "target"), verb, section, state)
            }
        }
        func facts(expectation: ScreenExpectation?) -> BatchPolicy.StepFacts {
            switch self {
            case .act(let target, let verb, let section, _):
                return .init(kind: .act, target: target, section: section, verb: verb.rawValue, expectation: expectation)
            case .select(let control, let item):
                return .init(kind: .select, target: control, item: item, expectation: expectation)
            case .menu(let path): return .init(kind: .menu, item: path, expectation: expectation)
            case .input(let input, let section):
                switch input {
                case .typeText(_, let target, _): return .init(kind: .typeText, target: target, section: section, expectation: expectation)
                case .insertText: return .init(kind: .insertText, expectation: expectation)
                case .pressKey(let chord, _): return .init(kind: .pressKey, chord: chord, expectation: expectation)
                case .scroll(_, let target): return .init(kind: .scroll, target: target, section: section, expectation: expectation)
                case .drag(let from, _): return .init(kind: .drag, target: from, section: section, expectation: expectation)
                case .contextMenu(let target, let item):
                    return .init(kind: .contextMenu, target: target, section: section, item: item, expectation: expectation)
                }
            }
        }

        func addressed(to element: SceneElement) -> Step {
            let section = element.container ?? element.section
            switch self {
            case .act(_, let verb, _, let state): return .act(element.label, verb, section, state)
            case .select(_, let item): return .select(element.label, item)
            case .menu: return self
            case .input(let input, _):
                switch input {
                case .typeText(let text, _, let replace): return .input(.typeText(text, into: element.label, replacing: replace), section: section)
                case .scroll(let lines, _): return .input(.scroll(lines: lines, over: element.label), section: section)
                case .drag(_, let to): return .input(.drag(from: element.label, to: to), section: section)
                case .contextMenu(_, let item): return .input(.contextMenu(on: element.label, item: item), section: section)
                default: return self
                }
            }
        }

    }

}
