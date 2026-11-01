import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import TaskRouting

/// ToolCatalogue defines the tools, instructions and interruption policy for each channel set.
enum ToolCatalogue {
    static func instructions(for channels: AutomationChannels) -> String {
        baseInstructions(for: channels) + "\n" + MemoryTaskTool.instructions
    }

    static func routes(for channels: AutomationChannels) -> String {
        guard !channels.isDisjoint(with: [.native, .web]) else { return ModelText.text(.init(rawValue: "tool_catalogue.routes.v1")) }
        let native = channels.contains(.native)
            ? ModelText.text(.init(rawValue: "tool_catalogue.native.v1"))
                + ModelText.text(.init(rawValue: "tool_catalogue.native.v1.2"))
            : ModelText.text(.init(rawValue: "tool_catalogue.native.v1.3"))
        guard channels.contains(.web) else { return native }
        return native + ModelText.text(.init(rawValue: "tool_catalogue.native.v1.4"))
            + SharedRoutes.browserEngine + ModelText.text(.init(rawValue: "tool_catalogue.native.v1.5"))
    }

    /// What the browser engine is to the person: Braus's own Chrome and profile, not theirs, with no window unless they
    /// show it; a sign-in there is theirs to make in its window; a failure there sends nowhere without asking. Only the
    /// person's Use My Chrome, or one of their Chrome profiles paired with Braus that they choose, makes it their own
    /// Chrome for a conversation, which every answer then says under browser.
    static let browserEngineProfile = ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.2"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.3"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.4"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.5"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.6"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.7"))
        + ModelText.text(.init(rawValue: "tool_catalogue.browserEngineProfile.v1.8"))

    /// With the adapters, the one sentence on files (P12): folders, files and text files go through the `files`
    /// adapter's verbs, never through Finder, TextEdit or a shell.
    static func files(for channels: AutomationChannels) -> String {
        guard channels.contains(.adapters) else { return "" }
        return ModelText.text(.init(rawValue: "tool_catalogue.files.v1"))
            + ModelText.text(.init(rawValue: "tool_catalogue.files.v1.2"))
            + ModelText.text(.init(rawValue: "tool_catalogue.files.v1.3"))
    }

    /// How the web is reached: the browser engine when it is composed, else the browser app on the Seat.
    static func web(for channels: AutomationChannels) -> String {
        let browserApp = ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1"))
        guard channels.contains(.web) else {
            return ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.2"))
                + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.3")) + browserApp
        }
        return (ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.4"))
            + "\(SharedRoutes.browserEngine)"
            + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.5")))

                + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.6"))
                + browserEngineProfile
                + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.7"))
                + bulkReading
                + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.8"))
            + ModelText.text(.init(rawValue: "tool_catalogue.browserApp.v1.9")) + browserApp
    }

    /// How many posts or articles of a page are read: in one collect_posts call, never by observing and scrolling.
    static let bulkReading = ModelText.text(.init(rawValue: "tool_catalogue.bulkReading.v1"))
        + ModelText.text(.init(rawValue: "tool_catalogue.bulkReading.v1.2"))
        + ModelText.text(.init(rawValue: "tool_catalogue.bulkReading.v1.3"))
        + ModelText.text(.init(rawValue: "tool_catalogue.bulkReading.v1.4"))

    // MARK: MCP client instructions

    /// MCPInstructionsForm selects the complete client guidance or its standalone opening line.
    static func mcpInstructions(_ form: AutomationTools.MCPInstructionsForm) -> String {
        switch form {
        case .firstLine: String(mcpClientInstructions.prefix { $0 != "\n" })
        case .full: mcpClientInstructions
        }
    }

    static let mcpClientInstructions = ModelText.text(.init(rawValue: "tool_catalogue.mcpClientInstructions.v1"))

    static func baseInstructions(for channels: AutomationChannels) -> String {
        (ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1"))
            + "\(routes(for: channels))"
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.2"))
            + "\(web(for: channels))"
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.3"))
            + "\(files(for: channels))"
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.4"))
            + "\(channels.contains(.adapters) ? ModelText.text(.init(rawValue: "prompt.adapters.v1")) : "")"
            + ModelText.text(.init(rawValue: "tool_catalogue.baseInstructions.v1.5")))
    }

    /// How to read a scene, in a tool description rather than the instructions: a client that serves
    /// only the definitions (the bare MCP server of the benchmark) still sends it to the model.
    static let sceneLegend = ModelText.text(.init(rawValue: "tool_catalogue.sceneLegend.v1"))

    /// What the lines of a changes answer mean.
    static let changesLegend = ModelText.text(.init(rawValue: "tool_catalogue.changesLegend.v1"))

    static let webOpening = ModelText.text(.init(rawValue: "tool_catalogue.webOpening.v1"))
        + ModelText.text(.init(rawValue: "tool_catalogue.webOpening.v1.2"))
        + ModelText.text(.init(rawValue: "tool_catalogue.webOpening.v1.3"))

    /// The tools of an instance composed with no channel beyond the Seat (`definitions(for:)`).
    static func definitions(for channels: AutomationChannels) -> [JSONValue] {
        let routes = !channels.isDisjoint(with: [.web, .adapters])
        let better = [channels.contains(.web) ? ModelText.text(.init(rawValue: "tool_catalogue.better.v1")) : nil,
                      channels.contains(.adapters) ? ModelText.text(.init(rawValue: "tool_catalogue.better.v1.2")) : nil]
            .compactMap { $0 }.joined(separator: ", ")
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        let section: JSONValue = .object([
            "type": .string("string"), "minLength": .number(1),
            "description": .string(ModelText.text(.init(rawValue: "tool_catalogue.section.v1")))
        ])
        let session = ["session": text]
        let action: [String: JSONValue] = [
            "target": text, "verb": .object(["type": .string("string"),
                "enum": .array(ActionVerb.allCases.map { .string($0.rawValue) })]),
            "value": .object(["type": .string("string"), "enum": .array([.string("on"), .string("off")])]),
            "section": section
        ]
        func whole(_ range: ClosedRange<Int>) -> JSONValue {
            .object(["type": .string("integer"), "minimum": .number(Double(range.lowerBound)),
                     "maximum": .number(Double(range.upperBound))])
        }
        func choice(_ values: [String]) -> JSONValue {
            .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
        }
        let points: JSONValue = .object(["type": .string("number"), "minimum": .number(-ToolArguments.maximumOffset),
                                         "maximum": .number(ToolArguments.maximumOffset)])
        let inputs: [String: [String: JSONValue]] = [
            "type_text": ["target": text, "text": text, "section": section, "replace": .object(["type": .string("boolean")])],
            "insert_text": ["text": text, "expected_value": text],
            "press_key": ["key": choice(KeyChord.Name.all),
                          "modifiers": .object(["type": .string("array"), "uniqueItems": .bool(true),
                                                "items": choice(["cmd", "shift", "opt", "ctrl"])]),
                          "count": whole(1...InputRequest.maximumKeyPresses)],
            "scroll": ["target": text, "section": section, "direction": choice(["up", "down"]),
                       "lines": whole(1...InputRequest.maximumScrollLines)],
            "drag": ["from": text, "to": text, "dx": points, "dy": points, "section": section],
            "context_menu": ["target": text, "item": text, "section": section]
        ]
        let required: [String: [String]] = [
            "type_text": ["target", "text"], "insert_text": ["text"], "press_key": ["key"],
            "scroll": ["direction"], "drag": ["from"],
            "context_menu": ["target", "item"]
        ]
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  _ required: [String], readOnly: Bool = false) -> JSONValue {
            .object(["name": .string(name), "description": .string(description),
                     "inputSchema": schema(properties, required),
                     "annotations": .object(["readOnlyHint": .bool(readOnly)])])
        }
        func input(_ name: String, _ description: String) -> JSONValue {
            tool(name, description, session.merging(inputs[name] ?? [:], uniquingKeysWith: { $1 }),
                 ["session"] + (required[name] ?? []))
        }
        func step(_ name: String) -> JSONValue {
            schema((inputs[name] ?? [:]).merging(["operation": .object(["const": .string(name)])],
                                                 uniquingKeysWith: { $1 }),
                   ["operation"] + (required[name] ?? []))
        }
        return [
            tool("status", ModelText.text(.init(rawValue: "tool_catalogue.step.v1")), [:], [], readOnly: true),
            tool("windows", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.2")),
                 ["app": text], [], readOnly: true),
            tool("apps", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.3"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.4"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.5"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.6")),
                 ["query": text], [], readOnly: true),
            tool("open_session", (channels.isDisjoint(with: [.native, .web])
                    ? ModelText.text(.init(rawValue: "tool_catalogue.step.v1.7"))
                    : ModelText.text(.init(rawValue: "tool_catalogue.step.v1.8"))
                        + Self.routes(for: channels)
                        + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.9")))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.10"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.11"))
                 + (routes ? ModelText.text(.init(rawValue: "tool_catalogue.step.v1.12"))
                    + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.13")) + better

                        + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.14"))
                        + SharedRoutes.namedApp
                        + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.15")) : "")
                 + (channels.contains(.web) ? webOpening : "")
                 + Self.sceneLegend,
                 ["app": text, "window": .object(["type": .string("string")])].merging(routes ? [
                    "named": .object(["type": .string("boolean"),
                                      "description": .string(ModelText.text(.init(rawValue: "tool_catalogue.step.v1.16"))
                                                             + SharedRoutes.namedApp)])
                 ] : [:], uniquingKeysWith: { $1 }), ["app"]),
            tool("observe", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.17"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.18"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.19"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.20"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.21")) + Self.changesLegend,
                 session.merging(["full": .object(["type": .string("boolean")])], uniquingKeysWith: { $1 }),
                 ["session"], readOnly: true),
            tool("act", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.22"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.23"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.24")),
                 session.merging(action, uniquingKeysWith: { $1 }), ["session", "target"]),
            tool("select", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.25")),
                 session.merging(["control": text, "item": text], uniquingKeysWith: { $1 }),
                 ["session", "control", "item"]),
            input("type_text", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.26"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.27"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.28"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.29"))),
            input("insert_text", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.30"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.31"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.32"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.33"))),
            input("press_key", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.34"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.35"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.36"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.37"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.38"))),
            input("scroll", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.39"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.40"))),
            input("drag", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.41"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.42"))),
            input("context_menu", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.43"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.44"))
                  + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.45"))),
            tool("batch", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.46"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.47"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.48")),
                 session.merging(["steps": .object(["type": .string("array"), "minItems": .number(1),
                     "maxItems": .number(20), "items": .object(["oneOf": .array([
                         schema(action.merging(["operation": .object(["const": .string("act")])],
                                               uniquingKeysWith: { $1 }), ["operation", "target"]),
                         schema(["operation": .object(["const": .string("select")]), "control": text, "item": text],
                                ["operation", "control", "item"])
                     ] + ToolArguments.inputTools.map(step))])])], uniquingKeysWith: { $1 }), ["session", "steps"]),
            tool("menu", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.49"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.50"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.51"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.52"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.53"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.54"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.55"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.56")),
                 session.merging(["path": text], uniquingKeysWith: { $1 }), ["session", "path"]),
            tool("press", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.57"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.58"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.59"))
                 + ModelText.text(.init(rawValue: "tool.press.v1.description.ending")),
                 session.merging(["button": text], uniquingKeysWith: { $1 }), ["session", "button"]),
            tool("app_capabilities", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.60"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.61"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.62"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.63")),
                 ["app": text, "query": text], ["app"], readOnly: true),
            tool("app_call", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.64"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.65"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.66"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.67"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.68")),
                 ["app": text, "verb": text,
                  "arguments": .object(["type": .string("object"),
                                        "description": .string(ModelText.text(.init(rawValue: "tool_catalogue.step.v1.69")))])],
                 ["app", "verb"]),
            tool("close_session", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.70"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.71"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.72")),
                 session, ["session"]),
            tool("collect_posts", ModelText.text(.init(rawValue: "tool_catalogue.step.v1.73"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.74"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.75"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.76"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.77"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.78"))
                 + ModelText.text(.init(rawValue: "tool_catalogue.step.v1.79")),
                 session.merging(["target": whole(PostCollectionRequest.targets),
                                  "max_scrolls": whole(PostCollectionRequest.scrolls),
                                  "seconds": whole(PostCollectionRequest.wholeSeconds)],
                                 uniquingKeysWith: { $1 }),
                 ["session", "target"]),
            MemoryTaskTool.definition,
            HumanStepTool.definition
        ].filter { channels.contains(.adapters) || !Self.adapterTools.contains($0["name"].string ?? "") }
            .filter { channels.contains(.web) || $0["name"].string != "collect_posts" }
    }

    /// The tools that reach the app adapters, served only with `.adapters`.
    static let adapterTools: Set<String> = ["app_capabilities", "app_call"]
    nonisolated static func interruptionPolicy(for name: String) -> AutomationTools.InterruptionPolicy {
        switch name {
        case "status", "windows", "apps", "observe", "app_capabilities", "human_step": .readOnly
        case "open_session": .openingScene
        case "act", "select", "type_text", "insert_text", "press_key", "scroll", "drag",
             "context_menu", "batch", "menu", "press", "app_call", "close_session",
             "collect_posts", "memory_task": .mutating
        default: .mutating
        }
    }
    static func schema(_ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }

}
