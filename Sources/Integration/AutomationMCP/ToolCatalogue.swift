import AppAdapters
import Capabilities
import Memory
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import TaskRouting

nonisolated enum ToolSurface: Sendable { case tagged }

/// ToolCatalogue defines the tools, instructions and interruption policy for each channel set.
enum ToolCatalogue {
    static func instructions(for channels: AutomationChannels) -> String {
        baseInstructions(for: channels) + "\n" + taskInstructions
    }

    static var taskInstructions: String {
        ModelText.text(.init(rawValue: "task_cycle.instructions.v2"))
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
        let text = mcpClientInstructions
        return form == .firstLine ? String(text.prefix { $0 != "\n" }) : text
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
    private static func legacyDefinitions(for channels: AutomationChannels) -> [JSONValue] {
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
                "enum": .array(ActionVerb.allCases.filter { $0 != .tripleClick }.map { .string($0.rawValue) })]),
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
        ].filter { channels.contains(.adapters) || !Self.adapterTools.contains($0["name"].string ?? "") }
            .filter { channels.contains(.web) || $0["name"].string != "collect_posts" }
    }

    static let currentSurface = ToolSurface.tagged

    static let fixedPartCeiling = 15_360
    static let descriptionCeiling = 4_096

    /// Counts the UTF-8 instructions and canonical served list, including its array delimiters.
    /// Throws when a definition cannot be encoded, including a non-finite number.
    static func fixedPartBytes(instructions: String, definitions: [JSONValue]) throws -> Int {
        instructions.utf8.count + (try JSONValue.canonicalEncoder().encode(JSONValue.array(definitions))).count
    }

    static func isFixedPartWithinBudget(instructions: String, definitions: [JSONValue]) throws -> Bool {
        try fixedPartBytes(instructions: instructions, definitions: definitions) <= fixedPartCeiling
    }

    static func coreSizeWarns(bytes: Int, approvedBytes: Int) -> Bool {
        Double(bytes) > Double(approvedBytes) * 1.2
    }

    /// Adds policy arguments only in the policy arm; the default definitions stay byte identical.
    private static func batchDefinitions(_ definitions: [JSONValue]) -> [JSONValue] {
        guard let batch = definitions.first(where: { $0["name"].string == "batch" }) else { return definitions }
        let variants = batch["inputSchema"]["properties"]["steps"]["items"]["oneOf"].array ?? []
        var fields: [String: JSONValue] = [:]
        var operations: [JSONValue] = []
        for variant in variants {
            for (key, value) in variant["properties"].object ?? [:] where key != "operation" { fields[key] = value }
            operations.append(variant["properties"]["operation"]["const"])
        }
        operations.append(.string("menu"))
        fields["operation"] = .object(["type": .string("string"), "enum": .array(operations)])
        fields["path"] = .object(["type": .string("string")])
        fields["expect"] = .object(["type": .string("object")])
        let steps: JSONValue = .object(["type": .string("array"), "minItems": .number(1),
            "maxItems": .number(Double(BatchPolicy.maximumSteps)), "items": schema(fields, ["operation"])])
        return definitions.compactMap { definition in
            guard var tool = definition.object, let name = tool["name"]?.string,
                  var input = tool["inputSchema"]?.object, var properties = input["properties"]?.object else { return definition }
            if name == "batch" {
                properties["steps"] = steps
                tool["description"] = .string(ModelText.text(.init(rawValue: "batch.description.v2")))
            }
            input["properties"] = .object(properties)
            tool["inputSchema"] = .object(input)
            return .object(tool)
        }
    }

    /// Serves the canonical compact tools with the current session implicit.
    static func availableDefinitions(
        for channels: AutomationChannels,
        surface: ToolSurface = currentSurface
    ) -> [JSONValue] {
        let definitions = batchDefinitions(legacyDefinitions(for: channels))
        return cycleDefinitions(definitions.map { definition in
            guard var tool = definition.object, let name = tool["name"]?.string,
                  var input = tool["inputSchema"]?.object else { return definition }
            var properties = input["properties"]?.object ?? [:]
            properties.removeValue(forKey: "session")
            input["required"] = .array((input["required"]?.array ?? []).filter { $0.string != "session" })
            if name == "batch", var steps = properties["steps"]?.object,
               let variants = steps["items"]?["oneOf"].array {
                var fields: [String: JSONValue] = [:]
                var operations: [JSONValue] = []
                for variant in variants {
                    for (key, value) in variant["properties"].object ?? [:] where key != "operation" {
                        fields[key] = value
                    }
                    operations.append(variant["properties"]["operation"]["const"])
                }
                fields["operation"] = .object(["type": .string("string"), "enum": .array(operations)])
                steps["items"] = schema(fields, ["operation"])
                properties["steps"] = .object(steps)
            }
            if name == "open_session", var named = properties["named"]?.object {
                named["description"] = .string(ModelText.text(.init(rawValue: "tool.open_session.v2.named")))
                properties["named"] = .object(named)
            }
            if name == "memory_task" {
                // The task parser retains its full validation; the served schema names the envelope and types.
                properties = properties.mapValues(compactTaskParameter)
            }
            input["properties"] = .object(properties)
            tool["inputSchema"] = .object(input)
            let description = name == "batch"
                ? ModelText.text(.init(rawValue: "batch.description.v2"))
                : ModelText.text(.init(rawValue: "tool.\(name).v2.description"))
            tool["description"] = .string(description)
            return .object(tool)
        }, surface: surface)
    }

    private static func cycleDefinitions(_ definitions: [JSONValue], surface: ToolSurface) -> [JSONValue] {
        let gestures: Set<String> = ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag",
                                     "context_menu", "batch", "menu", "press", "app_call", "collect_posts"]
        var result = definitions.filter { $0["name"].string != MemoryTaskTool.name }.map { definition in
            guard let name = definition["name"].string, gestures.contains(name),
                  var tool = definition.object, var input = tool["inputSchema"]?.object,
                  var properties = input["properties"]?.object else { return definition }
            properties["step"] = .object(["type": .string("string"), "pattern": .string("^r[1-9][0-9]*$")])
            if name == "batch", var steps = properties["steps"]?.object, var items = steps["items"]?.object {
                // Each row is parsed by ToolArguments.step before recording or gestures.
                // Keep its schema within the shared validator's supported vocabulary.
                let step: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
                func marked(_ value: JSONValue) -> JSONValue {
                    guard var schema = value.object, var fields = schema["properties"]?.object else { return value }
                    fields["step"] = step
                    schema["properties"] = .object(fields)
                    return .object(schema)
                }
                if let variants = items["oneOf"]?.array { items["oneOf"] = .array(variants.map(marked)) }
                else { items = marked(.object(items)).object ?? items }
                steps["items"] = .object(items)
                properties["steps"] = .object(steps)
            }
            input["properties"] = .object(properties)
            tool["inputSchema"] = .object(input)
            return JSONValue.object(tool)
        }
        let legacy = MemoryTaskTool.definition["inputSchema"]["properties"]
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        let row = schema(["id": text, "title": text, "app": text, "part": text, "expect": .object([:])], ["title"])
        let rows: JSONValue = .object(["type": .string("array"), "items": row, "minItems": .number(1), "maxItems": .number(Double(Todo.rowLimit))])
        result.append(.object(["name": .string("plan"),
            "description": .string(ModelText.text(.init(rawValue: "task_cycle.plan.v2"))),
            "inputSchema": schema(["request": text, "inputs": compactTaskParameter(legacy["inputs"]), "rows": rows, "reason": text], ["rows"]),
            "annotations": .object(["readOnlyHint": .bool(false)])]))
        result.append(.object(["name": .string("end"),
            "description": .string(ModelText.text(.init(rawValue: "task_cycle.end.v2"))),
            "inputSchema": schema(["outcome": .object(["type": .string("string"),
                "enum": .array(["completed", "failed", "abandoned"].map(JSONValue.string))]),
                "note": text, "result_check": compactTaskParameter(legacy["result_check"])], ["outcome"]),
            "annotations": .object(["readOnlyHint": .bool(false)])]))
        return result
    }

    /// Registered now; service and discoverability belong to the person interaction increment.
    static var askPersonDefinition: JSONValue {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        return .object(["name": .string("ask_person"),
            "description": .string(ModelText.text(.init(rawValue: "task_cycle.ask_person.v2"))),
            "inputSchema": schema(["question": text, "context": text,
                "answer": .object(["type": .string("string"), "enum": .array(["single", "multiple", "text"].map(JSONValue.string))]),
                "options": .object(["type": .string("array"), "items": text, "minItems": .number(2), "maxItems": .number(4)])],
                ["question", "answer"])])
    }

    private static func compactTaskParameter(_ value: JSONValue) -> JSONValue {
        guard let fields = value.object else { return value }
        if fields["type"]?.string == "object" {
            let properties = (fields["properties"]?.object ?? [:]).mapValues { _ in JSONValue.object([:]) }
            return .object(["type": .string("object"), "properties": .object(properties),
                            "additionalProperties": .bool(false)])
        }
        if let variants = fields["anyOf"]?.array {
            return .object(["anyOf": .array(variants.map(compactTaskParameter))])
        }
        if fields["type"]?.string == "array", let items = fields["items"] {
            var compact = fields
            compact["items"] = compactTaskParameter(items)
            return .object(compact)
        }
        return value
    }

    /// The tools that reach the app adapters, served only with `.adapters`.
    static let adapterTools: Set<String> = ["app_capabilities", "app_call"]
    /// The nonisolated policy view uses the same explicit core declarations as the served contracts.
    nonisolated static let policyRegistry: CapabilityRegistry = {
        let names = ["status", "windows", "apps", "open_session", "observe", "act", "select", "type_text",
                     "insert_text", "press_key", "scroll", "drag", "context_menu", "batch", "menu", "press",
                     "app_capabilities", "app_call", "close_session", "collect_posts", "memory_task", "plan", "end", "ask_person", "find", "call", "triple_click", "reconcile_call"]
        do {
            return try CapabilityRegistry(core: names.compactMap {
                coreContract(name: $0, description: "", inputSchema: .null)
            }, registered: [])
        } catch {
            preconditionFailure("Invalid core capability declarations: \(error)")
        }
    }()

    nonisolated static func interruptionPolicy(for name: String) -> InterruptionClass {
        return policyRegistry.interruptionClass(of: name, arguments: .null)
    }

    /// Composes effective contracts from served definitions and adapter metadata.
    static func contracts(for channels: AutomationChannels, adapters: AppAdapters? = nil) -> [CapabilityContract] {
        var contracts = availableDefinitions(for: channels).compactMap { definition in
            coreContract(
                name: definition["name"].string ?? "",
                description: catalogueNames.contains(definition["name"].string ?? "")
                    ? ModelText.text(.init(rawValue: "catalogue." + (definition["name"].string ?? "")))
                    : definition["description"].string ?? "",
                inputSchema: definition["inputSchema"]
            )
        }
        if channels.contains(.adapters) {
            for adapter in (adapters ?? AppAdapters.standard()).adapters {
                for verb in adapter.verbs {
                    let id = CapabilityID(rawValue: "\(adapter.name).\(verb.name)")
                    guard !contracts.contains(where: { $0.id == id }) else { continue }
                    let summary = verb.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    contracts.append(CapabilityContract(
                        id: id,
                        group: ModelText.groupName(.integration),
                        description: summary + (summary.hasSuffix(".") ? " " : ". ")
                            + ModelText.text(.init(rawValue: "catalogue.adapter." + effect(of: verb.safety).rawValue)),
                        inputSchema: verb.schema,
                        effect: effect(of: verb.safety),
                        interruption: .mutating,
                        verification: verb.confirmation == .readBack
                            ? .readBack(description: verb.readBack) : .none(reason: "no read-back"),
                        channel: .adapter,
                        origin: .adapter(adapter.name),
                        memory: .agentCall(tool: "app_call"),
                        takesSession: false,
                        parallelSafe: false
                    ))
                }
            }
        }
        for definition in [findDefinition, callDefinition, tripleClickDefinition, reconcileCallDefinition] {
            if let contract = coreContract(name: definition["name"].string ?? "",
                description: definition["description"].string ?? "", inputSchema: definition["inputSchema"]) {
                contracts.append(contract)
            }
        }
        return contracts.map(composedContract)
    }

    static func definitions(for channels: AutomationChannels, surface: ToolSurface = currentSurface) -> [JSONValue] {
        return definitions(for: .init(attendance: .none, level: .actConnectors), channels: channels)
    }

    private static func effect(of safety: AdapterVerb.Safety) -> EffectClass {
        switch safety {
        case .read: .read
        case .write: .write
        case .irreversible: .irreversible
        }
    }

    private nonisolated static func coreContract(
        name: String,
        description: String,
        inputSchema: JSONValue
    ) -> CapabilityContract? {
        let effect: EffectClass
        let interruption: InterruptionClass
        let channel: Channel
        let verification: Verification
        switch name {
        case "status", "windows", "apps", "find":
            (effect, interruption, channel) = (.read, .readOnly, .braus)
            verification = .none(reason: "read only")
        case "observe":
            (effect, interruption, channel) = (.read, .readOnly, .seat)
            verification = .none(reason: "Scene observation")
        case "app_capabilities":
            (effect, interruption, channel) = (.read, .readOnly, .adapter)
            verification = .none(reason: "Read-only result")
        case "collect_posts":
            (effect, interruption, channel) = (.write, .mutating, .web)
            verification = .none(reason: "scrolling collection")
        case "ask_person":
            (effect, interruption, channel) = (.read, .readOnly, .braus)
            verification = .resultCheck
        case "plan", "end":
            (effect, interruption, channel) = (.read, .mutating, .braus)
            verification = .resultCheck
        case "memory_task":
            (effect, interruption, channel) = (.read, .mutating, .braus)
            verification = .resultCheck
        case "reconcile_call":
            (effect, interruption, channel) = (.write, .mutating, .braus)
            verification = .resultCheck
        case "open_session":
            (effect, interruption, channel) = (.write, .openingScene, .seat)
            verification = .engineVerdict
        case "app_call":
            (effect, interruption, channel) = (.write, .mutating, .adapter)
            verification = .none(reason: "The named verb owns verification")
        case "close_session":
            (effect, interruption, channel) = (.write, .mutating, .braus)
            verification = .none(reason: "session cleanup")
        case "call", "triple_click", "act", "select", "type_text", "insert_text", "press_key", "scroll", "drag",
             "context_menu", "batch", "menu", "press":
            (effect, interruption, channel) = (.write, .mutating, .seat)
            verification = .engineVerdict
        default:
            return nil
        }
        let agentTool = AgentTool(rawValue: name)
        return CapabilityContract(
            id: CapabilityID(rawValue: name),
            group: ModelText.groupName(["status", "windows", "apps"].contains(name)
                ? .inspection : name == "close_session" ? .session : .interaction),
            description: description,
            inputSchema: inputSchema,
            effect: effect,
            interruption: interruption,
            verification: verification,
            channel: channel,
            origin: .core,
            memory: ["find", "call", "reconcile_call"].contains(name) ? .notRecorded(reason: "discovery or dispatch")
                : name == "triple_click" ? .capabilityStep : agentTool.map { .agentCall(tool: $0.rawValue) }
                ?? .notRecorded(reason: "Recorded by its own interaction cycle"),
            takesSession: name == "triple_click" || (agentTool?.takesSession ?? (inputSchema["required"].array?.contains(.string("session")) == true)),
            parallelSafe: false
        )
    }
    static func schema(_ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }

}
