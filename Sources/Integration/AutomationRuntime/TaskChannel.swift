//
//  TaskChannel.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation
import Memory
import SQLiteMemory

/// OpenTask is the task a producer declared and has not ended, as the producer keeps it in memory: the
/// task, the attempt its calls belong to and the revision they begin under.
nonisolated public struct OpenTask: Sendable, Equatable {

    public let taskID: String
    public let attemptID: String
    public let revision: Int

    public init(taskID: String, attemptID: String, revision: Int) {
        self.taskID    = taskID
        self.attemptID = attemptID
        self.revision  = revision
    }

    /// What a call of the task records: the attempt and the revision current when it begins.
    public var attribution: TaskCallAttribution? {
        try? TaskCallAttribution(taskID: taskID, attemptID: attemptID, revision: revision)
    }
}

/// TaskChannel is how a producer communicates its task to the living memory, over `TaskContextStoring`:
/// it draws the identities, reads the revision a change builds on, and keeps the attempt the producer
/// is in. Every answer comes after the commit; every refusal is the contract's typed error, so the
/// producer can tell the agent exactly what to do. Nothing here is inferred: the goal, the inputs, the
/// outputs and the outcome are the agent's declarations, and a call is attributed to a task only
/// because the producer had it open when the call began.
nonisolated public enum TaskChannel {

    /// Opens a task with its first revision and first attempt.
    public static func begin(_ content: TaskRevisionContent, producer: TaskProducer, traceID: String?,
                             memory: MemoryService) async throws -> OpenTask {
        let content = try await admitting(content, producer: producer, memory: memory)
        let now     = memory.clock.calendarMS()
        let taskID  = UUID().uuidString
        let attempt = UUID().uuidString
        let task = try TaskRecord(taskID: taskID, producer: producer, traceID: traceID, openedAtMS: now, status: .open,
                                  closedAtMS: nil, currentRevision: 1)
        let revision = try TaskRevision(
            taskID      : taskID,
            revision    : 1,
            recordedAtMS: now,
            change      : .opened,
            content     : content
        )
        let first = try TaskAttempt(attemptID: attempt, taskID: taskID, ordinal: 1, resumes: nil, producer: producer,
                                    openedAtMS: now, openedAtRevision: 1)
        _ = try await memory.perform { try await $0.tasks.open(task, revision: revision, attempt: first) }
        return OpenTask(taskID: taskID, attemptID: attempt, revision: 1)
    }

    /// The task's revision `number`, as stored. A revision the task does not have is one the agent did
    /// not read: `staleRevision`, with the current one, so the agent can read it again.
    public static func revision(_ number: Int, of taskID: String, producer: TaskProducer,
                                memory: MemoryService) async throws -> TaskRevision {
        guard let revision = try await memory.perform({
            try await $0.tasks.revision(number, of: taskID, for: producer)
        }) else {
            guard let task = try await memory.perform({ try await $0.tasks.task(taskID, for: producer) }) else {
                throw TaskContextError.unknownTask(taskID: taskID)
            }
            throw TaskContextError.staleRevision(taskID: taskID, expected: number, current: task.currentRevision)
        }
        return revision
    }

    /// Adds a revision after `expecting`, the revision the agent read: another current revision is
    /// `staleRevision` and changes nothing.
    public static func revise(_ open: OpenTask, expecting: Int, content: TaskRevisionContent, reason: String?,
                              producer: TaskProducer, memory: MemoryService) async throws -> OpenTask {
        let content = try await admitting(content, producer: producer, memory: memory, current: (open.taskID, []))
        let revision = try TaskRevision(
            taskID      : open.taskID,
            revision    : try TaskContextContract.successor(of: expecting, field: "revision"),
            recordedAtMS: memory.clock.calendarMS(),
            change      : .revised,
            reason      : reason,
            content     : content
        )
        _ = try await memory.perform { try await $0.tasks.revise(revision, expecting: expecting, by: producer) }
        return OpenTask(taskID: open.taskID, attemptID: open.attemptID, revision: revision.revision)
    }

    /// Records a checkpoint or the end of the open task's attempt.
    public static func checkpoint(
        _ open  : OpenTask,
        _ draft : TaskCheckpointDraft,
        producer: TaskProducer,
        memory  : MemoryService
    ) async throws -> (receipt: MemoryReceipt, checkpoint: TaskCheckpoint) {
        let targets = try await targets(of: draft.outputs.map { ($0.sourceRef, $0.sourceVersion) }, producer: producer, memory: memory,
                                        current: (open.taskID, Set(draft.outputs.map(\.name))))
        let draft = try TaskCheckpointDraft(kind: draft.kind, declared: draft.declared, note: draft.note,
                                            outputs: try TaskOutputReference.admitting(draft.outputs, targets: targets))
        let at = memory.clock.calendarMS()
        return try await memory.perform {
            try await $0.tasks.checkpoint(draft, attempt: open.attemptID, at: at, by: producer)
        }
    }

    // MARK: References

    /// The revision's content with each structural reference of its inputs kept only when it resolves (`targets`).
    static func admitting(_ content: TaskRevisionContent, producer: TaskProducer, memory: MemoryService,
                          current: (taskID: String, outputs: Set<String>)? = nil) async throws -> TaskRevisionContent {
        let targets = try await targets(of: content.inputs.map { ($0.sourceRef, $0.sourceVersion) }, producer: producer, memory: memory,
                                        current: current)
        let inputs = try TaskOutputReference.admitting(content.inputs, targets: targets)
        guard inputs != content.inputs else { return content }
        return try TaskRevisionContent(goal: content.goal, requestedResult: content.requestedResult, constraints: content.constraints,
                                       inputs: inputs, messageRefs: content.messageRefs)
    }

    /// What each task a structural reference names can vouch for, read through the producer: the outputs its checkpoints and
    /// ends declared, its attempts and its revisions. A task of another producer, or none, vouches for nothing, so a reference
    /// to it is minimized as any text: the task contract lets a producer read only its own tasks. `current` is the task being
    /// written and the outputs the statement itself declares (a checkpoint's outputs, an interpretation's).
    public static func targets(of references: [(String?, String?)], producer: TaskProducer, memory: MemoryService,
                               current: (taskID: String, outputs: Set<String>)? = nil) async throws -> [String: TaskOutputReference.Target] {
        var targets: [String: TaskOutputReference.Target] = [:]
        for taskID in TaskOutputReference.tasks(in: references) {
            let task: TaskRecord?
            do {
                task = try await memory.perform { try await $0.tasks.task(taskID, for: producer) }
            } catch TaskContextError.foreignTask {
                continue
            }
            guard let task else { continue }
            let attempts = try await memory.perform { try await $0.tasks.attempts(of: taskID, for: producer) }
            var outputs: Set<String> = current?.taskID == taskID ? current?.outputs ?? [] : []
            for attempt in attempts {
                let checkpoints = try await memory.perform { try await $0.tasks.checkpoints(of: attempt.attempt.attemptID, for: producer) }
                for checkpoint in checkpoints { outputs.formUnion(checkpoint.outputs.map(\.name)) }
            }
            targets[taskID] = TaskOutputReference.Target(outputs: outputs, attempts: Set(attempts.map(\.attempt.attemptID)),
                                                         revisions: task.currentRevision)
        }
        return targets
    }

    /// Opens a new attempt of an open task of the producer, which resumes its last attempt: that one,
    /// if still running, is marked interrupted. Nothing of the earlier attempt is replayed.
    public static func resume(
        _ taskID: String,
        producer: TaskProducer,
        memory  : MemoryService
    ) async throws -> OpenTask {
        let attempts = try await memory.perform { try await $0.tasks.attempts(of: taskID, for: producer) }
        guard let task = try await memory.perform({ try await $0.tasks.task(taskID, for: producer) }),
              let last = attempts.last else {
            throw TaskContextError.unknownTask(taskID: taskID)
        }
        if task.status.isClosed { throw TaskContextError.closed(taskID: taskID, status: task.status) }
        let ordinal = try TaskContextContract.successor(of: last.attempt.ordinal, field: "ordinal")
        let attempt = try TaskAttempt(attemptID: UUID().uuidString, taskID: taskID, ordinal: ordinal,
                                      resumes: last.attempt.attemptID, producer: producer,
                                      openedAtMS: memory.clock.calendarMS(), openedAtRevision: task.currentRevision)
        _ = try await memory.perform { try await $0.tasks.resume(attempt) }
        return OpenTask(taskID: taskID, attemptID: attempt.attemptID, revision: task.currentRevision)
    }
}
