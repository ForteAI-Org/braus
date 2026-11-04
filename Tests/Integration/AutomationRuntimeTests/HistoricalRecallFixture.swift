@testable import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

/// HistoricalRecallFixture preserves the typed query/choice and storage contracts independently
/// of the model catalogue. These fixtures never invoke the retired tool or TaskCycleHandler.taskAnswer.
/// Product plan/step/end flows must be tested separately; a service query is not a delivered plan row.
@MainActor
enum HistoricalRecallFixture {
    typealias P = ProcedureLearningTests

    /// These doubles provide native automation channels; adapter suites must supply their actual channel keys.
    static var nativeChannels: Set<String> { Set(AgentTool.allCases.map(\.rawValue)) }

    private static func memory(_ tools: AutomationTools) throws -> MemoryService {
        guard let directory = tools.session.memoryDirectory else { throw P.FixtureFailure("Fixture needs an archive") }
        return MemoryService.shared(for: directory)
    }

    private static func decode(_ text: String) throws -> MemoryTaskTool.Request {
        try MemoryTaskTool.decode(P.json(text), minimization: ValueMinimization(), messageRef: nil)
    }

    private static func task(_ tools: AutomationTools) throws -> OpenTask {
        guard let session = tools.session as? LearningSession else { throw P.FixtureFailure("Fixture needs a learning session") }
        let source = tools.producer.source.rawValue.replacingOccurrences(of: "'", with: "''")
        let stream = tools.producer.streamID.replacingOccurrences(of: "'", with: "''")
        let records = try P.rows("SELECT t.task_uuid || '|' || o.task_occurrence_uuid || '|' || t.current_revision FROM memory_tasks t JOIN memory_task_attempts a ON a.task_id = t.task_id JOIN memory_task_occurrences o ON o.task_occurrence_id = a.task_occurrence_id WHERE t.source = '\(source)' AND t.source_stream_id = '\(stream)' ORDER BY a.task_occurrence_id DESC LIMIT 1", in: session)
        guard let saved = records.first else { throw P.FixtureFailure("No typed task fixture is open") }
        let fields = saved.split(separator: "|")
        guard fields.count == 3, let revision = Int(fields[2]) else { throw P.FixtureFailure("Malformed typed task identity") }
        return OpenTask(taskID: String(fields[0]), attemptID: String(fields[1]), revision: revision)
    }

