import AutomationRuntime
import Foundation
import LocalMCP
import Memory

extension TaskCycleHandler {
    /// Uses one existing Recall request and budget for every row newly delivered in this plan.
    func deliverMemory(for rows: [TodoRow], content: TaskRevisionContent, task: OpenTask,
                       owner: TaskProducer, memory: MemoryService, baseAnswer: [String: JSONValue] = [:], state: PlanMemoryState? = nil) async -> [String: JSONValue] {
        if RecallRendering.Version.current == .v2 {
            return await deliverPlanMemory(for: rows, content: content, task: task, owner: owner, memory: memory, baseAnswer: baseAnswer, state: state)
        }
        guard memoryAccess.reads else { return ["guidance": .string(ModelText.text(.init(rawValue: "recall.notRead")))] }
        do {
            let service = RecallService.shared(for: memory)
            let learned = access.reads ? await service.learnedApplications() : []
            var needs: [RecallNeed] = []
            var searched: [TodoRow] = []
            var candidates: [JSONValue] = []
            for row in rows {
                if let app = row.app {
                    let offered = try await session.applications(matching: app)
                    let need = try RecallNeed(text: row.title, bundleID: app)
                    let resolution = try RecallApplications.resolving([need],
                        among: RecallApplications.known(learned: learned, offered: offered))
                    guard let resolved = resolution.needs.first, let bundle = resolved.bundleID else {
                        candidates.append(.object(["row": .string(row.id.rawValue),
                            "candidates": .array(offered.map(ToolArguments.candidate)), "parts": .array([])]))
                        continue
                    }
                    needs.append(try RecallNeed(text: row.title, bundleID: bundle))
                } else { needs.append(try RecallNeed(text: row.title)) }
                searched.append(row)
            }
            var result: [String: JSONValue] = [:]
            if !candidates.isEmpty { result["applications"] = .array(candidates) }
            guard !needs.isEmpty else { return result }
            if access.reads { await service.schedule() }
            let request = try RecallRequest(taskID: task.taskID, attemptID: task.attemptID, revision: task.revision,
                reason: .initial, remainingWork: content.goal, needs: needs, values: content.inputs,
                constraints: content.constraints, notes: [])
            let answer = try await service.propose(request, producer: owner, access: access)
            let proposal = try memoryDelivery(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(answer.delivery)), reason: answer.reason)
            result["recall_proposal"] = proposal
            try state?.validate()
            let sources = proposal["sources"].array ?? []
            if let proposalID = proposal["proposal"].string, !sources.isEmpty {
                let parts = try await TaskChannel.todoParts(in: sources.compactMap { $0["version"].string }, memory: memory)
                try state?.validate()
                var offered: [String: (source: String, first: Int, last: Int)] = [:]
                for part in parts {
                    if let source = sources.first(where: { $0["version"].string == part.version })?["source"].string {
                        offered[part.id] = (source, part.first, part.last)
                    }
                }
                for (index, row) in searched.enumerated() {
                    rowMemory[row.id] = RowMemory(proposal: proposalID, need: index, parts: offered)
                }
                result["parts"] = .array(parts.map { part in
                    .object(["id": .string(part.id), "source": .string(offered[part.id]?.source ?? ""),
                        "from": .number(Double(part.first + 1)), "to": .number(Double(part.last + 1))])
                })
                if !parts.isEmpty { result["choice"] = .string(ModelText.text(.init(rawValue: "task_cycle.choice.v2"))) }
            }
            result["memory_rows"] = .array(searched.enumerated().map { index, row in
                .object(["row": .string(row.id.rawValue), "need": .number(Double(index + 1))])
            })
            return result
        } catch {
            return ["recall_error": .string(MemoryService.describe(error))]
        }
    }

    /// The existing choice contract accepts one complete proposal, so choices sharing it are grouped.
    func chooseParts(_ rows: [TodoRow], task: OpenTask, content: TaskRevisionContent,
                     owner: TaskProducer, memory: MemoryService, state: PlanMemoryState) async throws {
        if RecallRendering.Version.current == .v2 {
            _ = await preparePlanChoices(rows, task: task, content: content, owner: owner, memory: memory, state: state)
            return
        }
        guard memoryAccess.reads else { return }
        let changed = rows.filter { row in row.part != nil && todo?.rows.first(where: { $0.id == row.id })?.part != row.part }
        let proposals = Set(try changed.map { row -> String in
            guard let offered = rowMemory[row.id], let part = row.part, offered.parts[part] != nil else {
                throw MemoryTaskTool.Failure(code: "unknown_part", message: ModelText.text(.init(rawValue: "task_cycle.unknown_part.v2")))
            }
            return offered.proposal
        })
        for proposal in proposals.sorted() {
            let members = rowMemory.filter { $0.value.proposal == proposal }.sorted { $0.value.need < $1.value.need }
            let needs = members.map { id, offered -> RecallChoice.PlannedNeed in
                let selected = rows.first { $0.id == id }?.part.flatMap { offered.parts[$0] }
                let tracts = selected.map { [RecallChoice.Tract(key: $0.source, first: $0.first, last: $0.last)] } ?? []
                return RecallChoice.PlannedNeed(position: offered.need, tracts: tracts,
                    declared: selected == nil ? .none : .all, uncovered: nil, alternatives: [], settledBy: nil)
            }
            _ = try await RecallService.shared(for: memory).choose(.init(proposalID: proposal, needs: needs),
                taskID: task.taskID, attemptID: task.attemptID, revision: task.revision, values: content.inputs,
                constraints: content.constraints, producer: owner)
        }
    }
}
