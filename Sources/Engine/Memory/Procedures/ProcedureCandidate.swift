//
//  ProcedureCandidate.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// ProcedureSegmentation is the rule that turns an attempt's calls into the steps and blocks of a
/// procedure, the system's decision and never the agent's: one step per UI operation that started (a
/// call of `act`, `select`, the six inputs, `menu` or `press` that is not planned or skipped), in the
/// order the attempt started them; a batch is a container whose started children are the steps; the
/// context tools (`open_session`, `observe`, the listings, `close_session`) and `memory_task` are no
/// step. A block is a run of consecutive steps on one application, the application the call acted on
/// (its session's), so a passing change of focus never cuts a block and Finder, Preview, Finder is
/// three blocks. The same calls under the same version give the same steps and blocks.
public enum ProcedureSegmentation {

    /// The version of the rule, kept with every candidate it made.
    public static let policyVersion = "app-blocks-1"

    /// Call is what the rule reads of one call attributed to the attempt.
    public struct Call: Sendable, Equatable {
        public let callEventID: String
        public let tool: AgentTool
        public let status: AgentCallStatus
        public let bundleID: String?

        public init(callEventID: String, tool: AgentTool, status: AgentCallStatus, bundleID: String?) {
            self.callEventID = callEventID
            self.tool        = tool
            self.status      = status
            self.bundleID    = bundleID
        }
    }

    /// Whether a call is a step: an operation that started.
    public static func isStep(_ call: Call) -> Bool {
        call.tool.isOperation && call.status != .planned && call.status != .skipped
    }

    /// The steps of the calls, in their order, each with its block.
    public static func steps(of calls: [Call]) -> [ProcedureCandidate.Step] {
        var steps: [ProcedureCandidate.Step] = []
        for call in calls where isStep(call) {
            let block: Int
            if let previous = steps.last {
                block = EventFactText.same(previous.bundleID, call.bundleID) ? previous.blockIndex : previous.blockIndex + 1
            } else {
                block = 0
            }
            steps.append(ProcedureCandidate.Step(
                position        : steps.count,
                stepOccurrenceID: ProcedureCandidate.occurrenceID(of: call.callEventID),
                callEventID     : call.callEventID,
                blockIndex      : block,
                bundleID        : call.bundleID
            ))
        }
        return steps
    }

    /// The digest of a structure: the rule's version and every step's call, in order. Equal digests
    /// mean the same calls in the same order; a digest is a name, the steps are compared too.
    public static func digest(of steps: [ProcedureCandidate.Step]) -> String {
        var canonical = policyVersion
        for step in steps { canonical += "\n" + CanonicalText.field(step.callEventID) }
        return StructuralDigest.fnv1a(canonical)
    }
}

/// ProcedureCandidate is the segmentation of one attempt at one moment: its steps in order, each the one
/// occurrence of a started UI operation, and the blocks they fall in. It references calls and holds no
/// definition, no label and no value: nothing in it is reusable until an interpretation gives it labels
/// and parameters. Built again over the same calls it is the same candidate, by its id.
public struct ProcedureCandidate: Sendable, Equatable {

    /// Step is one step of the candidate: its position, the occurrence of its call, the call, its block
    /// and the application the call acted on.
    public struct Step: Sendable, Equatable {
        public let position: Int
        public let stepOccurrenceID: String
        public let callEventID: String
        public let blockIndex: Int
        public let bundleID: String?

        public init(position: Int, stepOccurrenceID: String, callEventID: String, blockIndex: Int, bundleID: String?) {
            self.position         = position
            self.stepOccurrenceID = stepOccurrenceID
            self.callEventID      = callEventID
            self.blockIndex       = blockIndex
            self.bundleID         = bundleID
        }