    private static func answer(_ task: OpenTask, _ status: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["status": .string(status), "task": .string(task.taskID), "attempt": .string(task.attemptID),
                 "revision": .number(Double(task.revision))].merging(extra, uniquingKeysWith: { $1 }))
    }

    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private static func search(_ tools: AutomationTools, task: OpenTask, content: TaskRevisionContent,
                               reason: RecallReason, plan: MemoryTaskTool.RecallPlan, proposal: Bool,
                               availableChannels: Set<String>) async throws -> [String: JSONValue] {
        let memory = try memory(tools)
        let service = RecallService.shared(for: memory)
        if tools.profile.memoryAccess.reads { await service.schedule() }
        let learned = tools.profile.memoryAccess.reads ? await service.learnedApplications() : []
        var offered: [ApplicationCandidate] = []
        for word in Set(plan.needs.compactMap(\.bundleID)).sorted() {
            offered += (try? await tools.session.applications(matching: word)) ?? []
        }
        let resolution = try RecallApplications.resolving(plan.needs, among: RecallApplications.known(learned: learned, offered: offered))
        let request = try RecallRequest(taskID: task.taskID, attemptID: task.attemptID, revision: task.revision,
            reason: reason, remainingWork: plan.remaining ?? content.goal, needs: resolution.needs,
            values: content.inputs, constraints: content.constraints, notes: resolution.notes)
        if proposal {
            let result = try await service.propose(request, producer: P.fixtureProducer(tools), access: tools.profile.memoryAccess, availableChannels: availableChannels)
            return ["recall_proposal": try json(result.delivery),
                    "memory_read_reason": result.reason.map { .string($0.rawValue) } ?? .null]
        }
        let result = try await service.recall(request, producer: P.fixtureProducer(tools), access: tools.profile.memoryAccess, availableChannels: availableChannels)
        return ["recall": try json(result.delivery),
                "memory_read_reason": result.reason.map { .string($0.rawValue) } ?? .null]
    }

    private static func begin(_ tools: AutomationTools, _ text: String, proposal: Bool,
                              availableChannels: Set<String>) async throws -> JSONValue {
        guard case .begin(let content, _, let plan) = try decode(text) else { throw P.FixtureFailure("Expected a typed begin fixture") }
        let opened = try await TaskChannel.begin(content, producer: P.fixtureProducer(tools),
                                                 traceID: tools.producer.traceID, memory: memory(tools))
        guard let plan else { return answer(opened, "begun") }
        return try await answer(opened, "begun", search(tools, task: opened, content: content,
            reason: .initial, plan: plan, proposal: proposal, availableChannels: availableChannels))
    }

    static func beginQuery(_ tools: AutomationTools, _ text: String,
                           availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        try await begin(tools, text, proposal: false, availableChannels: availableChannels)
    }

    static func beginProposal(_ tools: AutomationTools, _ text: String,
                              availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        try await begin(tools, text, proposal: true, availableChannels: availableChannels)
    }

    static func query(_ tools: AutomationTools, _ text: String,
                      availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        do {
        guard case .recall(let reason, let plan) = try decode(text) else { throw P.FixtureFailure("Expected a typed Recall query fixture") }
        let current = try task(tools)
        let revision = try await TaskChannel.revision(current.revision, of: current.taskID,
            producer: P.fixtureProducer(tools), memory: memory(tools))
        return try await answer(current, "recalled", search(tools, task: current, content: revision.content,
            reason: reason, plan: plan, proposal: false, availableChannels: availableChannels))
        } catch let failure as MemoryTaskTool.Failure {
            return .object(["status": .string("error"), "error": .string(failure.code), "message": .string(failure.message)])
        }
    }

    /// Offers a service proposal for an already opened current plan. This does not attach it to a row.
    static func proposeForCurrentTask(_ tools: AutomationTools, _ text: String,
                                      availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        guard case .begin(_, _, let plan?) = try decode(text) else { throw P.FixtureFailure("Expected proposal input fixture") }
        let current = try task(tools)
        let revision = try await TaskChannel.revision(current.revision, of: current.taskID,
            producer: P.fixtureProducer(tools), memory: memory(tools))
        return try await answer(current, "proposed", search(tools, task: current, content: revision.content,
            reason: .initial, plan: plan, proposal: true, availableChannels: availableChannels))
    }

    /// Runs the historical selector contract for a task opened by the actual plan tool.
    static func queryForCurrentTask(_ tools: AutomationTools, _ text: String,
                                    availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        guard case .begin(_, _, let plan?) = try decode(text) else { throw P.FixtureFailure("Expected query input fixture") }
        let current = try task(tools)
        let revision = try await TaskChannel.revision(current.revision, of: current.taskID,
            producer: P.fixtureProducer(tools), memory: memory(tools))
        return try await answer(current, "recalled", search(tools, task: current, content: revision.content,
            reason: .initial, plan: plan, proposal: false, availableChannels: availableChannels))
    }

    /// Declares a real current plan before exercising a separate historical selector contract.
    /// The returned value is explicitly the service query, not the model's plan response.
    static func beginPlannedQuery(_ tools: AutomationTools, _ text: String,
                                  availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        guard case .begin(let content, _, _) = try decode(text) else { throw P.FixtureFailure("Expected typed task input") }
        var fields: [String: JSONValue] = ["request": .string(content.goal),
            "rows": .array([.object(["title": .string(content.goal)])])]
        for key in ["inputs", "constraints", "requested_result"] {
            if let value = P.json(text).object?[key] { fields[key] = value }
        }
        let declared = try await tools.call("plan", .object(fields)).payload
        guard declared["status"].string == "planned" else { throw P.FixtureFailure("Plan fixture refused: \(declared)") }
        return try await queryForCurrentTask(tools, text, availableChannels: availableChannels)
    }

    /// Opens the actual current plan then makes a separately named typed service proposal.
    static func beginPlannedProposal(_ tools: AutomationTools, _ text: String,
                                     availableChannels: Set<String> = nativeChannels) async throws -> JSONValue {
        guard case .begin(let content, _, _) = try decode(text) else { throw P.FixtureFailure("Expected typed task input") }
        var fields: [String: JSONValue] = ["request": .string(content.goal),
            "rows": .array([.object(["title": .string(content.goal)])])]
        for key in ["inputs", "constraints", "requested_result"] {
            if let value = P.json(text).object?[key] { fields[key] = value }
        }
        let declared = try await tools.call("plan", .object(fields)).payload
        guard declared["status"].string == "planned" else { throw P.FixtureFailure("Plan fixture refused: \(declared)") }
        return try await proposeForCurrentTask(tools, text, availableChannels: availableChannels)
    }

    static func choose(_ tools: AutomationTools, _ text: String, preview: Bool = false) async throws -> JSONValue {
        guard case .choose(let choice) = try decode(text) else { throw P.FixtureFailure("Expected a typed choice fixture") }
        let current = try task(tools)
        let memory = try memory(tools)
        let revision = try await TaskChannel.revision(current.revision, of: current.taskID,
            producer: P.fixtureProducer(tools), memory: memory)
        do {
            let result = try await RecallService.shared(for: memory).choose(choice, taskID: current.taskID,
                attemptID: current.attemptID, revision: current.revision, values: revision.content.inputs,
                constraints: revision.content.constraints, producer: P.fixtureProducer(tools), preview: preview)
            return answer(current, result.recordedNow ? "chosen" : "already chosen", ["recall": try json(result.delivery)])
        } catch let failure as MemoryStoreError {
            switch failure {
                case .contract, .identity, .locked, .contention, .malformedText:
                    return .object(["status": .string("error"), "error": .string("choice_not_recorded"),
                                    "message": .string(MemoryService.describe(failure))])
                default: throw failure
            }
        } catch let refusal as RecallChoice.Refusal {
            return .object(["status": .string("error"), "error": .string(refusal.code.rawValue),
                            "message": .string(refusal.problems.joined(separator: "; ")),
                            "problems": .array(refusal.problems.map(JSONValue.string))])
        }
    }

    static func update(_ tools: AutomationTools, _ text: String) async throws -> JSONValue {
        guard case .update(let update, _) = try decode(text) else { throw P.FixtureFailure("Expected a typed revision fixture") }
        let current = try task(tools)
        let memory = try memory(tools)
        let expecting = update.expecting ?? current.revision
        let previous = try await TaskChannel.revision(expecting, of: current.taskID, producer: P.fixtureProducer(tools), memory: memory)
        let revised = try await TaskChannel.revise(current, expecting: expecting,
            content: update.applied(to: previous.content, messageRef: nil), reason: update.reason,
            producer: P.fixtureProducer(tools), memory: memory)
        return answer(revised, "revised")
    }

    static func status(_ tools: AutomationTools) throws -> JSONValue { answer(try task(tools), "open") }

    static func resume(_ tools: AutomationTools, taskID: String) async throws -> JSONValue {
        let resumed = try await TaskChannel.resume(taskID, producer: P.fixtureProducer(tools), memory: memory(tools))
        return answer(resumed.task, "resumed")
    }
    /// Records declared outputs/uses at the producer boundary. This does not execute the model's end tool
    /// or claim that inferred screen effects were checked; only explicitly supplied checks are read here.
    static func checkpoint(_ tools: AutomationTools, _ text: String) async throws -> JSONValue {
        guard case .checkpoint(let draft, _, let uses, let checks) = try decode(text) else {
            throw P.FixtureFailure("Expected a typed checkpoint fixture")
        }
        return try await record(tools, draft: draft, uses: uses, checks: checks)
    }

    static func end(_ tools: AutomationTools, _ text: String) async throws -> JSONValue {
        guard case .end(let draft, _, let uses, let checks) = try decode(text) else {
            throw P.FixtureFailure("Expected a typed end fixture")
        }
        return try await record(tools, draft: draft, uses: uses, checks: checks)
    }

    private static func record(_ tools: AutomationTools, draft: TaskCheckpointDraft,
                               uses: [MemoryTaskTool.UseReport], checks: [MemoryTaskTool.ResultCheck]) async throws -> JSONValue {
        let current = try task(tools)
        let memory = try memory(tools)
        let producer = try P.fixtureProducer(tools)
        let service = RecallService.shared(for: memory)
        var reported = 0
        var problems: [JSONValue] = []
        for use in uses {
            do {
                try await service.report(queryID: use.queryID, attemptID: current.attemptID,
                    needPosition: use.needPosition, declared: use.declared, cause: use.cause, note: use.note)
                reported += 1
            } catch RecallUseError.unknownQuery(let id) {
                let isProposal = await service.isProposal(id, of: current.taskID)
                problems.append(.string(isProposal ? "The supplied identity is a proposal, not a query; use not recorded" : "Unknown query: \(id)"))
            } catch { problems.append(.string(String(describing: error))) }
        }
        var results: [JSONValue] = []
        for named in checks {
            let check = try await ProcedureProducer.checkResult(named.kept, read: named.read, before: nil,
                screen: nil, asGuard: named.isGuard, attemptID: current.attemptID, producer: producer, memory: memory)
            results.append(.object(["check": .string(named.kept.line), "verdict": .string(check.verdict.rawValue),
                                    "found": .string(check.observed)]))
        }
        let saved = try await TaskChannel.checkpoint(current, draft, producer: producer, memory: memory)
        var extra: [String: JSONValue] = ["recorded": .string(saved.receipt == .committed ? "recorded" : "unchanged")]
        if reported > 0 { extra["use_reported"] = .number(Double(reported)) }
        if !problems.isEmpty { extra["use_not_recorded"] = .array(problems) }
        if !results.isEmpty { extra["result_check"] = .array(results) }
        _ = await memory.flush(within: .seconds(2))
        let summaries = try await service.link(attemptID: current.attemptID, taskID: current.taskID, producer: producer)
        if !summaries.isEmpty {
            extra["recall_use"] = .array(summaries.map { summary in
                .object(["query": .string(summary.queryID), "need": .number(Double(summary.needPosition + 1)),
                    "tract": summary.tract.map { .number(Double($0 + 1)) } ?? .null,
                    "steps_carried_out": .array(summary.executed.map { .number(Double($0 + 1)) }),
                    "verified": .array(summary.confirmed.map { .number(Double($0 + 1)) }),
                    "not_carried_out": .array(summary.notExecuted.map { .number(Double($0 + 1)) }),
                    "own_operations": .number(Double(summary.ownOperations)),
                    "undetermined": .number(Double(summary.undetermined))])
            })
        }
        if tools.profile.memoryAccess.learns,
           let candidate = try await ProcedureProducer.candidate(attemptID: current.attemptID, producer: producer, memory: memory) {
            extra["candidate"] = TaskCycleHandler.candidate(candidate)
        }
        if draft.kind == .end { extra["outcome"] = .string(saved.checkpoint.declared?.rawValue ?? "") }
        else { extra["sequence"] = .number(Double(saved.checkpoint.sequence)) }
        return answer(current, draft.kind == .end ? "ended" : "checkpointed", extra)
    }

}
