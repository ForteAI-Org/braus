import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing
@testable import AutomationMCP

@Suite
@MainActor
struct ToolSurfaceGoldenTests {
    @Test(arguments: 0..<8)
    func channelSurface(_ bits: Int) throws {
        var channels: AutomationChannels = []
        var names: [String] = []
        for (index, entry) in [("native", AutomationChannels.native), ("web", .web), ("adapters", .adapters)].enumerated() {
            if bits & (1 << index) != 0 { channels.insert(entry.1); names.append(entry.0) }
        }
        let value = JSONValue.object([
            "definitions": .array(AutomationTools.definitions(for: channels)),
            "instructions": .string(AutomationTools.instructions(for: channels)),
            "mcpFirstLine": .string(AutomationTools.mcpInstructions(.firstLine)),
            "mcpInstructions": .string(AutomationTools.mcpInstructions(.full))
        ])
        try ToolGolden.compare(value, named: "tools-" + (names.isEmpty ? "none" : names.joined(separator: "-")))
    }
}

@Suite
@MainActor
struct ToolResultGoldenTests {
    @Test
    func resultsAndTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tu3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let session = ToolResultSession()
        session.scene = SceneSnapshot(
            bundleID: "test.synthetic", appName: "Synthetic Mixer", windowTitle: "Synthetic New Paths",
            viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
            elements: (0..<20).map {
                SceneElement(id: "row\($0)", kind: .control, label: "Track \($0)",
                             bounds: NormalizedRect(x: 0.1, y: 0.04 * Double($0), width: 0.2, height: 0.03))
            })
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "tool-results", traceID: "fixed-trace")
        var transcript: [String] = []
        tools.record = { transcript.append($0) }
        var results: [JSONValue] = []
        func call(_ name: String, _ fields: [String: JSONValue] = [:], inSession: Bool = false) async throws {
            var fields = fields
            if inSession { fields["session"] = .string(try #require(session.id).uuidString) }
            results.append(try await tools.call(name, .object(fields)))
        }
        try await call("status")
        try await call("open_session", ["app": .string("Synthetic Mixer")])
        try await call("observe", ["full": .bool(true)], inSession: true)
        session.scene.elements[0].state = .on
        try await call("observe", inSession: true)
        try await call("act", ["target": .string("Track 0")], inSession: true)
        try await call("type_text", ["target": .string("Password"), "text": .string("fake-value")], inSession: true)
        #expect(!transcript.joined().contains("fake-value"))
        session.scene.windowTitle = "Batch result"
        try await call("batch", ["steps": .array([
            .object(["operation": .string("act"), "target": .string("Track 1")]),
            .object(["operation": .string("select"), "control": .string("Mode"), "item": .string("Stereo")])
        ])], inSession: true)
        session.scene.windowTitle = "Menu result"
        try await call("menu", ["path": .string("File > Save")], inSession: true)
        session.memoryDirectory = directory
        session.memoryApplication = "test.synthetic"
        try await call("memory_task", ["operation": .string("begin"), "goal": .string("Set a track"), "recall": .bool(false)])
        #expect(tools.openTask != nil)
        try await call("memory_task", ["operation": .string("update"), "result": .string("Track enabled")])
        try await call("act", ["target": .string("Track 0")], inSession: true)
        try await call("memory_task", ["operation": .string("end"), "outcome": .string("completed"),
                                      "result_check": .object(["element": .string("Track 0"), "state": .string("on")])])
        #expect(tools.openTask == nil)
        do {
            _ = try await tools.call("act", .object(["session": .string("stale"), "target": .string("Track 0")]))
            Issue.record("A stale session was accepted")
        } catch let error as AutomationFailure {
            results.append(.object(["refused": .string(error.description)]))
        }
        try await call("memory_task", ["operation": .string("begin"), "goal": .string("A stopped task"), "recall": .bool(false)])
        #expect(tools.openTask != nil)
        tools.markTaskInterrupted()
        try await tools.finishInterruptedTask()
        results.append(.object(["stopped": tools.takeStoppedTaskNotice().map(JSONValue.string) ?? .null]))
        #expect(tools.openTask == nil)
        #expect(tools.takeStoppedTaskNotice() == nil)
        try ToolGolden.compare(.array(results), named: "results-calls")
        try ToolGolden.compare(.array(transcript.map(JSONValue.string)), named: "results-transcript")
    }
}