        public static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.position == rhs.position && lhs.stepOccurrenceID.utf8.elementsEqual(rhs.stepOccurrenceID.utf8)
                && lhs.callEventID.utf8.elementsEqual(rhs.callEventID.utf8) && lhs.blockIndex == rhs.blockIndex
                && EventFactText.same(lhs.bundleID, rhs.bundleID)
        }
    }

    /// Block is a run of consecutive steps on one application.
    public struct Block: Sendable, Equatable {
        public let index: Int
        public let bundleID: String?
        public let firstPosition: Int
        public let lastPosition: Int
    }

    public let candidateID: String
    public let taskID: String
    public let attemptID: String
    public let policyVersion: String
    public let structureDigest: String
    /// The checkpoint the candidate was first built at, nil when it was built without one (after an
    /// interruption, from the facts alone).
    public let checkpointSequence: Int?
    public let builtAtMS: Int64
    public let steps: [Step]

    public init(candidateID: String, taskID: String, attemptID: String, policyVersion: String, structureDigest: String,
                checkpointSequence: Int?, builtAtMS: Int64, steps: [Step]) throws {
        func refuse(_ invalidity: ProcedureError.Invalidity) -> ProcedureError { .invalid(invalidity) }
        guard !candidateID.isEmpty, !taskID.isEmpty, !attemptID.isEmpty else { throw refuse(.emptyText(field: "candidate")) }
        guard !steps.isEmpty else { throw refuse(.noSteps) }
        guard BrainClock.range.contains(builtAtMS) else { throw refuse(.outOfRange(field: "built_at_ms")) }
        for (index, step) in steps.enumerated() {
            guard step.position == index else { throw refuse(.positions(of: "steps")) }
            if index == 0 {
                guard step.blockIndex == 0 else { throw refuse(.blocks) }
            } else {
                let previous = steps[index - 1]
                let sameApp = EventFactText.same(previous.bundleID, step.bundleID)
                guard (sameApp && step.blockIndex == previous.blockIndex) || (!sameApp && step.blockIndex == previous.blockIndex + 1) else {
                    throw refuse(.blocks)
                }
            }
        }
        self.candidateID        = candidateID
        self.taskID             = taskID
        self.attemptID          = attemptID
        self.policyVersion      = policyVersion
        self.structureDigest    = structureDigest
        self.checkpointSequence = checkpointSequence
        self.builtAtMS          = builtAtMS
        self.steps              = steps
    }

    /// The candidate of an attempt's calls under the current rule; nil when no call is a step.
    public static func of(_ calls: [ProcedureSegmentation.Call], taskID: String, attemptID: String,
                          checkpointSequence: Int?, builtAtMS: Int64) throws -> ProcedureCandidate? {
        let steps = ProcedureSegmentation.steps(of: calls)
        guard !steps.isEmpty else { return nil }
        let digest = ProcedureSegmentation.digest(of: steps)
        return try ProcedureCandidate(
            candidateID       : "candidate-\(attemptID)-\(digest)",
            taskID            : taskID,
            attemptID         : attemptID,
            policyVersion     : ProcedureSegmentation.policyVersion,
            structureDigest   : digest,
            checkpointSequence: checkpointSequence,
            builtAtMS         : builtAtMS,
            steps             : steps
        )
    }

    /// The id of the occurrence of a call: one per call, whatever the candidates and versions that
    /// include it.
    public static func occurrenceID(of callEventID: String) -> String { "occurrence-\(callEventID)" }

    /// The blocks, in order.
    public var blocks: [Block] {
        var blocks: [Block] = []
        for step in steps {
            if let last = blocks.last, last.index == step.blockIndex {
                blocks[blocks.count - 1] = Block(index: last.index, bundleID: last.bundleID, firstPosition: last.firstPosition,
                                                 lastPosition: step.position)
            } else {
                blocks.append(Block(index: step.blockIndex, bundleID: step.bundleID, firstPosition: step.position,
                                    lastPosition: step.position))
            }
        }
        return blocks
    }

    /// Whether the other candidate is this one: the same id and the same steps. Its instant and the
    /// checkpoint it was first built at are not compared: a candidate built again is the stored one.
    public func hasSameStructure(as other: ProcedureCandidate) -> Bool {
        candidateID.utf8.elementsEqual(other.candidateID.utf8) && attemptID.utf8.elementsEqual(other.attemptID.utf8)
            && policyVersion.utf8.elementsEqual(other.policyVersion.utf8) && steps == other.steps
    }
}

/// ProcedureError is a procedure fact the contract or the store refuses, sorted by what the caller does
/// next. A refusal writes nothing.
public enum ProcedureError: Error, Sendable, Equatable {

    /// A value the contract cannot keep.
    case invalid(Invalidity)

    /// No candidate with this id, or not one of the producer's tasks.
    case unknownCandidate(candidateID: String)

    /// The candidate is not the attempt's latest: the agent interprets the one it was last given.
    case staleCandidate(candidateID: String, current: String)

    /// An interpretation of another content under a revision the candidate already holds.
    case conflictingInterpretation(candidateID: String, revision: Int)

    /// A revision that does not follow the candidate's last one.
    case revisionOutOfOrder(candidateID: String, expected: Int)

    /// What the interpretation names is not in the candidate or its calls: a step, a block, an argument.
    case unknownReference(String)

    /// No part with this id.
    case unknownPart(partID: String)

    /// A part's operational state cannot move this way: nothing follows retirement.
    case retired(partID: String)

    /// A variant's declared common prefix is contradicted by the operations at this step (from 0): the
    /// two versions do not do the same there.
    case contradictedPrefix(step: Int, why: String)

    /// A stored row the contract does not admit.
    case malformedRow(table: String, id: String, problem: String)

    public enum Invalidity: Sendable, Equatable {
        case emptyText(field: String)
        case tooLong(field: String)
        case tooMany(field: String)
        case duplicate(field: String)
        case outOfRange(field: String)
        case positions(of: String)
        case blocks
        case noSteps
        case template(String)
        case parameter(String)
        case label(String)
    }
}
