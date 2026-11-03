import AutomationRuntime
import Foundation
import EngineCore
import LocalMCP
import Memory
import os

/// StepTransition reports the row checked before a gesture starts its next subprocedure.
struct StepTransition: Sendable, Equatable {
    let finished: TodoRowID?
    let verdict: TodoRevision.RowVerdict?
    let started: TodoRowID
}

extension TaskCycleHandler {
    func step(to row: TodoRowID?, gesture: String) async throws -> StepTransition? {
        guard TaskCycleArm.current == .v2, let row else { return nil }
        guard let task = openTask else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "task_cycle.step_open.v2")), cause: "unknown_step")
        }
        let (memory, owner) = try cycleMemory()
        guard let current = try await currentTodo(memory),
              let next = current.rows.first(where: { $0.id == row }), next.status != .abandoned, next.status != .done else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "task_cycle.step_open.v2")), cause: "unknown_step")
        }
        let active = current.rows.first { $0.status == .inProgress }
        guard active?.id != row else { return nil }
        let nextPending = current.rows.first { $0.status == .pending }
        guard nextPending?.id == row else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "task_cycle.step_order.v2")), cause: "plan_revision_required")
        }
        var verdict: TodoRevision.RowVerdict?
        if let active {
            verdict = try await rowVerdict(active, task: task, owner: owner, memory: memory)
            let rows = current.rows.map { row -> TodoRow in
                var row = row
                if row.id == active.id { row.status = .done }
                return row
            }
            let revision = makeRevision(.rowFinished(active.id, verdict: verdict), rows: rows,
                                        taskID: task.taskID, at: memory.clock.calendarMS())
            try await append(revision, memory: memory)
        }
        let rows = (todo?.rows ?? current.rows).map { item -> TodoRow in
            var item = item
            if item.id == row { item.status = .inProgress }
            return item
        }
        let openedAtMS = memory.clock.calendarMS()
        let opening = await readRowOpening(next, at: openedAtMS)
        try await append(makeRevision(.rowStarted(row), rows: rows, taskID: task.taskID,
                                      at: openedAtMS), memory: memory)
        rowOpenings[row] = opening
        return StepTransition(finished: active?.id, verdict: verdict, started: row)
    }

    func readRowOpening(_ row: TodoRow, at instant: Int64) async -> RowOpening? {
        guard let expected = rowChecks[row.id]?.read ?? row.expected else { return nil }
        let before: TaskResultCheck.FileFacts?
        if let path = expected.path { before = await ProcedureProducer.readingOffMain(path: path) }
        else { before = nil }
        return RowOpening(expectation: expected, openedAtMS: instant, before: before)
    }

    func rowVerdict(_ row: TodoRow, task: OpenTask, owner: TaskProducer,
                    memory: MemoryService) async throws -> TodoRevision.RowVerdict {
        guard let expected = rowChecks[row.id]?.read ?? row.expected else { return .unknown }
        let checked: TaskResultCheck
        if let path = expected.path {
            let opening = rowOpenings[row.id].flatMap { $0.expectation == expected ? $0 : nil }
            let instant: Int64
            if let opening { instant = opening.openedAtMS }
            else if let revised = rowExpectationTimes[row.id] { instant = revised }
            else {
                let revisions: [TodoRevision]
                do { revisions = try await TaskChannel.todoRevisions(of: task.taskID, memory: memory) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let detail = producerSecrets.recordMinimization.minimize(text: MemoryService.describe(error)).0
                    let notice = ModelText.render(.init(rawValue: "expect.rowReadFailed"), ["detail": .minimized(detail)])
                    if let presentation = CallDispatcher.presentation { presentation.notices.append(notice) }
                    else { stoppedTaskNotice = [stoppedTaskNotice, notice].compactMap { $0 }.joined(separator: "\n") }
                    return .unknown
                }
                var previous: TaskResultCheck.Expectation?
                var added: Int64?
                for revision in revisions {
                    let current = revision.rows.first(where: { $0.id == row.id })?.expected
                    if current != previous { added = revision.recordedAtMS; previous = current }
                }
                guard let added else { return .unknown }
                instant = added
            }
            var text: String?
            if case .fileContains(_, let wanted) = expected { text = wanted }
            let now = await ProcedureProducer.readingOffMain(path: path, holding: text)
            let other: TaskResultCheck.FileFacts?
            switch expected {
            case .fileMoved(_, let to), .fileCopied(_, let to): other = await ProcedureProducer.readingOffMain(path: to)
            default: other = nil
            }
            checked = TaskResultCheck.judge(expected, attemptID: task.attemptID, openedAtMS: instant,
                before: opening?.before, now: now, other: other, window: .row)
        } else {
            let reading: TaskResultCheck.Reading
            switch expected {
            case .window(let app, _, _): reading = await windowReading(of: app)
            case .element(let app, _, _): reading = .screen(windows: nil, scene: await currentScene(of: app))
            default: reading = .nothing
            }
            let shown = producerSecrets.shownMinimization
            checked = ScreenExpectation.$valueIsReadable.withValue({ value in
                value != ValueMinimization.marker && shown.minimize(text: value).1 == nil
            }) {
                TaskResultCheck.judge(expected, attemptID: task.attemptID, openedAtMS: 0, reading: reading)
            }
        }
        return TodoRevision.RowVerdict(rawValue: checked.verdict.rawValue) ?? .unknown
    }

    func noteGesture(eventID: String, outcome: String, uncertain: Bool) {
        guard TaskCycleArm.current == .v2, let row = todo?.rows.first(where: { $0.status == .inProgress }) else { return }
        guard !bufferedCalls.contains(where: { $0.eventID == eventID }) else { return }
        bufferedCalls.append(CallAttribution(eventID: eventID, row: row.id))
        bufferedGestures.append(TodoGesture(eventID: eventID, row: row.id, outcome: outcome))
        lastGestureUncertain = uncertain
    }

    func end(_ request: EndRequest) async throws -> JSONValue {
        try requireUninterruptedEnd(request)
        guard let task = openTask else {
            throw MemoryTaskTool.Failure(code: "no_open_task", message: ModelText.text(.init(rawValue: "task_cycle.end_without_task.v2")))
        }
        let (memory, owner) = try cycleMemory()
        guard let current = try await currentTodo(memory) else { throw TodoStoreError.invalid(ModelText.text(.init(rawValue: "task_cycle.plan_missing.v2"))) }
        let checks = request.outcome == .completed
            ? Self.completed(request.checks, fingerprints: fingerprints, outputs: .null, minimization: producerSecrets.recordMinimization)
            : request.checks
        let checked = checks.isEmpty ? nil : await check(checks, attemptID: task.attemptID, producer: owner, memory: memory)
        let evidence = Self.completionEvidence(checks, checked: checked)
        let endCheck = TaskEndCheck(verdict: evidence["checks"].string.flatMap(TodoRevision.RowVerdict.init(rawValue:)) ?? .unknown,
            scope: evidence["scope"].string.flatMap(TaskEndCheck.Scope.init(rawValue:)) ?? .declaredPredicatesOnly)
        let active = current.rows.first { $0.status == .inProgress }
        let verdict = if let active { try await rowVerdict(active, task: task, owner: owner, memory: memory) } else { TodoRevision.RowVerdict.unknown }
        let rows = current.rows.map { item -> TodoRow in
            var item = item
            if item.status == .inProgress { item.status = request.outcome == .completed ? .done : .abandoned }
            else if item.status == .pending { item.status = .abandoned }
            return item
        }
        let change: TodoRevision.Change = active.map { .rowFinished($0.id, verdict: verdict) } ?? .revised(reason: nil)
        let revision = makeRevision(change, rows: rows, taskID: task.taskID, at: memory.clock.calendarMS())
        try requireUninterruptedEnd(request)
        guard openTask == task else { throw CancellationError() }
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: request.outcome, note: request.note),
            producer: owner, memory: memory, todo: revision, endCheck: endCheck)
        commit(revision, origin: .model)
        openTask = nil
        todo = nil
        rowChecks.removeAll()
        rowOpenings.removeAll()
        rowExpectationTimes.removeAll()
        forgetDeliveredMemory()
        planGuardArmed = true
        gesturesWithoutPlan = 0
        var answer: [String: JSONValue] = ["status": .string("ended"), "task": .string(task.taskID),
            "outcome": .string(request.outcome.rawValue), "completion_evidence": evidence]
        if let checked { answer["result_check"] = checked }
        if access.learns, request.outcome == .completed {
            do {
                if let summary = try await ProcedureProducer.candidate(attemptID: task.attemptID, producer: owner, memory: memory),
                   !interpretedCandidates.contains(summary.candidate.candidateID) {
                    pendingCandidate = summary.candidate.candidateID
                }
            } catch { answer["candidate_error"] = .string(MemoryService.describe(error)) }
        } else { pendingCandidate = nil }
        return .object(answer)
    }

    func requireUninterruptedEnd(_ request: EndRequest) throws {
        guard request.outcome != .completed || interruptedProducer == nil else {
            throw MemoryTaskTool.Failure(code: "task_interrupted",
                message: ModelText.text(.init(rawValue: "task_cycle.interrupted.v2")))
        }
    }

    func closeStoppedTask(_ cause: StopCause) async throws -> StoppedTask? {
        guard let task = openTask else { return nil }
        if TaskCycleArm.current == .v1 {
            markTaskInterrupted(producer: producer)
            try await finishInterruptedTask()
            return StoppedTask(taskID: task.taskID, verifiedRows: [], uncertainGesture: nil)
        }
        markTaskInterrupted(producer: producer)
        let (memory, _) = try cycleMemory()
        let source = interruptedProducer ?? producer
        let owner = try TaskProducer(source: source.source, streamID: source.streamID)
        guard let current = try await TaskChannel.todo(of: task.taskID, memory: memory) else { throw TodoStoreError.invalid(ModelText.text(.init(rawValue: "task_cycle.stopped_plan_missing.v2"))) }
        let verified = try await TaskChannel.verifiedRows(of: task.taskID, memory: memory)
        let key: String
        switch cause {
        case .person: key = "task_cycle.stop_note.v2"
        case .signal: key = "task_cycle.stop_signal.v2"
        case .conversationEnded: key = "task_cycle.stop_conversation.v2"
        }
        let note = ModelText.text(.init(rawValue: key))
        let reference = StoppedTask(taskID: task.taskID, verifiedRows: verified,
            uncertainGesture: lastGestureUncertain, lastState: note)
        let rows = current.rows.map { item -> TodoRow in
            var item = item
            if item.status == .pending || item.status == .inProgress { item.status = .abandoned }
            return item
        }
        let revision = TodoRevision(taskID: task.taskID, number: current.revision + 1, change: .stopped,
            rows: rows, attributedCalls: bufferedCalls, recordedAtMS: memory.clock.calendarMS())
        let draft = try TaskCheckpointDraft(kind: .end, declared: .abandoned, note: note)
        _ = try await TaskChannel.checkpoint(task, draft, producer: owner, memory: memory, todo: revision)
        commit(revision, origin: .braus)
        openTask = nil
        todo = nil
        rowChecks.removeAll()
        rowOpenings.removeAll()
        rowExpectationTimes.removeAll()
        forgetDeliveredMemory()
        pendingCandidate = nil
        stoppedReference = reference
        interruptedProducer = nil
        gesturesWithoutPlan = 0
        stoppedTaskNotice = ModelText.text(.init(rawValue: "task_cycle.stopped.v2"))
        planGuardArmed = true
        try formatter.transcribe("Braus stopped task", .object(["task": .string(task.taskID), "outcome": .string("abandoned")]))
        return reference
    }

    func planFirstRefusal(for tool: String) -> String? {
        guard TaskCycleArm.current == .v2, openTask == nil, planGuardArmed,
              gesturesWithoutPlan >= guardThreshold.gesturesBeforePlan else { return nil }
        return ModelText.render(.init(rawValue: "task_cycle.first.v2"), ["tool": .toolName("plan")])
    }

    /// Reports interpretation errors explicitly without converting a completed user turn into a failed task.
    func afterTurn() async {
        guard access.learns else { pendingCandidate = nil; return }
        guard TaskCycleArm.current == .v2, let candidate = pendingCandidate else { return }
        do {
            let (memory, owner) = try cycleMemory()
            guard let stated = try await ProcedureProducer.brausInterpretation(candidateID: candidate, producer: owner, memory: memory) else { return }
            var arguments: [String: JSONValue] = ["operation": .string("interpret"), "candidate": .string(candidate),
                "procedure": .object(["label": .string(stated.label), "outcome": .string("completed")])]
            if !stated.phases.isEmpty {
                arguments["phases"] = .array(stated.phases.map { phase in
                    .object(["from": .number(Double(phase.first + 1)), "to": .number(Double(phase.last + 1)), "label": .string(phase.label)])
                })
            }
            _ = try await taskAnswer(.object(arguments))
        } catch {
            let diagnostic = producerSecrets.withheld(MemoryService.describe(error))
            Logger(subsystem: "dev.forte.Braus", category: "TaskCycle").error("Task interpretation failed: \(diagnostic, privacy: .private)")
        }
    }
}
