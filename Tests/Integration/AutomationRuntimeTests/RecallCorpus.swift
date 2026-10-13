//
//  RecallCorpus.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import CryptoKit
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory

/// RecallCorpus is the Recall's versioned quality corpus (`Fixtures/recall-corpus-v1.json`) and its builder. The
/// knowledge is learned through the product's tools over the session double, as an agent's tasks are: begin, the
/// operations, end, the interpretation, each admitted by D2's qualification. The changes that follow it are applied
/// as the system applies them: a reinterpretation through the tool, a retired part through the procedures'
/// repository, which no tool exposes. The queries carry expectations written apart from any run, split by task
/// family into development and final, so no family of the final split was seen while calibrating.
@MainActor
struct RecallCorpus {

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Learned is one knowledge item as the archive holds it: its candidate and the versions built from it, the
    /// first interpretation first.
    nonisolated struct Learned: Sendable {
        let id: String
        let family: String
        let candidateID: String
        var revisions: [String]

        var current: String { revisions.last ?? "" }

        /// The version a corpus reference names: `id` is the current one, `id@N` the N-th.
        static func route(_ reference: String, in learned: [String: Learned]) -> String? {
            let parts = reference.split(separator: "@").map(String.init)
            guard let known = learned[parts[0]] else { return nil }
            guard parts.count == 2, let number = Int(parts[1]), known.revisions.indices.contains(number - 1) else { return known.current }
            return known.revisions[number - 1]
        }
    }

    let json: JSONValue
    let digest: String

