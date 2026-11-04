import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

extension TaskCycleHandler {
    /// Reads host identity without invoking a tool removed from the active catalogue.
    func statusAnswer(memory: MemoryService) async -> JSONValue {
        let suspended = await memory.status().suspended
        var answer: [String: JSONValue] = ["status": .string(openTask == nil ? ModelText.text(.init(rawValue: "task_cycle_handler__answer.answer.v1")) : "open")]
        if let current = openTask {
            answer["task"] = .string(current.taskID)
            answer["attempt"] = .string(current.attemptID)
            answer["revision"] = .number(Double(current.revision))
        }
        if let suspended { answer["memory"] = .string((ModelText.text(.init(rawValue: "answer.TaskCycleHandler.Answer.suspended.v1.fragment.0"))
            + "\(suspended)")) }
        // What this process records into and recalls with, as it resolved them: for a run's preflight, which needs the
        // process's own archive and configuration, not a value set in a shell.
        answer["archive"] = .string(memory.url.path)
        let recall = await RecallService.shared(for: memory).identity()
        answer["recall"] = .object(["channel": .string(recall.channel), "model": recall.model.map(JSONValue.string) ?? .null,
                                    "models_folder": recall.modelsFolder.map(JSONValue.string) ?? .null,
                                    "format": .string(recall.format), "owns_index": .bool(recall.ownsIndex),
                                    "model_state": .string(recall.modelState)])
        if reportsProfile { answer["profile"] = profile.status }
        return .object(answer)
    }

}
