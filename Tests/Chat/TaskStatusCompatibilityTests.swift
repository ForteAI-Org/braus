import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct TaskStatusCompatibilityTests {
    @Test func absentSwitchesPreserveLegacyStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "status-compatibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: directory)
        do {
            try await SwitchBoard.$testing.withValue(SwitchBoard()) {
                let session = ToolResultSession()
                session.memoryDirectory = directory
                let tools = AutomationTools(session: session)
                let response = try await tools.call("memory_task", .object(["operation": .string("status")]))
                let text = try #require(response["content"].array?.first?["text"].string)
                var value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                var object = try #require(value.object)
                #expect(object["switches"] == nil)
                #expect(object["switches_invalid"] == nil)
                // Identity depends on the installed model and local paths; its shape remains checked.
                #expect(object["archive"]?.string == memory.url.path)
                let recall = try #require(object["recall"]?.object)
                #expect(Set(recall.keys) == ["channel", "model", "models_folder", "format", "owns_index", "model_state"])
                object["archive"] = .string("<archive>")
                object["recall"] = .string("<recall-identity>")
                value = .object(object)
                try ToolGolden.compare(value, named: "memory-task-status-default")
            }
        } catch { Issue.record(error) }
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }
}
