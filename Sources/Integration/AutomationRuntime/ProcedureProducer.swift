//
//  ProcedureProducer.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import Memory
import SQLiteMemory

/// ProcedureProducer turns a producer's task into the procedures the living memory keeps, at the points
/// of the task's own cycle: after a checkpoint or the end the agent declared, the candidate of the
/// attempt is built from the facts the archive confirmed (never from the agent's account), and handed
/// back to the agent with what it needs to interpret it; the agent's interpretation then builds a
/// version, qualified part by part. The app's workers, its external MCP clients and `braus chat` reach it
/// through `memory_task`, so the same contract serves them all. Every write is a transaction of the
/// archive; nothing here waits for a model or acts on an application.
nonisolated public enum ProcedureProducer {

    /// How long a build waits for the derived queue (the scene associations the entry states come from)
    /// before it reads the facts. A state not associated in time is recorded as not known.
    public static let associationBudget: Duration = .seconds(2)

    /// StepSummary is one step of a candidate as the agent reads it: its number and block from 1, the
    /// application, the tool, the arguments as the archive kept them (withheld values as the marker), how
    /// the call ended and how its check judged it.
    public struct StepSummary: Sendable {
        public let number: Int
        public let block: Int
        public let bundleID: String?
        public let tool: AgentTool
        public let arguments: [BrainArgument]
        public let status: AgentCallStatus
        public let condition: OperationCheck.Condition?
        public let verdict: OperationCheck.Verdict?
    }

    /// CandidateSummary is a candidate as the agent reads it.
    public struct CandidateSummary: Sendable {
        public let candidate: ProcedureCandidate
        public let steps: [StepSummary]
        public let isNew: Bool
    }

    /// The candidate of the attempt now, after the derived queue drained within its budget, with what
    /// the agent needs to interpret it; nil when the attempt started no UI operation. The attempt's
    /// current version is evaluated again from the facts now, so an end declared since, or a call that
    /// concluded since, is reflected in its parts' qualification.
    public static func candidate(attemptID: String, producer: TaskProducer, memory: MemoryService) async throws -> CandidateSummary? {
        await memory.flush(within: associationBudget)
        let now = memory.clock.calendarMS()
        guard let (receipt, candidate) = try await memory.perform({
            try await $0.procedures.buildCandidate(attemptID: attemptID, for: producer, at: now)
        }) else { return nil }
        _ = try await memory.perform { try await $0.procedures.requalifyCurrent(attemptID: attemptID, at: now) }
        return try await summary(of: candidate, isNew: receipt == .committed, memory: memory)
    }

    /// The candidate of the last attempt of one of the producer's tasks, built again from the facts: for an
    /// agent that lost the one it was given, or a task interrupted before any checkpoint.
    public static func candidate(taskID: String, producer: TaskProducer, memory: MemoryService) async throws -> CandidateSummary? {
        let attempts = try await memory.perform { try await $0.tasks.attempts(of: taskID, for: producer) }
        guard let last = attempts.last else {
            guard try await memory.perform({ try await $0.tasks.task(taskID, for: producer) }) != nil else {
                throw TaskContextError.unknownTask(taskID: taskID)
            }
            return nil
        }
        return try await candidate(attemptID: last.attempt.attemptID, producer: producer, memory: memory)
    }

    /// Records the agent's interpretation of a candidate and builds its version with the qualification of
    /// every part.
    public static func interpret(_ interpretation: ProcedureInterpretation, producer: TaskProducer,
                                 memory: MemoryService) async throws -> InterpretationOutcome {
        let interpretation = try await admitting(interpretation, producer: producer, memory: memory)
        let now = memory.clock.calendarMS()
        return try await memory.perform { try await $0.procedures.interpret(interpretation, by: producer, at: now) }
    }

    /// The interpretation with each structural reference of its parameters kept only when it resolves: to an output of an
    /// earlier task of the producer, or of the candidate's own task, as its checkpoints or this interpretation declare it.
    static func admitting(_ interpretation: ProcedureInterpretation, producer: TaskProducer,
                          memory: MemoryService) async throws -> ProcedureInterpretation {
        let references = interpretation.parameters.map { ($0.sourceRef, $0.sourceVersion) }
        guard !TaskOutputReference.tasks(in: references).isEmpty else { return interpretation }
        let candidate = try await memory.perform { try await $0.procedures.candidate(interpretation.candidateID) }
        let declared = Set(interpretation.parameters.filter { $0.direction != .input }.map(\.name))
        let targets = try await TaskChannel.targets(of: references, producer: producer, memory: memory,
                                                    current: candidate.map { ($0.taskID, declared) })
        let parameters = try TaskOutputReference.admitting(interpretation.parameters, targets: targets)
        guard parameters != interpretation.parameters else { return interpretation }
        return try ProcedureInterpretation(candidateID: interpretation.candidateID, revision: interpretation.revision,
                                           parts: interpretation.parts, parameters: parameters, uses: interpretation.uses,
                                           variantOf: interpretation.variantOf, divergencePosition: interpretation.divergencePosition)
    }

    private static func summary(of candidate: ProcedureCandidate, isNew: Bool, memory: MemoryService) async throws -> CandidateSummary {
        var steps: [StepSummary] = []
        for step in candidate.steps {
            guard let call = try await memory.perform({ try await $0.calls.call(step.callEventID) }) else {
                throw ProcedureError.unknownReference("call \(step.callEventID)")
            }
            let check = try await memory.perform { try await $0.facts.verifications(of: step.callEventID) }.first?.check
            steps.append(StepSummary(number: step.position + 1, block: step.blockIndex + 1, bundleID: step.bundleID,
                                     tool: call.request.tool, arguments: call.request.arguments, status: call.progress.status,
                                     condition: check?.condition, verdict: check?.verdict))
        }
        return CandidateSummary(candidate: candidate, steps: steps, isNew: isNew)
    }
}
