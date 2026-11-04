import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import os

extension TaskCycleHandler {
    struct RowMemory {
        let proposal: String
        let need: Int
        let parts: [String: (source: String, first: Int, last: Int)]
    }

    func cycleCall(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        for secret in MemoryTaskTool.declaredSecrets(in: arguments) where !producerSecrets.secrets.contains(secret) {
            producerSecrets.secrets.append(secret)
        }
        try formatter.transcribe("→ \(name)", Self.masked(arguments))
        let answer: JSONValue
        let isError: Bool
        do {
            switch name {
            case "plan": answer = try await plan(PlanRequest(arguments, minimization: producerSecrets.recordMinimization,
                                                           messageRef: producer.messageRef))
            case "end": answer = try await end(EndRequest(arguments, minimization: producerSecrets.recordMinimization))
            default: throw MemoryTaskTool.Failure(code: "unknown_tool", message: ModelText.text(.init(rawValue: "task_cycle.unknown_tool.v2")))
            }
            isError = false
        } catch let failure as MemoryTaskTool.Failure {
            answer = Self.taskFailure(failure); isError = true
        } catch let error as TodoStoreError {
            let code: String
            switch error {
            case .unavailable: code = "todo_unavailable"
            case .staleRevision: code = "stale_todo_revision"
            default: code = "invalid_todo"
            }
            answer = Self.taskFailure(.init(code: code, message: MemoryService.describe(error))); isError = true
        } catch let error as TaskContextError {
            answer = Self.taskFailure(Self.failure(of: error)); isError = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            answer = Self.taskFailure(.init(code: "memory_unavailable", message: MemoryService.describe(error))); isError = true
        }
        try formatter.transcribe("← \(name)", answer)
        return MCPRouter.toolResult(answer, isError: isError)
    }

