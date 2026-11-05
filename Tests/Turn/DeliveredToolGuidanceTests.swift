import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import Memory
import Testing
@testable import Turn

@MainActor
struct DeliveredToolGuidanceTests {
    @Test(arguments: ["valid", "replay", "observe"])
    func codexInvocationDeliversGuidanceAndRunsRealContracts(_ mode: String) async throws {
        let replayErrors = mode == "replay", observeOnly = mode == "observe"
        let root = try testTurnRoot()
        let directory = root.appending(path: "archive"), output = root.appending(path: "public-output.txt")
        let session = RecoveryApplication(directory: directory, output: output, opened: false)
        let profile: SessionProfile? = observeOnly
            ? .init(attendance: .client, level: .observe, memory: .read, catalogue: .open,
                takeover: false, options: .init(), name: "client") : nil
        let tools = AutomationTools(session: session, profile: profile)
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/recovery-provider.py")
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: source, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try Data("""
        {"type":"thread.started","thread_id":"offline-delivery"}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8).write(to: root.appending(path: "reply.jsonl"))
        func call(_ name: String, _ fields: [String: JSONValue], error: Bool = false) -> JSONValue {
            .object(["method": .string("tools/call"), "params": .object(["name": .string(name),
                "arguments": .object(fields)]), "isError": .bool(error)])
        }
        var commands: [JSONValue] = [
            .object(["method": .string("initialize"), "params": .object([:])]),
            .object(["method": .string("tools/list"), "params": .object([:])])]
        if replayErrors {
            commands += [call("observe", [:], error: true),
                call("find", ["query": .string("Public capability"), "limit": .number(20)], error: true)]
        }
        commands.append(call("open_session", ["app": .string("Synthetic")]))
        if observeOnly {
            commands.append(call("observe", [:]))
        } else {
            let check: JSONValue = .object(["file_written": .string(output.path)])
            let resultRow: JSONValue = .object(["title": .string("Write public output"), "expect": check])
            let rows: [JSONValue] = replayErrors
                ? [.object(["title": .string("Prepare app")]), resultRow] : [resultRow]
            commands.append(call("plan", ["request": .string("Write public output"), "rows": .array(rows)]))
            let step = replayErrors ? "r2" : "r1"
            let batch: [String: JSONValue] = ["step": .string(step), "steps": .array([
                .object(["operation": .string("act"), "target": .string("Write public file")])])]
            if replayErrors {
                commands.append(call("batch", ["steps": .array([.object(["target": .string("Write public file")])])], error: true))
                commands.append(call("batch", batch, error: true))
                let revised: JSONValue = .object(["id": .string("r2"), "title": .string("Write public output"), "expect": check])
                commands.append(call("plan", ["rows": .array([revised])], error: true))
                commands.append(call("plan", ["rows": .array([revised]), "reason": .string("App is prepared")]))
            }
            commands.append(call("batch", batch))
            commands.append(call("end", ["outcome": .string("completed"), "result_check": check]))
        }
        try JSONValue.canonicalEncoder().encode(JSONValue.array(commands)).write(to: root.appending(path: "commands.json"))
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false,
            closesSessionOnEnd: false), host: host)
        _ = try await runner.run(.init(prompt: "Write public output", route: .commandLine(provider: .codex,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { _ in }
        let delivery = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "delivered.json")))
        #expect(delivery["provider"].string == "codex")
        let prompt = try #require(delivery["instructions"].string)
        #expect(prompt.contains("Initial tools:"))
        #expect(prompt.contains("Call these directly"))
        #expect(prompt.contains("step is an argument, not a tool") == !observeOnly)
        if observeOnly {
            #expect(!prompt.contains("`plan`") && !prompt.contains("`end`"))
        }
        #expect(prompt.contains("before observe"))
        let replies = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: root.appending(path: "answers.json")))
        let served = try #require(replies[1]["result"]["tools"].array)
        #expect(served == tools.toolDefinitions)
        let inventory = try #require(prompt.split(separator: "\n").first { $0.hasPrefix("Initial tools: ") })
        let listed = String(inventory).replacingOccurrences(of: "Initial tools: ", with: "")
            .replacingOccurrences(of: ". Call these directly.", with: "").components(separatedBy: ", ")
        #expect(listed == served.compactMap { $0["name"].string })
        let bytes = prompt.utf8.count + (try JSONValue.canonicalEncoder().encode(JSONValue.array(served))).count
        #expect(bytes <= 15_360)
        #expect(served.first { $0["name"].string == "find" }?["description"].string?.contains("3-5") == true)
        if !observeOnly {
            #expect(served.first { $0["name"].string == "batch" }?["description"].string?.contains("requires operation") == true)
        }
        if replayErrors {
            let text = try #require(replies[2]["result"]["content"].array?.first?["text"].string)
            #expect(text.contains("not_dispatched") && !text.contains("Effects may be partial"))
        }
        #expect(session.actions == (observeOnly ? 0 : 1) && tools.openTask == nil)
        if observeOnly { #expect(!FileManager.default.fileExists(atPath: output.path)) }
        else { #expect(try String(contentsOf: output, encoding: .utf8) == "PUBLIC_OUTPUT") }
        print("DELIVERED_GUIDANCE provider=codex fake_child=true mode=\(mode) actions=\(session.actions) bytes=\(bytes)")
        try await runner.close()
        let memory = MemoryService.shared(for: directory)
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: root)
    }
}