    /// A corpus among the test resources by name, or a file outside them by its absolute path (a holdout written after the
    /// code was frozen).
    static func load(_ name: String = "recall-corpus-v1") throws -> RecallCorpus {
        let url: URL
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name)
        } else {
            guard let resource = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw Failure("the corpus \(name) is not among the test resources")
            }
            url = resource
        }
        let data = try Data(contentsOf: url)
        return RecallCorpus(json: try JSONDecoder().decode(JSONValue.self, from: data), digest: Self.sha256(data))
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var version: String { json["version"].string ?? "" }
    var knowledge: [JSONValue] { json["knowledge"].array ?? [] }

    /// The queries of a split (`dev`, `final`), or all of them.
    func queries(split: String) -> [JSONValue] {
        (json["queries"].array ?? []).filter { split == "all" || $0["split"].string == split }
    }

    // MARK: Windows

    /// A window of the corpus as the session double shows it.
    func window(_ bundle: String, _ name: String) throws -> LearningSession.Window {
        let spec = json["apps"][bundle]["windows"][name]
        guard let elements = spec["elements"].array else { throw Failure("no window \(name) of \(bundle)") }
        let surface: CaptureSurface = switch spec["surface"].string {
            case "dialog": .dialog
            case "sheet" : .sheet
            default      : .window
        }
        return LearningSession.Window(elements: elements.enumerated().map { Self.element($1, at: $0) }, surface: surface,
                                      title: spec["title"].string ?? name)
    }

    static func element(_ spec: JSONValue, at index: Int) -> SceneElement {
        let label = spec["label"].string ?? ""
        let bounds = NormalizedRect(x: 0.05 + Double(index % 3) * 0.3, y: 0.05 + Double(index) * 0.07, width: 0.2, height: 0.04)
        let container = spec["container"].string
        switch spec["kind"].string {
            case "textfield":
                return SceneElement(id: "field|\(index)", kind: .control, label: label, bounds: bounds, role: "AXTextField",
                                    container: container, labelOrigin: LabelOrigin(rawValue: spec["origin"].string ?? "") ?? .title)
            case "row":
                return SceneElement(id: "row|\(label)", kind: .control, label: label, bounds: bounds, role: "AXRow",
                                    labelOrigin: .rowContent, collectionPath: spec["list"].string)
            case "checkbox":
                return SceneElement(id: "check|\(label.lowercased())", kind: .control, label: label, bounds: bounds, role: "AXCheckBox",
                                    state: spec["state"].string == "on" ? .on : .off, labelOrigin: .title)
            case "popup":
                return SceneElement(id: "popup|\(label.lowercased())", kind: .control, label: label, bounds: bounds, role: "AXPopUpButton",
                                    value: spec["value"].string, labelOrigin: .title)
            case "link":
                return SceneElement(id: "link|\(label.lowercased())", kind: .control, label: label, bounds: bounds, role: "AXLink",
                                    labelOrigin: .title)
            case "text":
                return SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label, bounds: bounds, role: "AXStaticText")
            default:
                return SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label, bounds: bounds, role: "AXButton",
                                    container: container, labelOrigin: .title)
        }
    }

    /// The double's script key of an operation: what it acts on, as `LearningSession` names it.
    static func scriptKey(_ tool: String, _ arguments: [String: JSONValue]) -> String {
        switch tool {
            case "select"   : "select|\(arguments["control"]?.string ?? "")"
            case "menu"     : "menu|\(arguments["path"]?.string ?? "")"
            case "press"    : "press|\(arguments["button"]?.string ?? "")"
            case "press_key": "press_key|\(arguments["key"]?.string ?? "")"
            default         : "\(tool)|\(arguments["target"]?.string ?? "")"
        }
    }

    // MARK: Learning

    /// Learns every knowledge item into the archive of `directory`, in the corpus's order.
    func learn(into directory: URL) async throws -> [String: Learned] {
        var learned: [String: Learned] = [:]
        for item in knowledge {
            let one = try await learn(item, into: directory)
            learned[one.id] = one
        }
        return learned
    }

    /// One task through the tools: begin without a search, the operations, the declared end, the interpretation.
    func learn(_ item: JSONValue, into directory: URL) async throws -> Learned {
        let id = item["id"].string ?? ""
        let session = LearningSession(directory: directory)
        let tools = ProcedureLearningTests.tools(session, stream: "corpus-\(id)")
        var begin: [String: JSONValue] = ["operation": .string("begin"), "goal": item["goal"], "recall": .bool(false)]
        if item["inputs"] != .null { begin["inputs"] = item["inputs"] }
        let begun = try await tools.call("memory_task", .object(begin)).payload
        guard begun["status"].string == "begun" else { throw Failure("\(id): begin answered \(begun)") }
        var application: String?
        for operation in item["run"].array ?? [] {
            if let bundle = operation["open"].string {
                session.windows[bundle] = try window(bundle, operation["window"].string ?? "")
                application = bundle
                _ = try await tools.call("open_session", .object(["app": .string(bundle)]))
                continue
            }
            guard let tool = operation["op"].string, var arguments = operation["args"].object, let application else {
                throw Failure("\(id): an operation before any application")
            }
            arguments["session"] = .string(session.id?.uuidString ?? "")
            session.script[Self.scriptKey(tool, arguments)] = try operation["next"].string.map {
                LearningSession.Outcome(next: try window(application, $0))
            }
            _ = try await tools.call(tool, .object(arguments))
        }
        let ended = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": item["end"]])).payload
        guard let candidate = ended["candidate"]["id"].string else { throw Failure("\(id): no candidate at the end: \(ended)") }
        var interpretation = item["interpretation"].object ?? [:]
        interpretation["operation"] = .string("interpret")
        interpretation["candidate"] = .string(candidate)
        // `{task}` in a source_ref is the learning task's own id: a reference to an output of the same task.
        if let task = begun["task"].string {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let text = String(decoding: try encoder.encode(JSONValue.object(interpretation)), as: UTF8.self)
                .replacingOccurrences(of: "{task}/", with: "\(task)/")
            interpretation = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).object ?? interpretation
        }
        let interpreted = try await tools.call("memory_task", .object(interpretation)).payload
        guard interpreted["status"].string == "interpreted",
              interpreted["parts"].array?.allSatisfy({ $0["admitted"].bool == true }) == true else {
            throw Failure("\(id): the interpretation is not wholly admitted: \(interpreted)")
        }
        return Learned(id: id, family: item["family"].string ?? "", candidateID: candidate,
                       revisions: [ProcedureAssembly.routeID(candidateID: candidate, revision: 1)])
    }

    /// Applies the changes that follow the learning, in the corpus's order: a reinterpretation through the tool, a
    /// part retired through the procedures' repository.
    func applyChanges(to learned: inout [String: Learned], in directory: URL) async throws {
        let memory = MemoryService.shared(for: directory)
        for item in knowledge {
            guard let id = item["id"].string, let changes = item["after"].array, var known = learned[id] else { continue }
            for change in changes {
                if var reinterpretation = change["reinterpret"].object {
                    let tools = ProcedureLearningTests.tools(LearningSession(directory: directory), stream: "corpus-\(id)")
                    reinterpretation["operation"] = .string("interpret")
                    reinterpretation["candidate"] = .string(known.candidateID)
                    let answer = try await tools.call("memory_task", .object(reinterpretation)).payload
                    guard answer["status"].string == "interpreted" else { throw Failure("\(id): the reinterpretation answered \(answer)") }
                    known.revisions.append(ProcedureAssembly.routeID(candidateID: known.candidateID, revision: known.revisions.count + 1))
                } else if change["state"] != .null, case .number(let step) = change["state"]["step"] {
                    let part = "\(known.current)/step-\(Int(step) - 1)"
                    let reason = change["state"]["reason"].string ?? "retired by the corpus"
                    let at = memory.clock.calendarMS()
                    _ = try await memory.perform { try await $0.procedures.setState(.retired, of: part, reason: reason, by: "recall-corpus", at: at) }
                }
            }
            learned[id] = known
        }
        await RecallService.shared(for: memory).schedule()
    }

    // MARK: Queries

    /// The task values a query declares, as `memory_task` would record them.
    nonisolated static func values(_ query: JSONValue) throws -> [TaskValue] {
        try (query["inputs"].array ?? []).map { input in
            try TaskValue(name: input["name"].string ?? "", role: input["role"].string,
                          kind: TaskValueKind(rawValue: input["kind"].string ?? "text") ?? .text,
                          content: .text(input["value"].string ?? ""),
                          source: TaskValueSource(rawValue: input["source"].string ?? "request") ?? .request, sourceRef: input["source_ref"].string)
        }
    }

    /// The query's request as the Recall receives it from `memory_task begin`.
    nonisolated static func request(_ query: JSONValue) throws -> RecallRequest {
        let id = query["id"].string ?? "query"
        return try RecallRequest(taskID: "eval-\(id)", attemptID: "eval-\(id)", revision: 1, reason: .initial,
                                 remainingWork: query["remaining"].string ?? "",
                                 needs: try (query["needs"].array ?? []).map { try RecallNeed(text: $0["text"].string ?? "", bundleID: $0["app"].string) },
                                 values: try values(query), constraints: (query["constraints"].array ?? []).compactMap(\.string))
    }

    /// The query as an agent states it to `memory_task begin`.
    static func begin(_ query: JSONValue) -> JSONValue {
        var begin: [String: JSONValue] = ["operation": .string("begin"), "goal": query["remaining"], "remaining": query["remaining"]]
        if query["inputs"] != .null { begin["inputs"] = query["inputs"] }
        if query["constraints"] != .null { begin["constraints"] = query["constraints"] }
        if let needs = query["needs"].array {
            begin["needs"] = .array(needs.map { need in .object(["text": need["text"]].merging(need["app"] == .null ? [:] : ["app": need["app"]]) { a, _ in a }) })
        }
        return .object(begin)
    }

    /// The corpus restricted to the knowledge named: the minimal archive a bootstrap query is also judged on.
    func restricted(to knowledge: Set<String>) -> RecallCorpus {
        guard case .object(var root) = json else { return self }
        root["knowledge"] = .array(self.knowledge.filter { knowledge.contains($0["id"].string ?? "") })
        return RecallCorpus(json: .object(root), digest: digest)
    }
}
