import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

extension TaskCycleHandler {
    func taskAnswer(_ arguments: JSONValue) async throws -> JSONValue {
        guard let directory = session.memoryDirectory else {
            throw MemoryTaskTool.Failure(
                code   : "no_memory",
                message: "This session has no memory: nothing about tasks is recorded."
            )
        }
        let memory   = MemoryService.shared(for: directory)
        let producer = try TaskProducer(source: self.producer.source, streamID: self.producer.streamID)
        let request  = try MemoryTaskTool.decode(arguments == .null ? .object([:]) : arguments,
                                                 minimization: producerSecrets.recordMinimization,
                                                 messageRef: self.producer.messageRef)
        func open(_ task: OpenTask, _ status: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            .object(["status": .string(status), "task": .string(task.taskID), "attempt": .string(task.attemptID),
                     "revision": .number(Double(task.revision))].merging(extra, uniquingKeysWith: { $1 }))
        }
        func keep(_ more: [String]) { for text in more where !producerSecrets.secrets.contains(text) { producerSecrets.secrets.append(text) } }
        switch request {
            case .begin(let content, let declared, let plan):
                if let current = openTask {
                    throw MemoryTaskTool.Failure(
                        code   : "task_already_open",
                        message: "A task is already open: update it, or end it "
                            + "before beginning another.",
                        details: ["task": .string(current.taskID)]
                    )
                }
                keep(declared)
                fingerprints = await Self.fingerprints(of: arguments["inputs"])
                let opened = try await TaskChannel.begin(
                    content,
                    producer: producer,
                    traceID : self.producer.traceID,
                    memory  : memory
                )
                openTask = opened
                // The preparation before any operation: the memory searched once for what serves the task.
                guard let plan else { return open(opened, "begun") }
                if plan.propose {
                    return open(opened, "begun", await propose(.initial, plan, content: content, task: opened, producer: producer, memory: memory))
                }
                return open(opened, "begun", await recall(.initial, plan, content: content, task: opened, producer: producer,
                                                          memory: memory))
            case .update(let update, let declared):
                guard let current = openTask else { throw Self.noOpenTask }
                keep(declared)
                let expecting = update.expecting ?? current.revision
                let base      = try await TaskChannel.revision(
                    expecting,
                    of      : current.taskID,
                    producer: producer,
                    memory  : memory
                )
                let content   = try update.applied(
                    to        : base.content,
                    messageRef: self.producer.messageRef.flatMap { $0.isEmpty ? nil : $0 }
                )
                let revised   = try await TaskChannel.revise(
                    current,
                    expecting: expecting,
                    content  : content,
                    reason   : update.reason,
                    producer : producer,
                    memory   : memory
                )
                openTask = revised
                for (path, facts) in await Self.fingerprints(of: arguments["inputs"]) where fingerprints[path] == nil { fingerprints[path] = facts }
                return open(revised, "revised")
            case .checkpoint(let draft, let declared, let uses, let checks), .end(let draft, let declared, let uses, let checks):
                guard let current = openTask else { throw Self.noOpenTask }
                keep(declared)
                let (reported, useProblems) = await report(uses, task: current, memory: memory)
                // The result the task names is read by Braus before the checkpoint or the end is recorded: the procedure's
                // admission, and its phases', rest on it (`QualificationPolicy` version B).
                // At a completed end Braus completes what the task named with what it can read on disk itself
                // (`AutomationTools.completed`).
                var checks = checks
                if case .end(let draft, _, _, _) = request, draft.declared == .completed {
                    checks = Self.completed(checks, fingerprints: fingerprints, outputs: arguments["outputs"],
                                            minimization: producerSecrets.recordMinimization)
                }
                let checkedResult: JSONValue? = checks.isEmpty ? nil
                    : await check(checks, attemptID: current.attemptID, producer: producer, memory: memory)
                let (receipt, checkpoint) = try await TaskChannel.checkpoint(
                    current,
                    draft,
                    producer: producer,
                    memory  : memory
                )
                let recorded: JSONValue = .string(receipt == .committed ? "recorded" : "already recorded")
                var extra: [String: JSONValue] = ["recorded": recorded]
                if let used = await linked(current, producer: producer, memory: memory) { extra["recall_use"] = used }
                if reported > 0 { extra["use_reported"] = .number(Double(reported)) }
                if !useProblems.isEmpty { extra["use_not_recorded"] = .array(useProblems.map(JSONValue.string)) }
                // The checkpoint is saved whatever the candidate: a candidate that cannot be built now is
                // built again from the same facts by `candidate` or the next checkpoint.
                do {
                    if let summary = try await ProcedureProducer.candidate(attemptID: current.attemptID, producer: producer,
                                                                           memory: memory) {
                        extra["candidate"] = Self.candidate(summary)
                        let candidateID = summary.candidate.candidateID
                        if !interpretedCandidates.contains(candidateID) {
                            pendingCandidate = candidateID
                            extra["next"] = .string(Self.interpretNext(candidateID))
                        }
                    }
                } catch {
                    extra["candidate_error"] = .string(MemoryService.describe(error))
                }
                if draft.kind == .end {
                    openTask = nil
                    extra["outcome"] = .string(checkpoint.declared?.rawValue ?? "")
                    if let checkedResult {
                        extra["result_check"] = checkedResult
                    } else if checkpoint.declared == .completed,
                              !((try? await ProcedureProducer.hasReadResult(attemptID: current.attemptID, memory: memory)) ?? false) {
                        // A result read at a checkpoint is the attempt's result: nothing is missing then.
                        extra["result_check"] = .object(["status": .string("missing"), "next": .string(Self.resultMissing)])
                    }
                    if checkpoint.declared == .completed {
                        extra["completion_evidence"] = Self.completionEvidence(checks, checked: checkedResult)
                    }
                    extra["before_answering"] = .string(Self.closeChangedCopies)
                    return open(current, "ended", extra)
                }
                extra["sequence"] = .number(Double(checkpoint.sequence))
                if let checkedResult { extra["result_check"] = checkedResult }
                return open(current, "checkpointed", extra)
            case .resume(let taskID):
                if let current = openTask, current.taskID != taskID {
                    throw MemoryTaskTool.Failure(
                        code   : "task_already_open",
                        message: "Another task is open: end it before "
                            + "resuming this one.",
                        details: ["task": .string(current.taskID)]
                    )
                }
                let (resumed, unfinished) = try await TaskChannel.resume(taskID, producer: producer, memory: memory)
                openTask = resumed
                var extra: [String: JSONValue] = [
                    "guidance": .string("A new attempt began. Observe the present state before acting: nothing of "
                        + "the earlier attempt is replayed.")
                ]
                if !unfinished.isEmpty {
                    // A call whose end the archive never got may have run (M06): said, never repeated.
                    extra["unfinished_calls"] = .array(unfinished.map { call in
                        .object(["event": .string(call.eventID), "tool": .string(call.tool),
                                 "started_at": call.startedAtMS.map { .number(Double($0)) } ?? .null])
                    })
                    let calls = unfinished.count == 1 ? "1 call" : "\(unfinished.count) calls"
                    extra["guidance"] = .string("A new attempt began. The earlier attempts left \(calls) without an "
                        + "end: each may have run, or still be running. Observe its effect in the present state before "
                        + "acting, and do not repeat it: nothing of the earlier attempts is replayed.")
                }
                return open(resumed, "resumed", extra)
            case .candidate(let taskID):
                guard let summary = try await ProcedureProducer.candidate(taskID: taskID, producer: producer, memory: memory) else {
                    return .object(["status": .string("no candidate"), "task": .string(taskID),
                                    "message": .string("The task's last attempt started no app action.")])
                }
                return .object(["status": .string("candidate"), "task": .string(taskID), "candidate": Self.candidate(summary)])
            case .interpret(let interpretation, let declared, let checks):
                keep(declared)
                // A result the end did not name, read now, before the version is built and qualified on it.
                var checkedResult: JSONValue?
                if !checks.isEmpty, let state = try await ProcedureProducer.resultState(candidateID: interpretation.candidateID,
                                                                                         producer: producer, memory: memory) {
                    if !state.checked {
                        let completed = Self.completed(checks, fingerprints: fingerprints, outputs: .null,
                                                       minimization: producerSecrets.recordMinimization)
                        checkedResult = await check(completed, attemptID: state.attemptID, producer: producer, memory: memory)
                    } else {
                        checkedResult = .object(["status": .string("already checked"),
                                                 "message": .string("The attempt's result was checked before: nothing more was read.")])
                    }
                }
                let outcome = try await ProcedureProducer.interpret(interpretation, producer: producer, memory: memory)
                interpretedCandidates.insert(interpretation.candidateID)
                if pendingCandidate == interpretation.candidateID { pendingCandidate = nil }
                // The version and its qualification are committed with their index work: the worker takes it now.
                await RecallService.shared(for: memory).schedule()
                var answer = Self.interpreted(outcome, candidateID: interpretation.candidateID)
                if let checkedResult, case .object(var fields) = answer {
                    fields["result_check"] = checkedResult
                    answer = .object(fields)
                }
                return answer
            case .recall(let reason, let plan):
                guard let current = openTask else { throw Self.noOpenTask }
                let revision = try await TaskChannel.revision(current.revision, of: current.taskID, producer: producer, memory: memory)
                if plan.propose {
                    return open(current, "proposed", await propose(reason, plan, content: revision.content, task: current, producer: producer,
                                                                   memory: memory))
                }
                return open(current, "recalled", await recall(reason, plan, content: revision.content, task: current,
                                                              producer: producer, memory: memory))
            case .choose(let plan):
                guard let current = openTask else { throw Self.noOpenTask }
                let revision = try await TaskChannel.revision(current.revision, of: current.taskID, producer: producer, memory: memory)
                do {
                    let answer = try await RecallService.shared(for: memory).choose(
                        plan, taskID: current.taskID, attemptID: current.attemptID, revision: current.revision,
                        values: revision.content.inputs, constraints: revision.content.constraints, producer: producer)
                    let data = try JSONEncoder().encode(answer.delivery)
                    return open(current, answer.recordedNow ? "chosen" : "already chosen",
                                ["recall": try JSONDecoder().decode(JSONValue.self, from: data)])
                } catch let refusal as RecallChoice.Refusal {
                    throw MemoryTaskTool.Failure(code: refusal.code.rawValue,
                                                 message: "The plan was not admitted; nothing was recorded or run: "
                                                    + refusal.problems.joined(separator: "; ") + ".",
                                                 details: ["problems": .array(refusal.problems.map(JSONValue.string))])
                } catch let error as MemoryStoreError where Self.isChoiceRecordFault(error) {
                    // The archive refused the choice's own record: an internal error of the experiment, not the memory's
                    // unavailability. The task's facts are untouched and the memory is not suspended.
                    throw MemoryTaskTool.Failure(code: "choice_not_recorded",
                                                 message: "Braus could not record this choice (\(MemoryService.describe(error))): nothing was "
                                                    + "recorded or delivered, and this call ran no app action. Plan with the current scene "
                                                    + "and tools, or propose again.")
                }
            case .reconcile(let call, let finding, let evidence, let note):
                let owned = try await memory.unresolvedCalls(source: producer.source, streamID: producer.streamID,
                                                             excludingExecutor: nil)
                guard owned.contains(where: { $0.eventID == call }) else {
                    throw MemoryTaskTool.Failure(code: "not_reconciled", message: "The call is not unresolved in this producer stream.")
                }
                // The store checks successful read evidence, resource identity and compatible data context.
                let fact = try CallReconciliation(callEventID: call, kind: .observed, finding: finding, evidenceEventID: evidence,
                                                  declaredBy: .agent, recordedAtMS: memory.clock.calendarMS(), detail: note)
                do {
                    try await memory.reconcile(fact)
                } catch {
                    throw MemoryTaskTool.Failure(code: "not_reconciled", message: "The reconciliation was not recorded "
                        + "(\(MemoryService.describe(error))): use a successful read of this effect and resource in the same "
                        + "producer and data context. Unsupported or inconclusive evidence leaves the call unresolved.")
                }
                let left = await unresolvedCalls(memory: memory)
                return .object(["status": .string("reconciled"), "call": .string(call), "finding": .string(finding.rawValue),
                                "unresolved_calls": .array(left.map(Self.unresolvedJSON))])
            case .use(let uses):
                guard let current = openTask else { throw Self.noOpenTask }
                let (reported, useProblems) = await report(uses, task: current, memory: memory)
                // A call that only reports uses and recorded none of them failed.
                if reported == 0, let problem = useProblems.first { throw MemoryTaskTool.Failure(code: "unknown_query", message: problem) }
                var extra: [String: JSONValue] = ["use_reported": .number(Double(reported))]
                if !useProblems.isEmpty { extra["use_not_recorded"] = .array(useProblems.map(JSONValue.string)) }
                if let used = await linked(current, producer: producer, memory: memory) { extra["recall_use"] = used }
                return open(current, "use recorded", extra)
            case .status:
                let suspended = await memory.status().suspended
                var answer: [String: JSONValue] = ["status": .string(openTask == nil ? "no open task" : "open")]
                if let current = openTask {
                    answer["task"] = .string(current.taskID)
                    answer["attempt"] = .string(current.attemptID)
                    answer["revision"] = .number(Double(current.revision))
                }
                if let suspended { answer["memory"] = .string("suspended: \(suspended)") }
                // What this process records into and recalls with, as it resolved them: for a run's preflight, which needs the
                // process's own archive and configuration, not a value set in a shell.
                answer["archive"] = .string(memory.url.path)
                let recall = await RecallService.shared(for: memory).identity()
                answer["recall"] = .object(["channel": .string(recall.channel), "model": recall.model.map(JSONValue.string) ?? .null,
                                            "models_folder": recall.modelsFolder.map(JSONValue.string) ?? .null,
                                            "format": .string(recall.format), "owns_index": .bool(recall.ownsIndex),
                                            "model_state": .string(recall.modelState)])
                // A measure's control names what it turned off, so the run proves it from the process; absent otherwise.
                let ablation = MeasureAblation.active
                if !ablation.isEmpty {
                    let named: [(MeasureAblation, String)] = [(.recall, "recall"), (.brain, "brain")]
                    answer["measure_ablation"] = .array(named.filter { ablation.contains($0.0) }.map { .string($0.1) })
                }
                return .object(answer)
        }
    }
}
