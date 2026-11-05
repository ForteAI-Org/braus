import AutomationMCP
import AutomationRuntime
import ChatCore
import CryptoKit
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing
@testable import Turn

@MainActor
struct ToolRecoveryIntegrationTests {
    @Test func smokeRejectionsRecoverThroughRealRunnerRouterParserAndArchive() async throws {
        let root = try testTurnRoot()
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let output = root.appending(path: "public-output.txt")
        let directory = root.appending(path: "archive")
        let session = RecoveryApplication(directory: directory, output: output)
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: work,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false, closesSessionOnEnd: false), host: host)
        let source = URL(filePath: #filePath).deletingLastPathComponent()
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: source.appending(path: "Fixtures/recovery-provider.py"), to: script)
        try FileManager.default.copyItem(at: source.deletingLastPathComponent().appending(path: "Chat/Fixtures/claude-turn1.jsonl"),
            to: root.appending(path: "reply.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        func call(_ name: String, _ args: JSONValue, error: Bool = false) -> JSONValue {
            .object(["method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": args]), "isError": .bool(error)])
        }
        let invalid: [JSONValue] = [.string("Il display mostra 89."), .object(["display": .string("89")]),
            .object(["type": .string("element"), "text": .string("89")]), .object(["kind": .string("element"), "text": .string("89")])]
        var commands: [JSONValue] = [.object(["method": .string("initialize"), "params": .object([:])]),
            .object(["method": .string("tools/list"), "params": .object([:])])]
        for check in invalid {
            commands.append(call("plan", .object(["request": .string("Write a public output"),
                "rows": .array([.object(["title": .string("Write"), "expect": check])])]), error: true))
        }
        let check: JSONValue = .object(["file_written": .string(output.path)])
        commands.append(call("plan", .object(["request": .string("Write a public output"),
            "rows": .array([.object(["title": .string("Write"), "expect": check])])])))
        commands.append(call("act", .object(["target": .string("Write public file"), "verb": .string("set_toggle")]), error: true))
        commands.append(call("call", .object(["name": .string("drag"), "arguments": .object([
            "from": .string("Write public file"), "to": .string("Other"), "dx": .number(1), "dy": .number(1)])]), error: true))
        let batch: JSONValue = .object(["step": .string("r1"), "steps": .array([
            .object(["operation": .string("act"), "target": .string("Write public file")])])])
        commands.append(call("batch", batch))
        commands.append(call("end", .object(["outcome": .string("completed"), "result_check": .object(["none": .bool(true)])]), error: true))
        commands.append(call("end", .object(["outcome": .string("completed"), "result_check": check])))
        try JSONValue.canonicalEncoder().encode(JSONValue.array(commands)).write(to: root.appending(path: "commands.json"))
        _ = try await runner.run(.init(prompt: "Write the public output", route: .commandLine(provider: .claude,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { _ in }
        let replies = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: root.appending(path: "answers.json")))
        let served = try #require(replies[1]["result"]["tools"].array)
        #expect(served == tools.toolDefinitions)
        #expect(served.contains { $0["inputSchema"]["$defs"].object?.isEmpty == false })
        let schemaBytes = try JSONValue.canonicalEncoder().encode(JSONValue.array(served))
        print("INTEGRATION_TOOLS_JSON " + String(decoding: schemaBytes, as: UTF8.self))
        print("INTEGRATION_SCHEMA_SHA256 " + SHA256.hash(data: schemaBytes).map { String(format: "%02x", $0) }.joined())
        func payload(_ index: Int) throws -> JSONValue {
            let text = try #require(replies[index]["result"]["content"].array?.first?["text"].string)
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        let taskID = try #require(try payload(6)["task"].string)
        let attemptID = try #require(try payload(6)["attempt"].string)
        #expect(try payload(7)["dispatch"].string == "not_dispatched")
        #expect(try payload(8)["dispatch"].string == "not_dispatched")
        let ended = try payload(11)
        #expect(ended["completion_evidence"]["checks"].string == "passed")
        #expect(ended["result_check"].array?.contains { $0["verdict"].string == "passed" } == true)
        #expect(session.actions == 1)
        #expect(try String(contentsOf: output, encoding: .utf8) == "PUBLIC_OUTPUT")
        #expect(tools.openTask == nil)
        let memory = MemoryService.shared(for: directory)
        let owner = try TaskProducer(source: tools.producer.source, streamID: tools.producer.streamID)
        let stored = try await memory.perform { try await $0.tasks.task(taskID, for: owner) }
        #expect(stored?.status == .completed)
        let todo = try await TaskChannel.todo(of: taskID, memory: memory)
        #expect(todo?.rows.count == 1)
        #expect(todo?.rows.first?.status == .done)
        let calls = try await memory.perform { try await $0.todos.attributedCalls(ofTask: taskID) }
        #expect(!calls.isEmpty)
        let savedChecks = try await memory.perform { repositories in
            try await repositories.store.read { transaction in
                try transaction.query("""
                    SELECT c.verdict FROM memory_task_end_checks c
                    JOIN memory_task_occurrences o ON o.task_occurrence_id = c.task_occurrence_id
                    WHERE o.task_occurrence_uuid = ?
                    """, [.text(attemptID)]) { try $0.text(0) }
            }
        }
        #expect(savedChecks == ["passed"])
        print("INTEGRATION_RECOVERY saved=completed actions=1 invalid_plan=4 invalid_gesture=2 invalid_end=1")
        try await runner.close()
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class RecoveryApplication: AutomationSessionOperating {
    var id: UUID?
    let memoryDirectory: URL?
    let memoryApplication: String? = "test.synthetic"
    let output: URL
    var actions = 0
    var scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Fixture", windowTitle: "Main",
        viewportPixelSize: .init(width: 400, height: 400), elements: [
            .init(id: "write", kind: .control, label: "Write public file", bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), role: "AXButton")])
    init(directory: URL, output: URL, opened: Bool = true) {
        memoryDirectory = directory
        self.output = output
        id = opened ? UUID() : nil
    }
    func open(application: String, window: String?) async throws -> SceneSnapshot { id = UUID(); return scene }
    func observe() async throws -> SceneSnapshot { scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        guard target == "Write public file" else { throw AutomationFailure("Unexpected target") }
        actions += 1
        try Data("PUBLIC_OUTPUT".utf8).write(to: output)
        scene.elements[0].value = "done"
        return ActOutcome(.foundActed, "Synthetic app wrote its public output", scene: scene)
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected select") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("Unexpected input") }
    func menu(path: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected menu") }
    func close() async {}
}
