import Capabilities

@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing
import SQLiteMemory

@MainActor
struct TaskInputContractTests {
    private func assertNoTaskWrites(_ directory: URL) async throws {
        // Facade initialization may prepare Catalogue independently of this rejected call.
        let memory = MemoryService.shared(for: directory)
        let counts = try await memory.perform { repositories in
            try await repositories.store.read { transaction in
                try transaction.query("""
                    SELECT (SELECT COUNT(*) FROM memory_tasks),
                           (SELECT COUNT(*) FROM memory_task_occurrences),
                           (SELECT COUNT(*) FROM memory_task_end_checks)
                    """) { [$0.integer(0), $0.integer(1), $0.integer(2)] }
            }
        }
        #expect(counts == [[0, 0, 0]])
        await memory.close()
        MemoryService.forget(directory)
    }

    private let invalidChecks: [JSONValue] = [
        .object(["element": .string("Public marker"), "present": .string("false")]),
        .object(["window": .string("Public window"), "open": .string("false")]),
        .object(["element": .string("Public marker"), "present": .bool(false), "value": .string("x")]),
        .object(["element": .string("Public marker"), "window": .string("Public window")]),
        .object(["file_moved": .string("/public/a"), "to": .string("/public/b"), "none": .string("unknown")])
    ]

    @Test func invalidChecksAreRejectedByDecoderAndServedSchema() throws {
        let schema = try #require(AutomationTools.definitions.first { $0["name"].string == "end" })["inputSchema"]
        for check in invalidChecks {
            let args: JSONValue = .object(["outcome": .string("failed"), "result_check": check])
            #expect(SchemaValidation.firstProblem(args, schema: schema) != nil)
            #expect(throws: MemoryTaskTool.Failure.self) { _ = try EndRequest(args, minimization: .init()) }
        }
    }

    @Test func invalidInputDoesNotOpenTaskOrCreateTaskDatabase() async throws {
        let directory = URL.temporaryDirectory.appending(path: "contract-public-\(UUID().uuidString)")
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session)
        let args: JSONValue = .object(["request": .string("Public fixture"),
            "inputs": .array([.object(["name": .string("marker"), "value": .string("PUBLIC_TEST_MARKER"),
                "secret": .string("true")])]), "rows": .array([.object(["title": .string("Check")])])])
        #expect(throws: MemoryTaskTool.Failure.self) { _ = try PlanRequest(args, minimization: .init(), messageRef: nil) }
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("plan"), "arguments": args])])
        let response = try #require(await router.handle(request))["result"]
        #expect(response["isError"].bool == true)
        #expect(tools.openTask == nil)
        #expect(session.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "memory.sqlite").path))
        try await assertNoTaskWrites(directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            let memory = MemoryService.shared(for: directory)
            await memory.close()
            MemoryService.forget(directory)
            try FileManager.default.removeItem(at: directory)
        }
    }

    @Test func explicitNullIsNotAnOmittedField() throws {
        let base: [String: JSONValue] = ["request": .string("Public task"),
            "rows": .array([.object(["title": .string("Check")])])]
        for key in ["request", "inputs"] {
            var args = base
            args[key] = .null
            do { _ = try PlanRequest(.object(args), minimization: .init(), messageRef: nil); Issue.record("Accepted null \(key)") }
            catch {}
        }
        var row = base
        row["rows"] = .array([.object(["title": .string("Check"), "expect": .null])])
        do { _ = try PlanRequest(.object(row), minimization: .init(), messageRef: nil); Issue.record("Accepted null expect") }
        catch {}
        do { _ = try EndRequest(.object(["outcome": .string("failed"), "result_check": .null]), minimization: .init()); Issue.record("Accepted null result check") }
        catch {}
    }

    @Test func unicodeBoundsAreRejectedBeforeWritesAndBoundaryTitleIsStored() async throws {
        let schema = try #require(AutomationTools.definitions.first { $0["name"].string == "plan" })["inputSchema"]
        let boundary = String(repeating: "a\u{0301}", count: 60)
        let tooLong = String(repeating: "a\u{0301}", count: 120)
        #expect(boundary.count == 60 && boundary.unicodeScalars.count == 120)
        func args(_ title: String, reason: String? = nil, expect: JSONValue? = nil) -> JSONValue {
            var row: [String: JSONValue] = ["title": .string(title)]
            if let expect { row["expect"] = expect }
            var fields: [String: JSONValue] = ["request": .string("Public Unicode fixture"), "rows": .array([.object(row)])]
            if let reason { fields["reason"] = .string(reason) }
            return .object(fields)
        }
        #expect(SchemaValidation.firstProblem(args(boundary), schema: schema) == nil)
        #expect(SchemaValidation.firstProblem(args(tooLong), schema: schema) != nil)
        #expect(SchemaValidation.firstProblem(args("Check", reason: String(repeating: "x", count: 201)), schema: schema) != nil)
        _ = try PlanRequest(args("Check", reason: String(repeating: "é", count: 100)), minimization: .init(), messageRef: nil)
        for invalid in [args(tooLong), args("Check", reason: String(repeating: "é", count: 101)),
                        args("Check", expect: .object(["none": .string(String(repeating: "a\u{0301}", count: 81))]))] {
            let directory = URL.temporaryDirectory.appending(path: "contract-unicode-invalid-\(UUID().uuidString)")
            let session = ToolResultSession()
            session.memoryDirectory = directory
            let tools = AutomationTools(session: session)
            #expect(throws: MemoryTaskTool.Failure.self) { _ = try PlanRequest(invalid, minimization: .init(), messageRef: nil) }
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string("plan"), "arguments": invalid])])
            #expect(try #require(await router.handle(request))["result"]["isError"].bool == true)
            #expect(tools.openTask == nil && session.calls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "memory.sqlite").path))
            try await assertNoTaskWrites(directory)
            try FileManager.default.removeItem(at: directory)
        }
        let directory = URL.temporaryDirectory.appending(path: "contract-unicode-valid-\(UUID().uuidString)")
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session)
        let result = try await tools.call("plan", args(boundary))
        #expect(result["isError"].bool != true)
        let task = try #require(tools.openTask)
        let memory = MemoryService.shared(for: directory)
        let todo = try await TaskChannel.todo(of: task.taskID, memory: memory)
        #expect(todo?.rows.first?.title == boundary)
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func validBooleansKeepTheirMeaning() throws {
        for flag in [true, false] {
            let checks = try MemoryTaskTool.resultChecks(.object(["window": .string("Public window"), "open": .bool(flag)]), minimization: .init())
            guard case .window(_, _, let open) = checks.first?.read else { Issue.record("Missing window check"); return }
            #expect(open == flag)
        }
    }
}