/// ToolGolden normalizes only the tool envelopes and transcript suffixes before replacing variable values.
@MainActor
enum ToolGolden {
    static func normalized(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func embedded(_ text: String) throws -> String? {
            let data = Data(text.utf8)
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data) }
            catch { return nil } // Ordinary text is not an embedded JSON object or array.
            guard object is [String: Any] || object is [Any] else { return nil }
            return String(decoding: try JSONSerialization.data(withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        func candidateIdentity(_ value: JSONValue) -> JSONValue {
            // Only memory_task end's candidate.id suffix and its exact identity in next use this regex:
            // ^candidate-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}-([0-9a-f]{1,16})$
            guard case .object(var object) = value, case .object(var candidate)? = object["candidate"],
                  let id = candidate["id"]?.string else { return value }
            let pattern = "^candidate-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}-([0-9a-f]{1,16})$"
            guard id.range(of: pattern, options: .regularExpression) != nil,
                  let separator = id.lastIndex(of: "-") else { return value }
            let kept = String(id[...separator]) + "<suffix>"
            candidate["id"] = .string(kept)
            object["candidate"] = .object(candidate)
            if let next = object["next"]?.string {
                object["next"] = .string(next.replacingOccurrences(of: id, with: kept))
            }
            return .object(object)
        }
        func payload(_ text: String) throws -> String? {
            guard let json = try embedded(text) else { return nil }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return String(decoding: try encoder.encode(candidateIdentity(value)), as: UTF8.self)
        }
        var rows = value.array ?? [value]
        for index in rows.indices {
            if case .string(let line) = rows[index] {
                for position in line.indices where line[position] == " " {
                    let start = line.index(after: position)
                    guard start < line.endIndex, line[start] == "{" || line[start] == "[" else { continue }
                    if let json = try payload(String(line[start...])) {
                        rows[index] = .string(String(line[...position]) + json)
                        break
                    }
                }
            } else if case .object(var object) = rows[index] {
                if var content = object["content"]?.array {
                    for item in content.indices {
                        if case .object(var fields) = content[item], let text = fields["text"]?.string,
                           let json = try payload(text) {
                            fields["text"] = .string(json)
                            content[item] = .object(fields)
                        }
                    }
                    object["content"] = .array(content)
                }
                if let structured = object["structuredContent"] {
                    object["structuredContent"] = candidateIdentity(try JSONDecoder().decode(JSONValue.self, from: encoder.encode(structured)))
                }
                rows[index] = .object(object)
            }
        }
        let normalized = value.array == nil ? rows[0] : .array(rows)
        var text = String(decoding: try encoder.encode(normalized), as: UTF8.self)
        text = text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                        with: "<uuid>", options: .regularExpression)
        text = text.replacingOccurrences(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z",
                                        with: "<time>", options: .regularExpression)
        return Data((text + "\n").utf8)
    }

    static func compare(_ value: JSONValue, named name: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/Golden/\(name).json")
        let actual = try normalized(value)
        if ProcessInfo.processInfo.environment["BRAUS_RECORD_TOOL_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url)
        }
        let expected = try Data(contentsOf: url)
        if actual != expected {
            try actual.write(to: FileManager.default.temporaryDirectory.appending(path: "tu3-\(name)-actual.json"))
        }
        #expect(actual == expected, "Golden differs: \(name)")
    }
}

@Suite
@MainActor
struct CandidateIdentityGoldenTests {
    @Test(arguments: ["1", "1e8595fe991593", "0123456789abcdef"])
    func variableWidthSuffixKeepsTheSameGoldenIdentity(_ suffix: String) throws {
        let id = "candidate-00000000-0000-0000-0000-000000000000-" + suffix
        let payload: JSONValue = .object([
            "candidate": .object(["id": .string(id)]),
            "next": .string("Interpret " + id),
            "unchanged": .string("Keep " + suffix)
        ])
        let result = try ToolGolden.normalized(.array([.object(["structuredContent": payload])]))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: result)
        let kept = try #require(decoded.array?.first?["structuredContent"])
        #expect(kept["candidate"]["id"].string == "candidate-<uuid>-<suffix>")
        #expect(kept["next"].string == "Interpret candidate-<uuid>-<suffix>")
        #expect(kept["unchanged"].string == "Keep " + suffix)
    }
}

@Suite
@MainActor
struct InterruptionPolicyLocationTests {
    @Test
    func everyServedNameAndUnknown() {
        let names = AutomationTools.definitions(for: [.native, .web, .adapters]).compactMap { $0["name"].string }
        for name in names + ["unknown"] {
            let policy = AutomationTools.interruptionPolicy(for: name)
            let expected: AutomationTools.InterruptionPolicy
            switch name {
            case "status", "windows", "apps", "observe", "app_capabilities", "human_step": expected = .readOnly
            case "open_session": expected = .openingScene
            default: expected = .mutating
            }
            #expect(policy == expected)
            #expect(policy == ToolCatalogue.interruptionPolicy(for: name))
        }
    }
}
