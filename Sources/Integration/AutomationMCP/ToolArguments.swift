import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// ToolArguments decodes a complete call before any effects begin.
enum ToolArguments {
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
            throw AutomationFailure("\(key) must be a nonempty string.")
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
        guard let title = supplied.string else { throw AutomationFailure("window must be a string.") }
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
    private static func whole(_ object: JSONValue, _ key: String, _ range: ClosedRange<Int>,
                              default fallback: Int) throws -> Int {
        guard object.object?[key] != nil else { return fallback }
        guard case .number(let value) = object[key], value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw AutomationFailure("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(value)
    }

    /// A drag offset in points, zero when the argument is absent.
    private static func offset(_ object: JSONValue, _ key: String) throws -> Double {
        guard object.object?[key] != nil else { return 0 }
        guard case .number(let value) = object[key], abs(value) <= maximumOffset else {
            throw AutomationFailure("\(key) must be a number of points within ±\(Int(maximumOffset)).")
        }
        return value
    }

    enum Step {
        case act(String, ActionVerb, String?, ControlState?)
        case select(String, String)
        case input(InputRequest.Input, section: String?)

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

        /// The step as the call contract keeps it.
        var callRequest: AgentCallRequest {
            switch self {
                case .act(let target, let verb, let section, let state):
                    .act(target: target, verb: verb, value: state, section: section)
                case .select(let control, let item):
                    .select(control: control, item: item)
                case .input(let input, let section):
                    .input(input, section: section)
            }
        }

        init(_ name: String, _ args: JSONValue) throws {
            guard (["act", "select"] + inputTools).contains(name),
                  let definition = AutomationTools.definitions.first(where: { $0["name"].string == name }) else {
                throw AutomationFailure("batch supports act, select, type_text, insert_text, press_key, scroll, drag and "
                                        + "context_menu only.")
            }
            let permitted = Set(definition["inputSchema"]["properties"].object?.keys.map { $0 } ?? [])
                .union(["operation"])
            guard let object = args.object, Set(object.keys).isSubset(of: permitted) else {
                throw AutomationFailure("Unknown step argument.")
            }
            let section = try optionalString(args, "section")
            switch name {
            case "type_text":
                guard let text = args["text"].string, !text.isEmpty else {
                    throw AutomationFailure("text must be a nonempty string.")
                }
                if object["replace"] != nil, args["replace"].bool == nil {
                    throw AutomationFailure("replace must be true or false.")
                }
                self = .input(.typeText(text, into: try reference(args, "target"),
                                        replacing: args["replace"].bool ?? true), section: section)
            case "insert_text":
                guard let text = args["text"].string, !text.isEmpty else {
                    throw AutomationFailure("text must be a nonempty string.")
                }
                self = .input(.insertText(text, expecting: try optionalString(args, "expected_value")), section: nil)
            case "press_key":
                guard let key = KeyChord.Name(try requiredString(args, "key")) else {
                    throw AutomationFailure("key must be return, tab, escape, space, delete, an arrow, a letter, a digit, / or ~.")
                }
                var modifiers: KeyModifiers = []
                if object["modifiers"] != nil {
                    guard let tokens = args["modifiers"].array else {
                        throw AutomationFailure("modifiers must be a list of cmd, shift, opt and ctrl.")
                    }
                    for token in tokens {
                        switch token.string {
                        case "cmd"  : modifiers.insert(.command)
                        case "shift": modifiers.insert(.shift)
                        case "opt"  : modifiers.insert(.option)
                        case "ctrl" : modifiers.insert(.control)
                        default     : throw AutomationFailure("modifiers must be a list of cmd, shift, opt and ctrl.")
                        }
                    }
                }
                let count = try whole(args, "count", 1...InputRequest.maximumKeyPresses, default: 1)
                self = .input(.pressKey(KeyChord(key, modifiers: modifiers), times: count), section: nil)
            case "scroll":
                let direction = try requiredString(args, "direction")
                guard direction == "up" || direction == "down" else {
                    throw AutomationFailure("direction must be up or down.")
                }
                let lines = try whole(args, "lines", 1...InputRequest.maximumScrollLines, default: 3)
                self = .input(.scroll(lines: direction == "up" ? lines : -lines, over: try optionalReference(args, "target")),
                              section: section)
            case "drag":
                let hasOffset = object["dx"] != nil || object["dy"] != nil
                let end: InputRequest.DragEnd
                if let target = try optionalReference(args, "to") {
                    guard !hasOffset else { throw AutomationFailure("drag takes to or dx/dy, not both.") }
                    end = .target(target)
                } else {
                    guard hasOffset else { throw AutomationFailure("drag needs to, or dx and dy.") }
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
                guard let verb = ActionVerb(rawValue: rawVerb) else { throw AutomationFailure("Unsupported action verb.") }
                let state: ControlState?
                if object["value"] != nil {
                    guard let value = ControlState(rawValue: try requiredString(args, "value")),
                          value == .on || value == .off else { throw AutomationFailure("value must be on or off.") }
                    state = value
                } else { state = nil }
                if verb == .setToggle, state == nil { throw AutomationFailure("set_toggle requires value on or off.") }
                if verb != .setToggle, state != nil { throw AutomationFailure("value is only valid for set_toggle.") }
                self = .act(try reference(args, "target"), verb, section, state)
            }
        }
    }

}