    func plan(_ request: PlanRequest) async throws -> JSONValue {
        let interruption = interruptionIdentity
        await acquirePlan()
        defer { releasePlan() }
        guard interruptionIdentity == interruption else { throw CancellationError() }
        let (memory, owner) = try cycleMemory()
        let identity = UUID()
        activePlan = identity
        var expectedTask = openTask
        func checkPlan() throws {
            try Task.checkCancellation()
            guard activePlan == identity, interruptedProducer == nil, openTask == expectedTask else {
                throw CancellationError()
            }
        }
        try checkPlan()
        let state = planMemoryState(validate: checkPlan)
        let old = try await currentTodo(memory)
        try checkPlan()
        let retained = request.rows.compactMap(\.id)
        guard Set(retained).count == retained.count,
              retained.allSatisfy({ id in old?.rows.contains(where: { $0.id == id && $0.status != .abandoned }) == true }) else {
            throw MemoryTaskTool.Failure(code: "unknown_step", message: ModelText.text(.init(rawValue: "task_cycle.retained_ids.v2")))
        }
        let active = old?.rows.filter { $0.status != .abandoned } ?? []
        let orderChanged = request.rows.contains { $0.id == nil } || retained != active.map(\.id)
        guard old == nil || !orderChanged || request.reason != nil else {
            throw MemoryTaskTool.Failure(code: "plan_reason_required", message: ModelText.text(.init(rawValue: "task_cycle.reason_required.v2")))
        }
        if old == nil, request.request == nil {
            throw MemoryTaskTool.Failure(code: "plan_request_required", message: ModelText.text(.init(rawValue: "task_cycle.request_required.v2")))
        }
        try await TaskChannel.requireTodos(memory: memory)
        try checkPlan()
        let inputFacts = await Self.fingerprints(of: request.rawInputs)
        try checkPlan()
        var nextID = (old?.rows.compactMap { Int($0.id.rawValue.dropFirst()) }.max() ?? 0)
        var checks = rowChecks
        var rows: [TodoRow] = []
        for offered in request.rows {
            let id: TodoRowID
            if let kept = offered.id { id = kept }
            else {
                guard nextID < Int.max else { throw TodoStoreError.invalid(ModelText.text(.init(rawValue: "task_cycle.identity_exhausted.v2"))) }
                nextID += 1; id = TodoRowID(rawValue: "r\(nextID)")
            }
            let previous = old?.rows.first { $0.id == id }
            let app = offered.app ?? previous?.app
            let changedCheck = offered.expected.map { $0.read != rowChecks[id]?.read } ?? false
            let reopens = previous?.status == .done && (changedCheck || app != previous?.app)
            rows.append(TodoRow(id: id, title: offered.title, app: app,
                status: reopens ? .pending : previous?.status ?? .pending,
                part: planPart(offered.part, row: id, previous: previous?.part, state: state), expected: offered.expected?.kept ?? previous?.expected))
            if let expected = offered.expected { checks[id] = expected }
        }
        for var removed in old?.rows ?? [] where !rows.contains(where: { $0.id == removed.id }) {
            removed.status = .abandoned
            rows.append(removed)
        }
        if let current = openTask {
            let base = try await TaskChannel.revision(current.revision, of: current.taskID, producer: owner, memory: memory)
            try checkPlan()
            let content = try TaskRevisionContent(goal: request.request ?? base.content.goal,
                requestedResult: base.content.requestedResult, constraints: base.content.constraints,
                inputs: request.inputs ?? base.content.inputs, messageRefs: base.content.messageRefs)
            try await chooseParts(rows, task: current, content: content, owner: owner, memory: memory, state: state)
            try checkPlan()
            let changedExpectations = Set(checks.compactMap { id, check in rowChecks[id]?.read != check.read ? id : nil })
                .union(rows.filter { row in row.expected != nil && old?.rows.first(where: { $0.id == row.id })?.app != row.app }.map(\.id))
            let revision = makeRevision(.revised(reason: request.reason), rows: rows, taskID: current.taskID,
                at: memory.clock.calendarMS(), revisedExpectations: changedExpectations)
            try Task.checkCancellation()
            if !content.isExactly(base.content) {
                let revised = try await TaskChannel.revise(current, expecting: current.revision, content: content,
                    reason: request.reason, producer: owner, memory: memory, todo: revision)
                try await planRevisionWritten?()
                try checkPlan()
                openTask = revised
                expectedTask = revised
                commit(revision, origin: .model)
            } else {
                try await TaskChannel.appendTodo(revision, memory: memory)
                try checkPlan()
                commit(revision, origin: .model)
            }
        } else {
            if stoppedReference == nil, let taskID = previousConversationTask,
               let stored = try await TaskChannel.stoppedRows(of: taskID, producer: owner, memory: memory) {
                try checkPlan()
                stoppedReference = StoppedTask(taskID: taskID, verifiedRows: stored, uncertainGesture: nil)
            } else if stoppedReference == nil, previousConversationTask == nil, producer.source == .app,
                      let stored = try await TaskChannel.stoppedTask(producer: owner, traceID: producer.traceID, memory: memory) {
                try checkPlan()
                stoppedReference = StoppedTask(taskID: stored.taskID, verifiedRows: stored.verifiedRows, uncertainGesture: nil)
            }
            try checkPlan()
            let content = try TaskRevisionContent(goal: request.request ?? "", inputs: request.inputs ?? [],
                                                 messageRefs: producer.messageRef.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
            let revision = TodoRevision(taskID: "", number: 1, change: .drafted, rows: rows,
                                        recordedAtMS: memory.clock.calendarMS())
            try Task.checkCancellation()
            let opened = try await TaskChannel.begin(content, producer: owner, traceID: producer.traceID, memory: memory, todo: revision)
            do { try checkPlan() }
            catch {
                let stopped = TodoRevision(taskID: opened.taskID, number: 2, change: .stopped,
                    rows: rows.map { row in
                        var row = row
                        row.status = .abandoned
                        return row
                    }, recordedAtMS: memory.clock.calendarMS())
                _ = try await TaskChannel.checkpoint(opened,
                    TaskCheckpointDraft(kind: .end, declared: .abandoned,
                        note: ModelText.text(.init(rawValue: "task_cycle.interrupted.v2"))),
                    producer: owner, memory: memory, todo: stopped)
                throw error
            }
            openTask = opened
            expectedTask = opened
            planGuardArmed = true
            commit(revision.forTask(opened.taskID), origin: .model)
        }
        for (id, check) in checks where rowChecks[id]?.read != check.read {
            rowOpenings.removeValue(forKey: id)
            rowExpectationTimes[id] = todoRecordedAtMS
        }
        rowChecks = checks
        if old == nil { fingerprints = inputFacts }
        else {
            for (path, facts) in inputFacts where fingerprints[path] == nil { fingerprints[path] = facts }
        }
        guard let current = openTask, let todo else { throw TodoStoreError.invalid(ModelText.text(.init(rawValue: "task_cycle.commit_missing.v2"))) }
        let base = try await TaskChannel.revision(current.revision, of: current.taskID, producer: owner, memory: memory)
        try checkPlan()
        var answer: [String: JSONValue] = ["status": .string(old == nil ? "planned" : "revised"),
            "task": .string(current.taskID), "attempt": .string(current.attemptID), "revision": .number(Double(todo.revision)),
            "rows": .array(todo.rows.map(planRowJSON))]
        let continuation = old == nil ? stoppedReference : nil
        if let previous = continuation {
            answer["continues"] = .object(["task": .string(previous.taskID),
                "verified_rows": .array(previous.verifiedRows.map(Self.rowJSON)),
                "uncertain_gesture": previous.uncertainGesture.map(JSONValue.bool) ?? .string("not_known"),
                "last_state": previous.lastState.map(JSONValue.string) ?? .null])
        }
        let offered = rowsNeedingMemory(todo.rows)
        do {
            let delivery = await deliverMemory(for: offered, content: base.content, task: current, owner: owner, memory: memory, baseAnswer: answer, state: state)
            try checkPlan()
            answer.merge(delivery, uniquingKeysWith: { _, new in new })
            if delivery["recall_error"] == nil { deliveredRows.formUnion(offered.map(\.id)) }
        }
        if continuation != nil {
            stoppedReference = nil
            previousConversationTask = nil
        }
        return .object(answer)
    }

    func currentTodo(_ memory: MemoryService) async throws -> Todo? {
        guard let openTask else { return nil }
        if let todo, todo.taskID == openTask.taskID { return todo }
        return try await TaskChannel.todo(of: openTask.taskID, memory: memory)
    }

    func cycleMemory() throws -> (MemoryService, TaskProducer) {
        guard let directory = session.memoryDirectory else {
            throw MemoryTaskTool.Failure(code: "no_memory", message: ModelText.text(.init(rawValue: "task_cycle.archive_unavailable.v2")))
        }
        return (MemoryService.shared(for: directory), try TaskProducer(source: producer.source, streamID: producer.streamID))
    }

    func makeRevision(_ change: TodoRevision.Change, rows: [TodoRow], taskID: String, at: Int64,
                      revisedExpectations: Set<TodoRowID> = []) -> TodoRevision {
        TodoRevision(taskID: taskID, number: (todo?.revision ?? 0) + 1, change: change, rows: rows,
                     attributedCalls: bufferedCalls, recordedAtMS: at, revisedExpectations: revisedExpectations)
    }

    func append(_ revision: TodoRevision, memory: MemoryService, origin: TodoEvent.Origin = .model) async throws {
        try await TaskChannel.appendTodo(revision, memory: memory)
        commit(revision, origin: origin)
    }

    func commit(_ revision: TodoRevision, origin: TodoEvent.Origin) {
        todoRecordedAtMS = revision.recordedAtMS
        let previousRows = todo?.rows ?? []
        for row in revision.rows {
            let previous = previousRows.first(where: { $0.id == row.id })
            if previous?.expected != row.expected || previous?.app != row.app {
                rowOpenings.removeValue(forKey: row.id)
                rowExpectationTimes[row.id] = revision.recordedAtMS
            }
            if row.status != .inProgress { rowOpenings.removeValue(forKey: row.id) }
        }
        todo = Todo(taskID: revision.taskID, revision: revision.number, rows: revision.rows)
        let gestures = bufferedGestures
        bufferedCalls.removeFirst(min(bufferedCalls.count, revision.attributedCalls.count))
        bufferedGestures.removeFirst(min(bufferedGestures.count, revision.attributedCalls.count))
        todoSink?(TodoEvent(revision, origin: origin, gestures: gestures, previousRows: previousRows))
    }

    func forgetDeliveredMemory() {
        deliveredRows.removeAll()
        rowMemory.removeAll()
        deliveredOffers.removeAll()
        deliveredComposition.removeAll()
        deliveredPlanParts.removeAll()
        deliveredGuideApps.removeAll()
    }

    static func rowJSON(_ row: TodoRow) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(row.id.rawValue), "title": .string(row.title),
            "status": .string(row.status.rawValue)]
        if let app = row.app { fields["app"] = .string(app) }
        if let part = row.part { fields["part"] = .string(part) }
        if let expected = row.expected { fields["expect"] = .string(expected.line) }
        return .object(fields)
    }
}
