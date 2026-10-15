//
//  ProcedureProducer.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import CryptoKit
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
        /// Runs of the candidate's steps that hold the method of a phase learned in other procedures, with its label
        /// (`ProcedureFamilies.knownPhases`): what the agent is offered so that procedures share phases and labels.
        public var knownPhases: [ProcedureFamilies.KnownPhase] = []
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
        var built = try await summary(of: candidate, isNew: receipt == .committed, memory: memory)
        built.knownPhases = (try? await memory.perform { try await $0.procedures.knownPhases(candidateID: candidate.candidateID) }) ?? []
        return built
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

    /// The largest file whose content a result check reads to compare it with the start: above it, size and time of last
    /// writing stand for the content.
    public static let digestLimit: Int64 = 256 << 20

    /// The largest text file a check of what it holds reads.
    public static let textLimit: Int64 = 8 << 20

    /// The most names a folder's listing keeps.
    public static let listingLimit = 5_000

    /// What the disk says of a path now, as a result check reads it (`TaskResultCheck.FileFacts`): whether something is
    /// there, when it was last written, its size, the SHA-256 of a file up to `digestLimit`, and whether a text file up
    /// to `textLimit` holds `text`. Read only.
    public static func read(path: String, holding text: String? = nil) -> TaskResultCheck.FileFacts {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        let modified = (attributes[.modificationDate] as? Date).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            // A folder is listed by its files' names, hidden ones left out, up to `listingLimit`.
            let names = attributes[.type] as? FileAttributeType == .typeDirectory
                ? (try? FileManager.default.contentsOfDirectory(atPath: path)).map { names in
                    Array(names.filter { !$0.hasPrefix(".") }.sorted().prefix(listingLimit)) } : nil
            return TaskResultCheck.FileFacts(exists: true, modifiedAtMS: modified, size: size, listing: names)
        }
        var digest: String?
        if let size, size <= digestLimit, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var holds: Bool?
        if let text, let size, size <= textLimit, let data = FileManager.default.contents(atPath: path) {
            let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            holds = content.map { $0.contains(text) || $0.precomposedStringWithCanonicalMapping.contains(text.precomposedStringWithCanonicalMapping) }
        }
        return TaskResultCheck.FileFacts(exists: true, modifiedAtMS: modified, size: size, digest: digest, holdsText: holds)
    }

    /// Records Braus's check of one thing an attempt says its result is, from what was read (`TaskResultCheck`): the
    /// disk for a file, read here at `read`'s path with `before` as the reading from the task's beginning, or the screen
    /// as the caller read it. `read` is the expectation as the agent gave it, judged and never stored; `kept` is the one
    /// the archive keeps, minimized. The attempt's current version is qualified again.
    public static func checkResult(_ kept: TaskResultCheck.Expectation, read: TaskResultCheck.Expectation,
                                   before: TaskResultCheck.FileFacts? = nil, screen: TaskResultCheck.Reading? = nil,
                                   asGuard: Bool = false, attemptID: String, producer: TaskProducer,
                                   memory: MemoryService) async throws -> TaskResultCheck {
        let reading: TaskResultCheck.Reading
        if let path = read.path {
            var text: String?
            if case .fileContains(_, let wanted) = read { text = wanted }
            var other: TaskResultCheck.FileFacts?
            switch read {
                case .fileMoved(_, let to), .fileCopied(_, let to): other = Self.read(path: to)
                default: break
            }
            reading = .disk(before: before, now: Self.read(path: path, holding: text), other: other)
        } else {
            reading = screen ?? .nothing
        }
        let now = memory.clock.calendarMS()
        return try await memory.perform {
            try await $0.procedures.recordResult(kept, judgedAs: read, reading: reading, asGuard: asGuard, attemptID: attemptID,
                                                 eventID: UUID().uuidString, by: producer, at: now)
        }
    }

    /// BrausInterpretation is what Braus states of a candidate the agent left uninterpreted: the procedure's label and
    /// phases, by the candidate's positions.
    public struct BrausInterpretation: Sendable, Equatable {
        public let label: String
        public let phases: [(first: Int, last: Int, label: String)]

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.label == rhs.label && lhs.phases.elementsEqual(rhs.phases) { $0 == $1 }
        }
    }

    /// The interpretation Braus makes of a completed task's candidate that the agent left uninterpreted after it was
    /// reminded (review I1, 14 October 2026; BUG-11: Haiku answered the person and nothing of a completed task was learned):
    /// the task's goal as the procedure's label, and the phases other procedures learned where the candidate's steps hold
    /// them (`ProcedureFamilies.knownPhases`), the first of overlapping ones. It names no step and no parameter: the version's
    /// assembly infers the uses the calls show (`InferredUses`), and the qualification decides as for any interpretation,
    /// so a step is offered alone only when an agent named it. Nil for a candidate not of a completed task of the producer.
    public static func brausInterpretation(candidateID: String, producer: TaskProducer,
                                           memory: MemoryService) async throws -> BrausInterpretation? {
        guard let candidate = try await memory.perform({ try await $0.procedures.candidate(candidateID) }),
              let task = try await memory.perform({ try await $0.tasks.task(candidate.taskID, for: producer) }),
              task.status == .completed,
              let revision = try await memory.perform({ try await $0.tasks.revision(task.currentRevision, of: task.taskID, for: producer) })
        else { return nil }
        let goal = revision.content.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        let known = (try? await memory.perform { try await $0.procedures.knownPhases(candidateID: candidateID) }) ?? []
        var phases: [(first: Int, last: Int, label: String)] = []
        var last = -1
        for phase in known.sorted(by: { ($0.firstPosition, -$0.lastPosition) < ($1.firstPosition, -$1.lastPosition) })
        where phase.firstPosition > last {
            phases.append((phase.firstPosition, phase.lastPosition, phase.label))
            last = phase.lastPosition
        }
        return BrausInterpretation(label: goal, phases: phases)
    }

    /// The attempt of a candidate of one of the producer's tasks and whether a result of it was checked already; nil for
    /// a candidate the producer does not own.
    public static func resultState(candidateID: String, producer: TaskProducer,
                                   memory: MemoryService) async throws -> (attemptID: String, checked: Bool)? {
        guard let candidate = try await memory.perform({ try await $0.procedures.candidate(candidateID) }),
              try await memory.perform({ try await $0.tasks.task(candidate.taskID, for: producer) }) != nil else { return nil }
        let read = try await memory.perform { try await $0.procedures.hasReadResult(ofAttempt: candidate.attemptID) }
        return (candidate.attemptID, read)
    }

    /// Whether Braus read the attempt's result: a check that read something, neither a guard nor a `none`.
    public static func hasReadResult(attemptID: String, memory: MemoryService) async throws -> Bool {
        try await memory.perform { try await $0.procedures.hasReadResult(ofAttempt: attemptID) }
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
