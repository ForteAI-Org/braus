@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// Exercises the real MCP schema, task handler and SQLite writer; only the application is simulated.
@MainActor
@Suite(.serialized)
struct EndRowFactsTests {
    @Test(arguments: ["failed", "unknown"])
    func activeRowVerdictIsDeliveredSeparatelyFromThePassingTaskCheck(_ verdict: String) async throws {
        let f = try EndRowFactsFixture()
        do {
            let plan = try f.payload(await f.call("plan", ["request": .string("Prepare and inspect"), "rows": .array([
                .object(["title": .string("Prepare"), "expect": .object(["element": .string("Readout"), "value": .string("wanted")])]),
                .object(["title": .string("Inspect later")])])]))
            let task = try #require(plan["task"].string)
            _ = try await f.call("act", ["target": .string("Run"), "step": .string("r1")])
            if verdict == "unknown" { f.session.observationFailure = AutomationFailure("Synthetic unreadable scene") }
            try Data("PUBLIC_RESULT".utf8).write(to: f.output)
            let answer = try await f.call("end", ["outcome": .string("completed"),
                "result_check": .object(["file": .string(f.output.path), "contains": .string("PUBLIC_RESULT")])])
            #expect(answer["isError"].bool != true)
            let ended = try f.payload(answer)
            #expect(ended["outcome"].string == "completed")
            #expect(ended["completion_evidence"]["checks"].string == "passed")
            #expect(ended["row_check"]["id"].string == "r1")
            #expect(ended["row_check"]["status"].string == "done")
            #expect(ended["row_check"]["verdict"].string == verdict)
            #expect(ended["unexecuted_rows"].array == [.string("r2")])
            let revisions = try await TaskChannel.todoRevisions(of: task, memory: f.memory)
            #expect(revisions.last?.change == .rowFinished(.init(rawValue: "r1"), verdict: .init(rawValue: verdict)))
            #expect(revisions.last?.rows.map(\.status) == [.done, .abandoned])
            let saved = try await f.memory.perform { repositories in
                try await repositories.store.read { tx in
                    try tx.query("""
                        SELECT s.check_verdict FROM memory_todo_item_states s
                        JOIN memory_todo_items i USING(item_id) JOIN memory_tasks t USING(task_id)
                        WHERE t.task_uuid=? AND i.row_key='r1' ORDER BY s.todo_revision_id DESC LIMIT 1
                        """, [.text(task)]) { try $0.text(0) }
                }
            }
            #expect(saved == [verdict])
            #expect(f.transcript.last?.contains("row_check") == true)
            #expect(f.transcript.last?.contains(verdict) == true)
            try await f.close()
        } catch { try await f.close(); throw error }
    }

    @Test(arguments: ["completed", "failed", "abandoned"])
    func terminalOutcomesKeepTheirActualRowStatusWithoutExtraReads(_ outcome: String) async throws {
        let f = try EndRowFactsFixture()
        do {
            let task = try await f.prepareActiveRow()
            let beforeReads = f.session.calls.filter { $0 == "observe" }.count
            let ended = try f.payload(await f.call("end", ["outcome": .string(outcome)]))
            let status = outcome == "completed" ? "done" : "abandoned"
            #expect(ended["outcome"].string == outcome)
            #expect(ended["row_check"]["id"].string == "r1")
            #expect(ended["row_check"]["status"].string == status)
            #expect(ended["row_check"]["verdict"].string == "unknown")
            #expect(ended["unexecuted_rows"].array == [.string("r2")])
            #expect(f.session.calls.filter { $0 == "observe" }.count == beforeReads)
            let todo = try await TaskChannel.todo(of: task, memory: f.memory)
            #expect(todo?.rows.map { $0.status.rawValue } == [status, "abandoned"])
            #expect(f.tools.openTask == nil)
            try await f.close()
        } catch { try await f.close(); throw error }
    }

    @Test func noActiveRowReturnsNoInventedCheckAndNamesOnlyCurrentPendingRows() async throws {
        let f = try EndRowFactsFixture()
        do {
            let plan = try f.payload(await f.call("plan", ["request": .string("Read later"), "rows": .array([
                .object(["title": .string("First")]), .object(["title": .string("Second")])])]))
            let task = try #require(plan["task"].string)
            let ended = try f.payload(await f.call("end", ["outcome": .string("completed")]))
            #expect(ended["row_check"] == .null)
            #expect(ended["unexecuted_rows"].array == [.string("r1"), .string("r2")])
            #expect(f.session.calls.isEmpty)
            #expect(try await TaskChannel.todo(of: task, memory: f.memory)?.rows.map(\.status) == [.abandoned, .abandoned])
            try await f.close()
        } catch { try await f.close(); throw error }
    }

    @Test func anExplicitStopDoesNotPublishSuccessfulEndFacts() async throws {
        let f = try EndRowFactsFixture()
        do {
            let task = try await f.prepareActiveRow()
            f.tools.markTaskInterrupted()
            let answer = try await f.call("end", ["outcome": .string("completed")])
            #expect(answer["isError"].bool == true)
            let failure = try f.payload(answer)
            #expect(failure["error"].string == "task_interrupted")
            #expect(failure["row_check"] == .null && failure["unexecuted_rows"] == .null)
            #expect(f.tools.openTask?.taskID == task)
            _ = try await f.tools.closeStoppedTask(.person)
            try await f.close()
        } catch { try await f.close(); throw error }
    }

