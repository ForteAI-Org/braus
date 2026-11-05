import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing
@testable import Turn

/// Real runner, authenticated loopback socket, MCP router/parser, batch executor and SQLite.
/// Two independent application implementations replace OS effects; no ActionEngine or Driver claim.
@MainActor
@Suite(.serialized)
struct RowLifecycleIntegrationTests {
    enum Case: String, CaseIterable, Sendable {
        case documentPassed, documentFailed, documentRevised, controlsPassed, controlsFailed, controlsNoExpectation
        var document: Bool { rawValue.hasPrefix("document") }
        var verdict: String {
            switch self {
            case .documentPassed, .controlsPassed: "passed"
            case .documentFailed, .controlsFailed: "failed"
            case .documentRevised, .controlsNoExpectation: "unknown"
            }
        }
    }

    @Test(arguments: Case.allCases)
    func twoRowsKeepBoundaryVerdictsAndAssociationsAfterReopening(_ scenario: Case) async throws {
        let root = try testTurnRoot()
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let directory = root.appending(path: "archive")
        let first = root.appending(path: "first.txt"), final = root.appending(path: "final.txt")
        let document = RowCycleApplications.Document(directory: directory, first: first, final: final,
            succeeds: scenario != .documentFailed)
        let controls = RowCycleApplications.Controls(directory: directory, final: final,
            succeeds: scenario != .controlsFailed)
        let session: any AutomationSessionOperating = scenario.document ? document : controls
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        defer { withExtendedLifetime(host) {} }
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: work,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false, closesSessionOnEnd: false), host: host)
        var memory = MemoryService.shared(for: directory)
        do {
            let source = URL(filePath: #filePath).deletingLastPathComponent()
            let provider = root.appending(path: "provider.py")
            try FileManager.default.copyItem(at: source.appending(path: "Fixtures/recovery-provider.py"), to: provider)
            try FileManager.default.copyItem(at: source.deletingLastPathComponent().appending(path: "Chat/Fixtures/claude-turn1.jsonl"),
                to: root.appending(path: "reply.jsonl"))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: provider.path)
            func call(_ name: String, _ args: [String: JSONValue]) -> JSONValue {
                .object(["method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(args)])])
            }
            let global: JSONValue = .object(["file": .string(final.path), "contains": .string("FINAL")])
            var firstRow: [String: JSONValue] = ["title": .string("Prepare the result")]
            if scenario.document {
                firstRow["expect"] = scenario == .documentRevised ? .object(["file_written": .string(first.path)])
                    : .object(["file": .string(first.path), "contains": .string("FIRST")])
            } else if scenario != .controlsNoExpectation {
                firstRow["expect"] = .object(["element": .string("Power"), "state": .string("on")])
            }
            let secondCheck: JSONValue = scenario.document ? global : .object(["element": .string("Mode"), "value": .string("Safe")])
            let secondRow: JSONValue = .object(["title": .string("Publish the result"), "expect": secondCheck])
            var commands: [JSONValue] = [.object(["method": .string("initialize"), "params": .object([:])]),
                .object(["method": .string("tools/list"), "params": .object([:])])]
            commands.append(call("plan", ["request": .string("Prepare and publish a public result"),
                "inputs": .array([first, final].enumerated().map { index, value in
                    .object(["name": .string("output_\(index)"), "kind": .string("file"), "value": .string(value.path)]) }),
                "rows": .array([.object(firstRow), secondRow])]))
            commands.append(call("batch", ["step": .string("r1"), "steps": .array([
                .object(["operation": .string("act"), "target": .string(scenario.document ? "Write" : "Enable")])])]))
            if scenario == .documentRevised {
                commands.append(call("plan", ["rows": .array([
                    .object(["id": .string("r1"), "title": .string("Prepare the result"),
                        "expect": .object(["file_changed": .string(first.path)])]),
                    .object(["id": .string("r2"), "title": .string("Publish the result"), "expect": secondCheck])])]))
            }
            let boundaryIndex = commands.count
            commands.append(call("act", ["target": .string(scenario.document ? "Publish" : "Apply"), "step": .string("r2")]))
            if !scenario.document {
                commands.append(call("batch", ["step": .string("r2"), "steps": .array([
                    .object(["operation": .string("select"), "control": .string("Mode"), "item": .string("Safe")])])]))
            }
            commands.append(call("end", ["outcome": .string("completed"), "result_check": global]))
            try JSONValue.canonicalEncoder().encode(JSONValue.array(commands)).write(to: root.appending(path: "commands.json"))
            _ = try await runner.run(.init(prompt: "Prepare and publish the public result", route: .commandLine(provider: .claude,
                executable: provider, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { _ in }
            let answers = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: root.appending(path: "answers.json")))
            func payload(_ index: Int) throws -> JSONValue {
                if let structured = answers[index]["result"]["structuredContent"].object { return .object(structured) }
                let text = try #require(answers[index]["result"]["content"].array?.first?["text"].string)
                return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            }
            let plan = try payload(2), ended = try payload(answers.count - 1)
            let task = try #require(plan["task"].string)
            let boundaryText = answers[boundaryIndex]["result"]["content"].array?.compactMap { $0["text"].string }.joined(separator: "\n") ?? ""
            #expect(boundaryText.contains("r1") && boundaryText.contains(scenario.verdict))
            #expect(ended["completion_evidence"]["checks"].string == "passed")
            #expect(ended["row_check"]["id"].string == "r2" && ended["row_check"]["status"].string == "done")
            #expect(ended["row_check"]["verdict"].string == "passed")
            #expect(ended["unexecuted_rows"].array == [])
            #expect(try String(contentsOf: final, encoding: .utf8) == "FINAL")
            #expect(scenario.document ? document.actions == 2 : controls.actions == 3)
            try await runner.close()
            await memory.close()
            MemoryService.forget(directory)
            memory = MemoryService.shared(for: directory)
            let revisions = try await TaskChannel.todoRevisions(of: task, memory: memory)
            #expect(revisions.contains { $0.change == .rowFinished(.init(rawValue: "r1"), verdict: .init(rawValue: scenario.verdict)) })
            #expect(revisions.last?.change == .rowFinished(.init(rawValue: "r2"), verdict: .passed))
            #expect(revisions.last?.rows.map(\.status) == [.done, .done])
            let calls = try await memory.perform { try await $0.todos.attributedCalls(ofTask: task) }
            #expect(calls.filter { $0.row.rawValue == "r1" }.count == 1)
            #expect(calls.filter { $0.row.rawValue == "r2" }.count == (scenario.document ? 1 : 2))
            #expect(Set(calls.map(\.eventID)).count == calls.count)
            let stored = try await memory.perform { repositories in
                try await repositories.store.read { tx in
                    try tx.query("""
                        SELECT i.row_key,s.check_verdict,s.expectation_revision_id,r.reason_kind
                        FROM memory_todo_items i JOIN memory_tasks t USING(task_id)
                        JOIN memory_todo_item_states s USING(item_id)
                        JOIN memory_todo_revisions r ON r.todo_revision_id=s.expectation_revision_id
                        WHERE t.task_uuid=? AND s.todo_revision_id=(SELECT max(x.todo_revision_id) FROM memory_todo_item_states x WHERE x.item_id=i.item_id)
                        ORDER BY s.position
                        """, [.text(task)]) { [try $0.text(0) ?? "", try $0.text(1) ?? "", String($0.integer(2) ?? 0), try $0.text(3) ?? ""] }
                }
            }
            if scenario != .controlsNoExpectation {
                #expect(stored.first?[1] == scenario.verdict)
                #expect(stored.first?[3] == (scenario == .documentRevised ? "revised" : "drafted"))
            }
            #expect(stored.last?[0] == "r2" && stored.last?[1] == "passed")
            let parentLinks = try await memory.perform { repositories in
                try await repositories.store.read { tx in
                    try tx.query("SELECT count(*) FROM memory_call_steps c JOIN memory_agent_actions a USING(event_id) WHERE a.tool_kind='batch'") { $0.integer(0) }
                }
            }
            #expect(parentLinks == [0])
            print("ROW_LIFECYCLE \(scenario.rawValue) r1=\(scenario.verdict) r2=passed unique_calls=\(calls.count) reopened=true")
            await memory.close()
            MemoryService.forget(directory)
            try FileManager.default.removeItem(at: root)
        } catch {
            try await runner.close()
            await memory.close()
            MemoryService.forget(directory)
            throw error
        }
    }
}

@MainActor
private enum RowCycleApplications {
    static func button(_ id: String) -> SceneElement {
        .init(id: id, kind: .control, label: id, bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1), role: "AXButton")
    }
    @MainActor
    final class Document: AutomationSessionOperating {
        var id: UUID? = UUID()
        let memoryDirectory: URL?
        let memoryApplication: String? = "test.row.document"
        let first: URL, final: URL
        let succeeds: Bool
        var actions = 0
        var scene = SceneSnapshot(bundleID: "test.row.document", appName: "Public document", windowTitle: "Document",
            viewportPixelSize: .init(width: 400, height: 200), elements: [button("Write"), button("Publish")])
        init(directory: URL, first: URL, final: URL, succeeds: Bool) {
            memoryDirectory = directory; self.first = first; self.final = final; self.succeeds = succeeds
        }
        func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
        func observe() async throws -> SceneSnapshot { scene }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            guard target == "Write" || target == "Publish" else { throw AutomationFailure("Unexpected document operation") }
            actions += 1
            if target == "Write" { try Data((succeeds ? "FIRST" : "WRONG").utf8).write(to: first) }
            else { try Data("FINAL".utf8).write(to: final) }
            return ActOutcome(.foundActed, "Public document operation", scene: scene)
        }
        func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected document select") }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("Unexpected document input") }
        func menu(path: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected document menu") }
        func close() async { id = nil }
    }
    @MainActor
    final class Controls: AutomationSessionOperating {
        var id: UUID? = UUID()
        let memoryDirectory: URL?
        let memoryApplication: String? = "test.row.controls"
        let final: URL
        let succeeds: Bool
        var actions = 0
        var scene = SceneSnapshot(bundleID: "test.row.controls", appName: "Public settings", windowTitle: "Settings",
            viewportPixelSize: .init(width: 400, height: 200), elements: [button("Enable"), button("Apply"),
                .init(id: "power", kind: .control, label: "Power", bounds: .init(x: 0.1, y: 0.3, width: 0.2, height: 0.1), role: "AXCheckBox", state: .off),
                .init(id: "mode", kind: .control, label: "Mode", bounds: .init(x: 0.1, y: 0.5, width: 0.2, height: 0.1), role: "AXPopUpButton", value: "Normal")])
        init(directory: URL, final: URL, succeeds: Bool) { memoryDirectory = directory; self.final = final; self.succeeds = succeeds }
        func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
        func observe() async throws -> SceneSnapshot { scene }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            guard target == "Enable" || target == "Apply" else { throw AutomationFailure("Unexpected settings operation") }
            actions += 1
            if target == "Enable" { scene.elements[2].state = succeeds ? .on : .off }
            return ActOutcome(.foundActed, "Public settings operation", scene: scene)
        }
        func select(control: String, item: String) async throws -> ActOutcome {
            guard control == "Mode", item == "Safe" else { throw AutomationFailure("Unexpected settings selection") }
            actions += 1
            scene.elements[3].value = item
            try Data("FINAL".utf8).write(to: final)
            return ActOutcome(.foundActed, "Public selection", scene: scene)
        }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("Unexpected settings input") }
        func menu(path: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected settings menu") }
        func close() async { id = nil }
    }
}
