import AutomationRuntime
import Foundation
import LocalMCP
import Memory

extension TaskCycleHandler {
    /// Restores authoritative open-plan facts when the host cannot carry earlier tool results.
    func continuationContext() async throws -> String? {
        guard let task = openTask else { return nil }
        let (memory, owner) = try cycleMemory()
        let revision = try await TaskChannel.revision(task.revision, of: task.taskID, producer: owner, memory: memory)
        let todo = try await currentTodo(memory)
        guard openTask == task else { throw CancellationError() }
        let inputs = revision.content.inputs.map { input -> JSONValue in
            var value: [String: JSONValue] = ["name": .string(input.name), "kind": .string(input.kind.rawValue)]
            switch input.content {
            case .text(let text): value["value"] = .string(text)
            case .missing: value["value"] = .null
            case .withheld: value["withheld"] = .bool(true)
            }
            if let role = input.role { value["role"] = .string(role) }
            return .object(value)
        }
        let data = JSONValue.object(["task": .string(task.taskID), "revision": .number(Double(task.revision)),
            "request": .string(revision.content.goal), "inputs": .array(inputs),
            "rows": .array((todo?.rows ?? []).map(planRowJSON)),
            "uncertain_gesture": lastGestureUncertain.map(JSONValue.bool) ?? .string("not_known")])
        let text = String(decoding: try JSONValue.canonicalEncoder().encode(data), as: UTF8.self)
        let minimized = producerSecrets.recordMinimization.minimize(text: text).0
        let escaped = minimized.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<open_task>\n" + escaped + "\n</open_task>"
    }
}
