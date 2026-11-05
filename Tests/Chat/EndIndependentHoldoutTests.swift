@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Private independent end case. Field accessors below are bound mechanically after the author freezes the schema.
@MainActor
struct EndIndependentHoldoutTests {
    @Test
    func failedTaskKeepsActiveUnknownDistinctFromUnexecutedRowsAndPassedFinalCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "end-heldout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = EndHoldoutApplication(root: root)
        let tools = AutomationTools(session: app)
        let transcript = EndHoldoutTranscript()
        tools.record = { transcript.lines.append($0) }
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let memory = MemoryService.shared(for: root)
        var sequence = 0
        var stopped = false
        func stop() async {
            guard !stopped else { return }
            stopped = true
            tools.record = nil
            await app.close()
            await memory.close()
            MemoryService.forget(root)
        }
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            sequence += 1
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
                "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
            let answer = try #require(await router.handle(request))
            #expect(answer["error"] == .null)
            let result = answer["result"]
            #expect(result["isError"].bool != true)
            if name == "open_session" { return result }
            let text = try #require(result["content"].array?.first?["text"].string)
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        // Gesture responses use outcome text, not the task JSON envelope.
        func act() async throws {
            sequence += 1
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
                "method": .string("tools/call"), "params": .object(["name": .string("act"),
                    "arguments": .object(["target": .string("Attempt"), "step": .string("r1")])])])
            let answer = try #require(await router.handle(request))
            #expect(answer["error"] == .null && answer["result"]["isError"].bool != true)
        }
        do {
            _ = try await call("open_session", ["app": .string("Public fixture")])
            let planned = try await call("plan", ["request": .string("Attempt the first phase and leave the second unexecuted"),
                "rows": .array([
                    .object(["title": .string("Attempt the phase without a row assertion")]),
                    .object(["title": .string("Never execute or probe this phase"),
                        "expect": .object(["element": .string("Forbidden probe"), "present": .bool(true)])])])])
            #expect(planned["rows"].array?.count == 2)
            try await act()
            #expect(app.actions == 1 && app.ready)
            let before = try await endHoldoutSQL(memory)
            #expect(before.rows == ["r1|in_progress|unknown", "r2|pending|unknown"])
            let observations = app.observations
            let ended = try await call("end", ["outcome": .string("failed"),
                "result_check": .object(["element": .string("Ready"), "present": .bool(true)])])
            #expect(ended["status"].string == "ended" && ended["outcome"].string == "failed")
            #expect(ended["completion_evidence"]["checks"].string == "passed")
            #expect(endHoldoutActiveFact(ended)["id"].string == "r1")
            #expect(endHoldoutActiveFact(ended)["verdict"].string == "unknown")
            #expect(endHoldoutUnexecuted(ended) == [.string("r2")],
                "Both final states are abandoned, but the active row was executed and must not be called unexecuted")
            #expect(app.observations == observations + 1,
                "Only the existing final element check reads the scene; missing optional expect and pending row require no new proof")
            #expect(app.actions == 1)
            let after = try await endHoldoutSQL(memory)
            #expect(after.rows == ["r1|abandoned|unknown", "r2|abandoned|unknown"])
            #expect(after.taskStatuses == ["failed"])
            #expect(after.todoRevisions == before.todoRevisions + 1)
            #expect(after.taskRevisions == before.taskRevisions && after.actCalls == before.actCalls)
            let line = try #require(transcript.lines.last { $0.hasPrefix("← end ") })
            let logged = try JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst("← end ".count).utf8))
            #expect(endHoldoutActiveFact(logged) == endHoldoutActiveFact(ended))
            #expect(endHoldoutUnexecuted(logged) == endHoldoutUnexecuted(ended))
            #expect(logged["outcome"].string == "failed")
            await stop()
        } catch {
            await stop()
            throw error
        }
    }
}

// API spelling is a mechanical post-freeze binding; the fixed oracle is active r1/unknown and only pending r2.
private func endHoldoutActiveFact(_ answer: JSONValue) -> JSONValue { answer["row_check"] }
private func endHoldoutUnexecuted(_ answer: JSONValue) -> [JSONValue]? { answer["unexecuted_rows"].array }

private struct EndHoldoutSnapshot: Sendable {
    let rows: [String]
    let taskStatuses: [String]
    let todoRevisions: Int64
    let taskRevisions: Int64
    let actCalls: Int64
}

@MainActor
private func endHoldoutSQL(_ memory: MemoryService) async throws -> EndHoldoutSnapshot {
    try await memory.perform { repositories in
        try await repositories.store.read { tx in
            let rows = try tx.query("""
                SELECT i.row_key || '|' || s.status || '|' || coalesce(s.check_verdict,'unknown')
                FROM memory_todo_items i JOIN memory_todo_item_states s USING(item_id)
                WHERE s.todo_revision_id=(SELECT max(s2.todo_revision_id) FROM memory_todo_item_states s2 WHERE s2.item_id=i.item_id)
                ORDER BY i.row_key
                """) { try $0.text(0) ?? "missing" }
            let states = try tx.query("SELECT status FROM memory_tasks ORDER BY task_id") { try $0.text(0) ?? "missing" }
            func count(_ table: String, where condition: String = "") throws -> Int64 {
                try tx.query("SELECT count(*) FROM \(table)" + condition) { $0.integer(0) ?? -1 }.first ?? -1
            }
            return EndHoldoutSnapshot(rows: rows, taskStatuses: states,
                todoRevisions: try count("memory_todo_revisions"), taskRevisions: try count("memory_task_revisions"),
                actCalls: try count("memory_agent_actions", where: " WHERE tool_kind='act'"))
        }
    }
}

@MainActor
private final class EndHoldoutTranscript { var lines: [String] = [] }

@MainActor
private final class EndHoldoutApplication: AutomationSessionOperating {
    var id: UUID?
    let memoryDirectory: URL?
    var memoryApplication: String? { id == nil ? nil : "org.braus.end-heldout" }
    var observations = 0
    var actions = 0
    var ready = false
    init(root: URL) { memoryDirectory = root }
    var scene: SceneSnapshot {
        var elements = [SceneElement(id: "attempt", kind: .control, label: "Attempt",
            bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), role: "AXButton")]
        if ready { elements.append(.init(id: "ready", kind: .control, label: "Ready",
            bounds: .init(x: 0.3, y: 0.1, width: 0.1, height: 0.1), role: "AXStaticText")) }
        return SceneSnapshot(bundleID: "org.braus.end-heldout", appName: "Public fixture", windowTitle: "Main",
            viewportPixelSize: .init(width: 400, height: 200), elements: elements)
    }
    func open(application: String, window: String?) async throws -> SceneSnapshot { id = UUID(); return scene }
    func observe() async throws -> SceneSnapshot { observations += 1; return scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        guard target == "Attempt" else { throw AutomationFailure("Unexpected fake action") }
        actions += 1; ready = true
        return ActOutcome(.foundActed, "Fake application performed the requested operation", scene: scene)
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("No selection requested") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("No input requested") }
    func close() async { id = nil }
}
