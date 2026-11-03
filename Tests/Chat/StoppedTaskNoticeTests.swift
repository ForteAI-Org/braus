import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
struct StoppedTaskNoticeTests {
    @Test func factsDoNotConsumeTheLegacyNoticeAndV2HasNoIdentity() async throws {
        let directory = URL.temporaryDirectory.appending(path: "seat-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let session = ToolResultSession()
        session.memoryDirectory = directory
        session.memoryApplication = "test.synthetic"
        let tools = AutomationTools(session: session)
        _ = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Set a track"), "recall": .bool(false)
        ]))
        let taskID = try #require(tools.openTask).taskID
        #expect(await tools.taskFacts(for: "test.synthetic") == SeatTaskFacts(isOpen: true))
        tools.markTaskInterrupted()
        try await tools.finishInterruptedTask()
        #expect(await tools.taskFacts(for: "test.synthetic") == SeatTaskFacts())
        enum RenderFailure: Error { case insufficientBudget }
        #expect(throws: RenderFailure.insufficientBudget) {
            try tools.withStoppedTaskNotice { _ -> String? in throw RenderFailure.insufficientBudget }
        }
        let legacy = try #require(tools.withStoppedTaskNotice { $0 })
        #expect(legacy == "Braus stopped task \(taskID) and closed its attempt as abandoned, not completed. "
            + "Begin a new task for the current request, including any remaining work toward the same goal. "
            + "The abandoned task cannot be resumed. Observe current effects first; never repeat an uncertain action.")
        let current = ModelText.text(.init(rawValue: "seat_line.stopped.v2"))
        #expect(current == "The previous task was stopped by the person and closed as abandoned. "
            + "Begin a new task for this request. Observe current effects first; never repeat an uncertain action.")
        #expect(!current.contains(taskID))
        #expect(tools.takeStoppedTaskNotice() == nil)
    }
}