    @Test func checkpointFailureRollsBackAndReportsNoUncommittedRowFacts() async throws {
        let f = try EndRowFactsFixture()
        do {
            let task = try await f.prepareActiveRow()
            let before = try await TaskChannel.todoRevisions(of: task, memory: f.memory)
            try await f.memory.perform { repositories in
                try await repositories.store.write { tx in
                    try tx.execute("CREATE TRIGGER refuse_end_check BEFORE INSERT ON memory_task_end_checks BEGIN SELECT RAISE(ABORT, 'synthetic checkpoint refusal'); END")
                }
            }
            let answer = try await f.call("end", ["outcome": .string("completed")])
            #expect(answer["isError"].bool == true)
            let failure = try f.payload(answer)
            #expect(failure["row_check"] == .null && failure["unexecuted_rows"] == .null)
            #expect(f.tools.openTask?.taskID == task)
            #expect(try await TaskChannel.todoRevisions(of: task, memory: f.memory) == before)
            try await f.memory.perform { repositories in
                try await repositories.store.write { try $0.execute("DROP TRIGGER refuse_end_check") }
            }
            let ended = try f.payload(await f.call("end", ["outcome": .string("completed")]))
            #expect(ended["row_check"]["id"].string == "r1")
            let calls = try await f.memory.perform { try await $0.todos.attributedCalls(ofTask: task) }
            #expect(calls.count == 1)
            try await f.close()
        } catch { try await f.close(); throw error }
    }

    @Test func cancellationBeforeCheckpointPreservesTaskAndItsCancellationCause() async throws {
        let f = try EndRowFactsFixture()
        let secrets = ProducerSecrets()
        let scenes = SceneTextPolicy()
        let formatter = ResultFormatter(session: f.session, secrets: secrets, sceneText: scenes)
        let handler = TaskCycleHandler(session: f.session, secrets: secrets, formatter: formatter)
        do {
            _ = try await handler.plan(PlanRequest(.object(["request": .string("Inspect"), "rows": .array([
                .object(["title": .string("Inspect")])])]), minimization: .init(), messageRef: nil))
            let task = try #require(handler.openTask)
            let ending = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await handler.end(EndRequest(.object(["outcome": .string("completed")]), minimization: .init()))
            }
            do {
                _ = try await ending.value
                Issue.record("Cancelled end unexpectedly returned closure facts")
            } catch is CancellationError {
                // A storage-independent cancellation remains a cancellation.
            } catch let failure as MemoryStoreError {
                guard case .cancelled(.begin) = failure else { throw failure }
            }
            #expect(handler.openTask == task)
            #expect(try await TaskChannel.todo(of: task.taskID, memory: f.memory)?.rows.first?.status == .pending)
            try await f.close()
        } catch { try await f.close(); throw error }
        withExtendedLifetime((secrets, scenes, formatter)) {}
    }
}

@MainActor
private final class EndRowFactsFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "end-row-facts-\(UUID())")
    var output: URL { root.appending(path: "public-result.txt") }
    let session = ToolResultSession()
    var sequence = 0
    var transcript: [String] = []
    private var closed = false
    private var toolsInitialized = false
    var memory: MemoryService { MemoryService.shared(for: root) }
    lazy var tools: AutomationTools = {
        toolsInitialized = true
        let tools = AutomationTools(session: session)
        tools.record = { [unowned self] in transcript.append($0) }
        return tools
    }()
    lazy var router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session.memoryDirectory = root
        session.memoryApplication = "test.end.facts"
        session.scene = SceneSnapshot(bundleID: "test.end.facts", appName: "Public fixture", windowTitle: "Public",
            viewportPixelSize: .init(width: 400, height: 200), elements: [
                .init(id: "run", kind: .control, label: "Run", bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), role: "AXButton"),
                .init(id: "value", kind: .control, label: "Readout", bounds: .init(x: 0.3, y: 0.1, width: 0.1, height: 0.1), role: "AXTextField", value: "wrong")])
    }
    func prepareActiveRow() async throws -> String {
        let plan = try payload(await call("plan", ["request": .string("Prepare"), "rows": .array([
            .object(["title": .string("Prepare")]), .object(["title": .string("Later")])])]))
        _ = try await call("act", ["target": .string("Run"), "step": .string("r1")])
        return try #require(plan["task"].string)
    }
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        sequence += 1
        let answer = try #require(await router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
            "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])))
        #expect(answer["error"] == .null)
        return answer["result"]
    }
    func payload(_ answer: JSONValue) throws -> JSONValue {
        let text = try #require(answer["content"].array?.first?["text"].string)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
    func close() async throws {
        guard !closed else { return }
        closed = true
        if toolsInitialized { tools.record = nil }
        await session.close()
        await memory.close()
        MemoryService.forget(root)
        try FileManager.default.removeItem(at: root)
    }
}
