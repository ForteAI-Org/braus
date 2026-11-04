import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
struct StoppedTaskNoticeTests {
    @Test func factsDoNotConsumeTheStoppedNoticeAndModelHasNoIdentity() async throws {
        let directory = URL.temporaryDirectory.appending(path: "seat-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let session = ToolResultSession()
        session.memoryDirectory = directory
        session.memoryApplication = "test.synthetic"
        let tools = AutomationTools(session: session)
        _ = try await tools.call("plan", .object(["request": .string("Set a track"),
            "rows": .array([.object(["title": .string("Set a track")])])]))
        let taskID = try #require(tools.openTask).taskID
        let open = await tools.taskFacts(for: "test.synthetic")
        #expect(open == SeatTaskFacts(isOpen: true, learnedForApp: 0))
        tools.markTaskInterrupted()
        try await tools.finishInterruptedTask()
        let stopped = await tools.taskFacts(for: "test.synthetic")
        #expect(stopped == SeatTaskFacts(learnedForApp: 0))
        enum RenderFailure: Error { case insufficientBudget }
        #expect(throws: RenderFailure.insufficientBudget) {
            try tools.withStoppedTaskNotice { _ -> String? in throw RenderFailure.insufficientBudget }
        }
        let notice = try #require(tools.withStoppedTaskNotice { $0 })
        #expect(notice == "Braus stopped the previous task and closed it as abandoned, not completed. "
            + "Plan the current request as a new task; plan's answer lists the rows of the stopped task that were done and verified. "
            + "Observe current effects first; never repeat an uncertain action.")
        #expect(!notice.contains(taskID))
        let current = ModelText.text(.init(rawValue: "seat_line.stopped.v2"))
        #expect(current == "The previous task was stopped by the person and closed as abandoned. "
            + "Begin a new task for this request. Observe current effects first; never repeat an uncertain action.")
        #expect(!current.contains(taskID))
        #expect(tools.takeStoppedTaskNotice() == nil)
        await MemoryService.shared(for: directory).close()
        MemoryService.forget(directory)
    }
}
