import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

extension ToolResultSession {
    /// Exercises the current plan contract on an isolated real archive, with deterministic cleanup.
    @MainActor
    func withPlannedTools<Value>(_ body: (AutomationTools) async throws -> Value) async throws -> Value {
        let directory = URL.temporaryDirectory.appending(path: "tool-result-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memoryDirectory = directory
        let memory = MemoryService.shared(for: directory)
        func close() async {
            await memory.close()
            MemoryService.forget(directory)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let tools = AutomationTools(session: self)
            let plan = try await tools.call("plan", .object(["request": .string("Use the controls"),
                "rows": .array([.object(["title": .string("Use the controls")])])]))
            let text = try #require(plan["content"].array?.first?["text"].string)
            let answer = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            try #require(answer["status"] == .string("planned"), "\(plan)")
            let value = try await body(tools)
            await close()
            return value
        } catch {
            await close()
            throw error
        }
    }
}
