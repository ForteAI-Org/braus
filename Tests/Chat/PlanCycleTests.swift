@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing
@testable import SQLiteMemory

@MainActor
struct PlanCycleTests {
    private func arguments(_ count: Int) -> JSONValue {
        .object(["request": .string("Prepare a document"), "rows": .array((0..<count).map { index in
            .object(["title": .string("Subprocedure \(index + 1)")])
        })])
    }

    @Test func firstPlanHasNoReasonAndTenRowsFit() throws {
        let request = try PlanRequest(arguments(10), minimization: ValueMinimization(), messageRef: nil)
        #expect(request.rows.count == 10)
        #expect(request.reason == nil)
    }

    @Test func eleventhRowRefusalNamesBothWaysForward() throws {
        do {
            _ = try PlanRequest(arguments(11), minimization: ValueMinimization(), messageRef: nil)
            Issue.record("Accepted eleven rows")
        } catch let failure as MemoryTaskTool.Failure {
            #expect(failure.code == "todo_row_limit")
            #expect(failure.message.contains("Summarize completed rows into one"))
            #expect(failure.message.contains("end and continue in a new task"))
        }
    }

    @Test func titleAndExpectationBoundariesAndNoSecondLevel() throws {
        for length in [120, 121] {
            let value: JSONValue = .object(["request": .string("Prepare"), "rows": .array([
                .object(["title": .string(String(repeating: "t", count: length))])])])
            if length == 120 { #expect(try PlanRequest(value, minimization: .init(), messageRef: nil).rows.count == 1) }
            else { #expect(throws: MemoryTaskTool.Failure.self) { _ = try PlanRequest(value, minimization: .init(), messageRef: nil) } }
        }
        for length in [160, 161] {
            let value: JSONValue = .object(["request": .string("Prepare"), "rows": .array([
                .object(["title": .string("Finish"), "expect": .object(["none": .string(String(repeating: "r", count: length))])])])])
            if length == 160 { #expect(try PlanRequest(value, minimization: .init(), messageRef: nil).rows.count == 1) }
            else { #expect(throws: MemoryTaskTool.Failure.self) { _ = try PlanRequest(value, minimization: .init(), messageRef: nil) } }
        }
        let nested: JSONValue = .object(["request": .string("Prepare"), "rows": .array([
            .object(["title": .string("Prepare"), "steps": .array([])])])])
        #expect(throws: MemoryTaskTool.Failure.self) { _ = try PlanRequest(nested, minimization: .init(), messageRef: nil) }
    }

    @Test func structuralRevisionsNeedReasonBeforeArchiveOrRecall() async throws {
        let session = ToolResultSession()
        session.memoryDirectory = URL.temporaryDirectory.appending(path: "tu6-reason-\(UUID().uuidString)")
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        handler.openTask = OpenTask(taskID: "task", attemptID: "attempt", revision: 1)
        handler.todo = Todo(taskID: "task", revision: 1, rows: [
            TodoRow(id: .init(rawValue: "r1"), title: "Prepare"), TodoRow(id: .init(rawValue: "r2"), title: "Save")])
        let row1: JSONValue = .object(["id": .string("r1"), "title": .string("Prepare")])
        let row2: JSONValue = .object(["id": .string("r2"), "title": .string("Save")])
        for rows in [[row1], [row2, row1], [row1, row2, .object(["title": .string("Check")])]] {
            let request = try PlanRequest(.object(["rows": .array(rows)]), minimization: .init(), messageRef: nil)
            do {
                _ = try await handler.plan(request)
                Issue.record("Accepted structural revision without reason")
            } catch let failure as MemoryTaskTool.Failure {
                #expect(failure.code == "plan_reason_required")
            }
            #expect(handler.todo?.revision == 1)
            #expect(session.calls.isEmpty)
        }
    }

    @Test func unavailableArchiveNeverOpensFirstTask() async throws {
        let root = URL.temporaryDirectory.appending(path: "tu6-unavailable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "not-a-directory")
        let original = Data("This file must not be replaced by an operation archive.".utf8)
        try original.write(to: directory)
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let tools = AutomationTools(session: session)
        let memory = MemoryService.shared(for: directory)
        do {
            let result = try await tools.call("plan", arguments(1))
            #expect(result["isError"].bool == true)
            let text = try #require(result["content"].array?.first?["text"].string)
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            #expect(payload["status"].string == "error")
            #expect(payload["error"].string == "memory_unavailable")
            #expect(tools.openTask == nil)
            #expect(session.calls.isEmpty)
        } catch {
            await memory.close()
            MemoryService.forget(directory)
            throw error
        }
        await memory.close()
        MemoryService.forget(directory)
        #expect(try Data(contentsOf: directory) == original)
    }
}

@MainActor
struct EndContractTests {
    @Test func noOpenTaskHasCode() async throws {
        do {
            let tools = AutomationTools(session: ToolResultSession())
            let result = try await tools.call("end", .object(["outcome": .string("completed")]))
            #expect(result["isError"].bool == true)
            #expect(String(describing: result).contains("no_open_task"))
        }
    }
}

@MainActor
struct AfterTurnInterpretationTests {
    @Test func aPendingCandidateStaysInternal() {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let scene = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: scene)
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        handler.pendingCandidate = "candidate"
        do {
            #expect(handler.takeInterpretationReminder() == nil)
        }
        #expect(handler.takeInterpretationReminder() == nil)
        #expect(handler.pendingCandidate == "candidate")
    }
}

extension PlanCycleTests {
    @Test func abandonedRowCannotBeRelisted() async throws {
        let session = ToolResultSession()
        session.memoryDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let secrets = ProducerSecrets()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: SceneTextPolicy())
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        handler.openTask = OpenTask(taskID: "task", attemptID: "attempt", revision: 1)
        handler.todo = Todo(taskID: "task", revision: 1, rows: [
            TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .abandoned)])
        let request = try PlanRequest(.object(["reason": .string("Restore"), "rows": .array([
            .object(["id": .string("r1"), "title": .string("Prepare")])])]), minimization: .init(), messageRef: nil)
        do {
            _ = try await handler.plan(request)
            Issue.record("Accepted an abandoned row")
        } catch let failure as MemoryTaskTool.Failure {
            #expect(failure.code == "unknown_step")
        }
    }
}
