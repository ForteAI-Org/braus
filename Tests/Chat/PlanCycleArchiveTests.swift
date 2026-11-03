@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Switches
import Testing
@testable import SQLiteMemory

/// Exercises the complete tool path once the separately delivered migration activates the archive.
@MainActor
@Suite(.enabled(if: SQLiteMemorySchema.version >= 22, "Requires DB2 to activate schema 22"))
struct PlanCycleArchiveTests {
    private func payload(_ result: JSONValue) throws -> JSONValue {
        let text = try #require(result["content"].array?.first?["text"].string)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func planRevisionStepAttributionAndEndShareOneTask() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["task_cycle": "v2", "tool_surface": "v2"])) {
            let directory = URL.temporaryDirectory.appending(path: "tu6-cycle-\(UUID().uuidString)")
            let session = ToolResultSession()
            session.memoryDirectory = directory
            session.memoryApplication = "test.synthetic"
            let tools = AutomationTools(session: session)
            let r1: JSONValue = .object(["title": .string("Prepare")])
            let r2: JSONValue = .object(["title": .string("Save")])
            let first = try payload(await tools.call("plan", .object(["request": .string("Prepare and save"), "rows": .array([r1, r2])])))
            let taskID = try #require(first["task"].string)
            #expect(first["rows"].array?.map { $0["id"].string } == ["r1", "r2"])
            let kept1: JSONValue = .object(["id": .string("r1"), "title": .string("Prepare")])
            let kept2: JSONValue = .object(["id": .string("r2"), "title": .string("Save")])
            let third: JSONValue = .object(["title": .string("Verify")])
            let refused = try await tools.call("plan", .object(["rows": .array([kept1, kept2, third])]))
            #expect(refused["isError"].bool == true)
            let revised = try payload(await tools.call("plan", .object([
                "rows": .array([kept1, kept2, third]), "reason": .string("Verify the saved result")])))
            #expect(revised["task"].string == taskID)
            #expect(revised["rows"].array?.last?["id"].string == "r3")
            for _ in 0..<3 {
                _ = try await tools.call("act", .object(["target": .string("Prepare"), "step": .string("r1")]))
            }
            _ = try await tools.call("act", .object(["target": .string("Save"), "step": .string("r2")]))
            let memory = MemoryService.shared(for: directory)
            let beforeEnd = try await memory.perform { try await $0.todos.attributedCalls(ofTask: taskID, item: .init(rawValue: "r1")) }
            #expect(beforeEnd.count == 3)
            let ended = try payload(await tools.call("end", .object(["outcome": .string("completed"),
                "result_check": .object(["none": .string("No readable result")]) ])))
            #expect(ended["completion_evidence"]["goal_match"].string == "not_assessed")
            #expect(ended["completion_evidence"]["scope"].string == "declared_predicates_only")
            let calls = try await memory.perform { try await $0.todos.attributedCalls(ofTask: taskID) }
            #expect(calls.count == 4)
            let revisions = try await TaskChannel.todoRevisions(of: taskID, memory: memory)
            #expect(revisions.contains { $0.change == .revised(reason: "Verify the saved result") })
            let next = try payload(await tools.call("plan", .object(["request": .string("Another task"), "rows": .array([r1])])))
            #expect(next["task"].string != taskID)
            await memory.close()
        }
    }
    @Test func replacingAWithheldLiteralReopensTheRowAndClearsItsStopReference() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["task_cycle": "v2", "tool_surface": "v2"])) {
            let directory = URL.temporaryDirectory.appending(path: "tu6-proof-\(UUID().uuidString)")
            let session = ToolResultSession()
            session.memoryDirectory = directory
            session.memoryApplication = "test.synthetic"
            let tools = AutomationTools(session: session)
            let initial: JSONValue = .object(["title": .string("Prepare"),
                "expect": .object(["file_absent": .string(directory.appending(path: "first").path)])])
            _ = try await tools.call("plan", .object(["request": .string("Prepare and inspect"),
                "rows": .array([initial, .object(["title": .string("Inspect")])])]))
            _ = try await tools.call("act", .object(["target": .string("Prepare"), "step": .string("r1")]))
            _ = try await tools.call("act", .object(["target": .string("Inspect"), "step": .string("r2")]))
            let result = try await tools.call("plan", .object(["rows": .array([
                .object(["id": .string("r1"), "title": .string("Prepare"),
                    "expect": .object(["file_absent": .string(directory.appending(path: "second").path)])]),
                .object(["id": .string("r2"), "title": .string("Inspect")])])]))
            let revised = try payload(result)
            #expect(revised["rows"].array?.first?["status"].string == "pending")
            let closed = try await tools.closeStoppedTask(.person)
            let reference = try #require(closed)
            #expect(reference.verifiedRows.isEmpty)
            await MemoryService.shared(for: directory).close()
        }
    }

}
