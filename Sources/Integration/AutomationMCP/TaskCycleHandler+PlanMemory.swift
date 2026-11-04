import AutomationRuntime
import Foundation
import LocalMCP
import Memory

extension TaskCycleHandler {
    /// Uses one Recall request and budget for every row newly delivered in this plan.
    func deliverMemory(for rows: [TodoRow], content: TaskRevisionContent, task: OpenTask,
                       owner: TaskProducer, memory: MemoryService, baseAnswer: [String: JSONValue] = [:],
                       state: PlanMemoryState? = nil) async -> [String: JSONValue] {
        await deliverPlanMemory(for: rows, content: content, task: task, owner: owner, memory: memory,
                                baseAnswer: baseAnswer, state: state)
    }

    /// Previews changed row choices using the current task's values and offer identities.
    func chooseParts(_ rows: [TodoRow], task: OpenTask, content: TaskRevisionContent,
                     owner: TaskProducer, memory: MemoryService, state: PlanMemoryState) async throws {
        _ = await preparePlanChoices(rows, task: task, content: content, owner: owner, memory: memory, state: state)
    }
}
