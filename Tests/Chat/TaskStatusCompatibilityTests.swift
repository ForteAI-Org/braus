import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

@MainActor
struct TaskStatusCompatibilityTests {
    @Test func hostIdentityDoesNotExposeRemovedConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "status-compatibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: directory)
        do {
            do {
                let session = ToolResultSession()
                session.memoryDirectory = directory
                let tools = AutomationTools(session: session)
                let value = try await tools.runtimeIdentity()
                let object = try #require(value.object)
                #expect(object["switches"] == nil)
                #expect(object["switches_invalid"] == nil)
                // Identity depends on the installed model and local paths; its shape remains checked.
                #expect(object["archive"]?.string == memory.url.path)
                let recall = try #require(object["recall"]?.object)
                #expect(Set(recall.keys) == ["channel", "model", "models_folder", "format", "owns_index", "model_state"])
                #expect(value["runtime"]["pending_experiments"] == .array([]))
                #expect(value["runtime"]["tool_schema_sha256"].string?.count == 64)
                #expect(value["profile"]["canAct"].bool == (tools.profile.level != .observe))
            }
        } catch { Issue.record(error) }
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }
}
