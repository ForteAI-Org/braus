//
//  ProcedureInspection.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// ProcedureInspection is what a developer reads of one task by its id, from one snapshot of the
/// archive: every attempt with its calls in the order they started and what each one is to the
/// procedures (a step and its occurrence, a batch's container, a step never started, a context tool),
/// how each call's check judged it and what it taught the Brain, the candidates and the versions built
/// from them with their parts, contracts, parameters, bindings and qualifications, the relations the
/// task's calls proved or contradicted, and what each attempt asked the Recall and was given back: the
/// proposals, the choice that answered each with its validated query, the calls linked to what was
/// delivered and the uses the agent declared. It is a diagnosis by identity: it reads what is stored and
/// selects nothing; it is not a recall.
public struct ProcedureInspection: Sendable {

    /// CallRole is what one call of an attempt is to the procedures.
    public enum CallRole: String, Sendable, Equatable {
        /// A started UI operation: one step, one occurrence.
        case step
        /// A batch, a container whose started children are the steps.
        case container
        /// A batch's step that never started.
        case skipped
        /// A planned operation that never started outside a batch, a context tool, or a `menu` that only
        /// listed a menu's items and pressed nothing.
        case context
    }

    /// Call is one call of an attempt.
    public struct Call: Sendable {
        public let callEventID: String
        public let position: Int
        public let tool: AgentTool
        public let status: AgentCallStatus
        public let bundleID: String?
        public let parentEventID: String?
        public let role: CallRole
        public let stepOccurrenceID: String?
        /// The check its path reported, `condition verdict`, nil when none was saved.
        public let check: String?
        /// What it taught the relations, `outcome` or `excluded:reason`, nil when not applied.
        public let brain: String?

        public init(callEventID: String, position: Int, tool: AgentTool, status: AgentCallStatus, bundleID: String?,
                    parentEventID: String?, role: CallRole, stepOccurrenceID: String?, check: String?, brain: String?) {
            self.callEventID      = callEventID
            self.position         = position
            self.tool             = tool
            self.status           = status
            self.bundleID         = bundleID
            self.parentEventID    = parentEventID
            self.role             = role
            self.stepOccurrenceID = stepOccurrenceID
            self.check            = check
            self.brain            = brain
        }
    }

    /// Attempt is one attempt with its calls, candidates and versions, and what it asked the Recall: the
    /// proposals it was given to choose from and the queries made for it, each as stored.
    public struct Attempt: Sendable {
        public let attempt: StoredTaskAttempt
        public let calls: [Call]
        public let candidates: [ProcedureCandidate]
        public let versions: [StoredProcedureVersion]
        /// The proposals the attempt was given, in the order they were recorded, each with its choice when one answered it.
        public var proposals: [Proposal] = []
        /// The queries made for the attempt, in the order they were recorded: a choice's validated query, or one made
        /// without a proposal (the selector's, under a test's control).
        public var queries: [Query] = []

        public init(attempt: StoredTaskAttempt, calls: [Call], candidates: [ProcedureCandidate], versions: [StoredProcedureVersion]) {
            self.attempt    = attempt
            self.calls      = calls
            self.candidates = candidates
            self.versions   = versions
        }
    }

    /// Counts keeps apart what is counted: operational steps (one per started UI operation), the
    /// containers and the skipped steps that are no step, the context calls, the parts admitted and
    /// refused under their latest evaluation, and the archive's Routes that are no version of D2 (legacy).
    public struct Counts: Sendable, Equatable {
        public let operationalSteps: Int
        public let containers: Int
        public let skipped: Int
        public let contextCalls: Int
        public let candidates: Int
        public let versions: Int
        public let admittedParts: Int
        public let refusedParts: Int
        /// The parts the catalogue offers now: admitted under a policy still active, usable, current.
        public let offeredParts: Int
        public let legacyRoutes: Int
        /// The Recall's side: the proposals given, how many of them were chosen, the queries made and the uses declared.
        public var proposals = 0
        public var choices = 0
        public var queries = 0
        public var useReports = 0

        public init(operationalSteps: Int, containers: Int, skipped: Int, contextCalls: Int, candidates: Int, versions: Int,
                    admittedParts: Int, refusedParts: Int, offeredParts: Int, legacyRoutes: Int) {
            self.operationalSteps = operationalSteps
            self.containers       = containers
            self.skipped          = skipped
            self.contextCalls     = contextCalls
            self.candidates       = candidates
            self.versions         = versions
            self.admittedParts    = admittedParts
            self.refusedParts     = refusedParts
            self.offeredParts     = offeredParts
            self.legacyRoutes     = legacyRoutes
        }
    }

    // MARK: The Recall's side, as stored

    /// Proposal is one proposal the attempt was given to choose from: what was asked and how the search went, the needs
    /// and the sources shortlisted for each, and the choice that answered it when one did. Texts are the agent's, as
    /// stored (minimized when recorded); the codes are the archive's words.
    public struct Proposal: Sendable, Equatable {
        public let proposalID: String
        public let revision: Int
        public let reason: String
        public let remainingWork: String
        public let channel: String
        public let searchStatus: String
        public let searchNote: String?
        public let candidatesConsidered: Int
        public let bytes: Int
        public let durationUS: Int64?
        public let recordedAtMS: Int64
        public let needs: [ProposedNeed]
        public let sources: [ProposedSource]
        public let choice: Choice?

        public init(proposalID: String, revision: Int, reason: String, remainingWork: String, channel: String, searchStatus: String,
                    searchNote: String?, candidatesConsidered: Int, bytes: Int, durationUS: Int64?, recordedAtMS: Int64,
                    needs: [ProposedNeed], sources: [ProposedSource], choice: Choice?) {
            self.proposalID           = proposalID
            self.revision             = revision
            self.reason               = reason
            self.remainingWork        = remainingWork
            self.channel              = channel
            self.searchStatus         = searchStatus
            self.searchNote           = searchNote
            self.candidatesConsidered = candidatesConsidered
            self.bytes                = bytes
            self.durationUS           = durationUS
            self.recordedAtMS         = recordedAtMS
            self.needs                = needs
            self.sources              = sources
            self.choice               = choice
        }
    }

    /// ProposedNeed is one need of a proposal, from 0, with the application it was resolved to when the agent named one.
    public struct ProposedNeed: Sendable, Equatable {
        public let position: Int
        public let text: String
        public let bundleID: String?

        public init(position: Int, text: String, bundleID: String?) {
            self.position = position
            self.text     = text
            self.bundleID = bundleID
        }
    }

    /// ProposedSource is one source shortlisted for a need: its name in the proposal, the version it is, its relevance and
    /// the steps the selector would have suggested, when it suggested any.
    public struct ProposedSource: Sendable, Equatable {
        public let needPosition: Int
        public let position: Int
        public let key: String
        public let routeID: String
        public let relevance: Double
        public let suggestedFirst: Int?
        public let suggestedLast: Int?

        public init(needPosition: Int, position: Int, key: String, routeID: String, relevance: Double, suggestedFirst: Int?,
                    suggestedLast: Int?) {
            self.needPosition   = needPosition
            self.position       = position
            self.key            = key
            self.routeID        = routeID
            self.relevance      = relevance
            self.suggestedFirst = suggestedFirst
            self.suggestedLast  = suggestedLast
        }
    }

    /// Choice is the agent's admitted plan for a proposal: the query Engine validated and delivered for it, and what the
    /// agent declared per need.
    public struct Choice: Sendable, Equatable {
        public let queryID: String
        public let recordedAtMS: Int64
        public let needs: [ChosenNeed]

        public init(queryID: String, recordedAtMS: Int64, needs: [ChosenNeed]) {
            self.queryID     = queryID
            self.recordedAtMS = recordedAtMS
            self.needs       = needs
        }
    }

    /// ChosenNeed is what the agent declared of one need: covered all, part, none or ambiguous, what stays uncovered,
    /// and the person's words that settled a choice between fixed alternatives.
    public struct ChosenNeed: Sendable, Equatable {
        public let position: Int
        public let declared: String
        public let uncovered: String?
        public let settledBy: String?

        public init(position: Int, declared: String, uncovered: String?, settledBy: String?) {
            self.position  = position
            self.declared  = declared
            self.uncovered = uncovered
            self.settledBy = settledBy
        }
    }

    /// Query is one query made for the attempt: the search and what it delivered, the proposal it answered when it did,
    /// and per need the tracts selected, the calls linked to them and the uses declared.
    public struct Query: Sendable, Equatable {
        public let queryID: String
        public let revision: Int
        public let reason: String
        public let remainingWork: String
        public let channel: String
        public let searchStatus: String
        public let searchNote: String?
        public let candidateLimit: Int
        public let candidatesConsidered: Int
        public let coverage: String
        public let delivery: String
        public let deliveryBytes: Int?
        public let selectorVersion: String
        public let recordedAtMS: Int64
        public let durationUS: Int64?
        public let proposalID: String?
        public let needs: [QueriedNeed]

        public init(queryID: String, revision: Int, reason: String, remainingWork: String, channel: String, searchStatus: String,
                    searchNote: String?, candidateLimit: Int, candidatesConsidered: Int, coverage: String, delivery: String,
                    deliveryBytes: Int?, selectorVersion: String, recordedAtMS: Int64, durationUS: Int64?, proposalID: String?,
                    needs: [QueriedNeed]) {
            self.queryID              = queryID
            self.revision             = revision
            self.reason               = reason
            self.remainingWork        = remainingWork
            self.channel              = channel
            self.searchStatus         = searchStatus
            self.searchNote           = searchNote
            self.candidateLimit       = candidateLimit
            self.candidatesConsidered = candidatesConsidered
            self.coverage             = coverage
            self.delivery             = delivery
            self.deliveryBytes        = deliveryBytes
            self.selectorVersion      = selectorVersion
            self.recordedAtMS         = recordedAtMS
            self.durationUS           = durationUS
            self.proposalID           = proposalID
            self.needs                = needs
        }
    }

    /// QueriedNeed is one need of a query with its coverage, the tracts selected or kept as alternatives, the calls
    /// linked to them and the uses the agent declared.
    public struct QueriedNeed: Sendable, Equatable {
        public let position: Int
        public let text: String
        public let bundleID: String?
        public let coverage: String
        public let reason: String?
        public let selections: [Selection]
        public let links: [Link]
        public let reports: [Use]

        public init(position: Int, text: String, bundleID: String?, coverage: String, reason: String?, selections: [Selection],
                    links: [Link], reports: [Use]) {
            self.position   = position
            self.text       = text
            self.bundleID   = bundleID
            self.coverage   = coverage
            self.reason     = reason
            self.selections = selections
            self.links      = links
            self.reports    = reports
        }
    }

    /// Selection is one tract of a need: selected, an alternative or excluded, the version and its steps, and what was
    /// required to deliver it, counted by kind (`parameter_bound`, `entry_state`, …).
    public struct Selection: Sendable, Equatable {
        public let position: Int
        public let role: String
        public let routeID: String
        public let firstPosition: Int
        public let lastPosition: Int
        public let wholePartID: String?
        public let relevance: Double
        public let preparations: Int
        public let requirements: [String: Int]

        public init(position: Int, role: String, routeID: String, firstPosition: Int, lastPosition: Int, wholePartID: String?,
                    relevance: Double, preparations: Int, requirements: [String: Int]) {
            self.position      = position
            self.role          = role
            self.routeID       = routeID
            self.firstPosition = firstPosition
            self.lastPosition  = lastPosition
            self.wholePartID   = wholePartID
            self.relevance     = relevance
            self.preparations  = preparations
            self.requirements  = requirements
        }
    }

    /// Link is one call of the attempt linked to a need: the tract and step it carried out when one was determined,
    /// whether its check confirmed it, or whether that is undetermined.
    public struct Link: Sendable, Equatable {
        public let callEventID: String
        public let selectionPosition: Int?
        public let stepPosition: Int?
        public let confirmed: Bool
        public let undetermined: Bool

        public init(callEventID: String, selectionPosition: Int?, stepPosition: Int?, confirmed: Bool, undetermined: Bool) {
            self.callEventID       = callEventID
            self.selectionPosition = selectionPosition
            self.stepPosition      = stepPosition
            self.confirmed         = confirmed
            self.undetermined      = undetermined
        }
    }

    /// Use is one use the agent declared of a need's selection: followed, adapted, abandoned or not executed, with the
    /// cause it named and its note.
    public struct Use: Sendable, Equatable {
        public let sequence: Int
        public let declared: String
        public let cause: String?
        public let note: String?

        public init(sequence: Int, declared: String, cause: String?, note: String?) {
            self.sequence = sequence
            self.declared = declared
            self.cause    = cause
            self.note     = note
        }
    }

    public let task: TaskRecord
    public let goal: String
    public let attempts: [Attempt]
    /// The relations the task's calls proved or contradicted, with their proofs counted.
    public let relations: [BrainRelation]
    /// The parts of the task's versions the catalogue offers now.
    public let offeredPartIDs: Set<String>
    public let counts: Counts

    public init(task: TaskRecord, goal: String, attempts: [Attempt], relations: [BrainRelation], offeredPartIDs: Set<String>,
                counts: Counts) {
        self.task           = task
        self.goal           = goal
        self.attempts       = attempts
        self.relations      = relations
        self.offeredPartIDs = offeredPartIDs
        self.counts         = counts
    }

    /// The same objects as lines of text, by id. No value of a parameter is printed: a binding says
    /// where its value came from and whether it is held, a literal typed text says only its length, so a
    /// diagnosis copied into a report carries no value the agent typed. The goal and the labels are
    /// printed as the agent stated them.
    public var text: [String] {
        var lines: [String] = []
        lines.append("task \(task.taskID) by \(task.producer.source.rawValue): \(task.status.rawValue), revision \(task.currentRevision)")
        lines.append("  goal: \(goal)")
        for attempt in attempts {
            let stored = attempt.attempt
            lines.append("attempt \(stored.attempt.ordinal) \(stored.attempt.attemptID): \(stored.status.rawValue)"
                         + (stored.attempt.resumes.map { ", resumes \($0)" } ?? ""))
            for call in attempt.calls {
                var line = "  call \(call.position) \(call.tool.rawValue) \(call.status.rawValue) on \(call.bundleID ?? "no app") — \(call.role.rawValue)"
                if let parent = call.parentEventID { line += " of \(parent)" }
                if let occurrence = call.stepOccurrenceID { line += ", \(occurrence)" }
                if let check = call.check { line += "; check \(check)" }
                if let brain = call.brain { line += "; brain \(brain)" }
                lines.append(line + "  [\(call.callEventID)]")
            }
            lines += Self.describe(attempt.proposals, attempt.queries)
            for candidate in attempt.candidates {
                lines.append("  candidate \(candidate.candidateID) (\(candidate.policyVersion)): \(candidate.steps.count) steps in "
                             + "\(candidate.blocks.count) blocks "
                             + candidate.blocks.map { "\($0.bundleID ?? "no app") \($0.firstPosition)–\($0.lastPosition)" }
                                 .joined(separator: ", ")
                             + (candidate.checkpointSequence.map { ", checkpoint \($0)" } ?? ", from the facts alone"))
            }
            for stored in attempt.versions { lines += Self.describe(stored, offered: offeredPartIDs) }
        }
        if !relations.isEmpty { lines.append("relations the task's calls proved or contradicted:") }
        for relation in relations {
            lines.append("  \(relation.summary) from state \(relation.key.fromSceneID.prefix(8)) on \(relation.key.elementKey ?? "the context"): "
                         + "\(relation.supports) proofs, \(relation.contradictions) contradictions, \(relation.standing.rawValue)  [\(relation.relationID)]")
        }
        let counted = counts
        lines.append("operational steps \(counted.operationalSteps) (containers \(counted.containers), skipped \(counted.skipped), "
                     + "context \(counted.contextCalls) are no step); candidates \(counted.candidates), versions \(counted.versions); "
                     + "parts admitted \(counted.admittedParts), refused \(counted.refusedParts), offered \(counted.offeredParts); "
                     + "legacy Routes in the archive \(counted.legacyRoutes); "
                     + "Recall: proposals \(counted.proposals), chosen \(counted.choices), queries \(counted.queries), uses \(counted.useReports)")
        return lines
    }

    /// A range of steps as stored, from 0 like every step of this diagnosis, with the numbers the agent saw in the
    /// proposal and gave in its choice, from 1.
    private static func steps(_ first: Int, _ last: Int) -> String {
        "steps \(first)–\(last) (\(first + 1)–\(last + 1) as proposed)"
    }

    /// The Recall's side of one attempt as lines: each proposal with its needs, sources and choice, then each query with
    /// its needs, tracts, linked calls and uses. Relevances are printed to three decimals; durations in milliseconds.
    private static func describe(_ proposals: [Proposal], _ queries: [Query]) -> [String] {
        var lines: [String] = []
        for proposal in proposals {
            lines.append("  proposal \(proposal.proposalID) rev \(proposal.revision), \(proposal.reason): \(proposal.channel) \(proposal.searchStatus)"
                         + (proposal.searchNote.map { " (\($0))" } ?? "")
                         + ", \(proposal.candidatesConsidered) candidates considered, \(proposal.needs.count) needs, "
                         + "\(proposal.sources.count) sources, \(proposal.bytes) bytes"
                         + (proposal.durationUS.map { ", \($0 / 1000) ms" } ?? ""))
            lines.append("    remaining: \(proposal.remainingWork)")
            for need in proposal.needs {
                let sources = proposal.sources.filter { $0.needPosition == need.position }
                lines.append("    need \(need.position + 1) \"\(need.text)\"" + (need.bundleID.map { " on \($0)" } ?? "")
                             + ": \(sources.count) sources")
                for source in sources {
                    lines.append("      source \(source.key) = \(source.routeID), relevance \(String(format: "%.3f", source.relevance))"
                                 + (source.suggestedFirst.map { first in
                                     ", suggested " + Self.steps(first, source.suggestedLast ?? first) } ?? ""))
                }
            }
            if let choice = proposal.choice {
                lines.append("    chosen → query \(choice.queryID): " + choice.needs.map { need in
                    "need \(need.position + 1) \(need.declared)"
                        + (need.settledBy.map { " settled by \"\($0)\"" } ?? "")
                        + (need.uncovered.map { ", uncovered \"\($0)\"" } ?? "")
                }.joined(separator: "; "))
            } else {
                lines.append("    not chosen")
            }
        }
        for query in queries {
            lines.append("  query \(query.queryID) rev \(query.revision), \(query.reason)"
                         + (query.proposalID.map { " of proposal \($0)" } ?? " (no proposal)")
                         + ": \(query.channel) \(query.searchStatus)" + (query.searchNote.map { " (\($0))" } ?? "")
                         + ", coverage \(query.coverage), \(query.delivery)" + (query.deliveryBytes.map { " \($0) bytes" } ?? "")
                         + ", \(query.candidatesConsidered)/\(query.candidateLimit) candidates, selector \(query.selectorVersion)"
                         + (query.durationUS.map { ", \($0 / 1000) ms" } ?? ""))
            for need in query.needs {
                lines.append("    need \(need.position + 1) \"\(need.text)\"" + (need.bundleID.map { " on \($0)" } ?? "")
                             + ": \(need.coverage)" + (need.reason.map { " (\($0))" } ?? ""))
                for selection in need.selections {
                    let requirements = selection.requirements.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
                        .joined(separator: ", ")
                    lines.append("      \(selection.role) \(selection.routeID) " + Self.steps(selection.firstPosition, selection.lastPosition)
                                 + (selection.wholePartID.map { " (whole \($0))" } ?? "")
                                 + ", relevance \(String(format: "%.3f", selection.relevance))"
                                 + (selection.preparations > 0 ? ", \(selection.preparations) preparations" : "")
                                 + (requirements.isEmpty ? "" : "; " + requirements))
                }
                if !need.links.isEmpty {
                    lines.append("      linked calls \(need.links.count): \(need.links.filter(\.confirmed).count) confirmed, "
                                 + "\(need.links.filter(\.undetermined).count) undetermined; "
                                 + need.links.map { link in
                                     link.callEventID + (link.stepPosition.map { " → step \($0)" } ?? " → no step")
                                 }.joined(separator: ", "))
                }
                for use in need.reports {
                    lines.append("      use \(use.sequence): \(use.declared)" + (use.cause.map { ", cause \($0)" } ?? "")
                                 + (use.note.map { ", \($0)" } ?? ""))
                }
            }
        }
        return lines
    }

    private static func describe(_ stored: StoredProcedureVersion, offered: Set<String>) -> [String] {
        let version = stored.version
        var lines = ["  version \(version.routeID) revision \(version.revision) of \(version.candidateID): "
                     + "interpreted while \(stored.interpretationState.rawValue), \(stored.isCurrent ? "current" : "superseded")"
                     + (version.variantOf.map { ", variant of \($0) from step \(version.divergencePosition ?? 0)" } ?? "")
                     + (version.variantOf == nil ? "" : stored.variantPrefix.map { check in
                         ", prefix \(check.status.rawValue) over \(check.comparedSteps) steps" + (check.reason.map { " (\($0.rawValue))" } ?? "")
                     } ?? ", prefix not checked")]
        for finding in version.findings {
            lines.append("    finding \(finding.kind.rawValue) at step \(finding.stepPosition)")
        }
        let depth: [PartKind: String] = [.procedure: "    ", .subprocedure: "      ", .step: "        "]
        for part in version.parts {
            let qualification = stored.qualifications[part.partID]
            let verdict = qualification.map { qualified in
                qualified.verdict.rawValue + (qualified.findings.isEmpty ? ""
                    : " (" + qualified.findings.map { $0.reason.rawValue + ($0.stepPosition.map { " @\($0)" } ?? "") }
                        .joined(separator: ", ") + ")")
            } ?? "not qualified"
            let state = (stored.states[part.partID].map { ", \($0.rawValue)" } ?? "")
                + (offered.contains(part.partID) ? ", offered" : ", not offered")
            lines.append("\(depth[part.kind] ?? "    ")\(part.kind.rawValue) \(part.label ?? "(unlabelled)") steps \(part.firstPosition)–\(part.lastPosition)"
                         + " on \(part.bundleID ?? "several apps"), declared \(part.declaredOutcome.rawValue): \(verdict)\(state)  [\(part.partID)]")
        }
        let names = Dictionary(version.definition.parameters.map { ($0.parameterID, $0.name) }, uniquingKeysWith: { first, _ in first })
        for step in version.definition.steps {
            for operation in step.operations {
                let arguments = operation.arguments.map { argument in
                    "\(argument.name)=" + Self.describe(argument, names: names)
                }
                lines.append("    step \(step.position) \(operation.tool.rawValue)(\(arguments.joined(separator: ", ")))")
            }
        }
        let details = Dictionary(version.parameterDetails.map { ($0.parameterID, $0) }, uniquingKeysWith: { first, _ in first })
        for parameter in version.definition.parameters {
            let detail = details[parameter.parameterID]
            let bound = version.bindings.filter { $0.parameterID == parameter.parameterID }.map { binding in
                let held = switch binding.content {
                    case .text: "held"
                    case .missing: "missing"
                    case .withheld: "withheld"
                }
                return "\(binding.source.rawValue)\(binding.sourceRef.map { " \($0)" } ?? ""): \(held)"
            }
            lines.append("    parameter \(parameter.name) \(parameter.direction.rawValue) \(parameter.valueType.rawValue)"
                         + (parameter.isRequired ? " required" : "")
                         + (detail.map { ", role \($0.role), \($0.kind.rawValue), \($0.sensitivity.rawValue)" } ?? "")
                         + (bound.isEmpty ? "" : "; bound from " + bound.joined(separator: "; ")))
        }
        for item in stored.contract {
            lines.append("    contract \(item.kind.rawValue) of \(item.partID)"
                         + (item.parameterID.map { " \(names[$0] ?? $0)" } ?? "")
                         + (item.bundleID.map { " \($0)" } ?? "")
                         + (item.kind == .entryState ? item.sceneID.map { " state \($0.prefix(8))" } ?? " state unknown" : "")
                         + (item.kind == .entryState && item.sceneID == nil
                            ? stored.lateEntryStates[item.partID].map { " when built; known since: state \($0.prefix(8))" } ?? "" : ""))
        }
        return lines
    }

    /// An argument as the procedure holds it: a parameter or a template by its names, a literal typed
    /// text by its length only, any other literal as it is.
    private static func describe(_ argument: OperationArgument, names: [String: String]) -> String {
        switch argument.value {
            case .parameter(let id): return "{\(names[id] ?? id)}"
            case .template(let segments):
                return "\"" + segments.map { segment in
                    switch segment {
                        case .literal(let text): text
                        case .parameter(let id): "{\(names[id] ?? id)}"
                    }
                }.joined() + "\""
            case .anchor(let key): return "anchor \(key.prefix(8))"
            case .menu(let path): return "menu \"\(path)\""
            case .literal(let value):
                switch value {
                    case .text(let text) where ["text", "expected_value"].contains(argument.name): return "text of \(text.count) characters"
                    case .text(let text): return "\"\(text)\""
                    case .integer(let number): return "\(number)"
                    case .real(let number): return "\(number)"
                    case .boolean(let flag): return "\(flag)"
                }
        }
    }

    /// One graph of the same objects, as Mermaid: Memory's containment (procedure, subprocedures,
    /// steps, solid) apart from the order of the steps (dotted), each step bound to the call it stands
    /// for, and the Brain's relations between states (labelled with the verb and the outcome; a state
    /// may lead to itself). Every node and edge is a stored row named by its id; nothing is drawn that
    /// a query does not return.
    public var graph: String {
        var lines = ["flowchart LR"]
        var nodes: [String: String] = [:]
        func node(_ id: String, _ label: String, shape: (String, String) = ("[", "]")) -> String {
            if let known = nodes[id] { return known }
            let name = "n\(nodes.count)"
            nodes[id] = name
            let text = label.replacingOccurrences(of: "\"", with: "'")
            lines.append("  \(name)\(shape.0)\"\(text)\"\(shape.1)")
            return name
        }
        for attempt in attempts {
            for stored in attempt.versions {
                let version = stored.version
                for part in version.parts {
                    let verdict = stored.qualifications[part.partID]?.verdict.rawValue ?? "unqualified"
                    _ = node(part.partID, "\(part.kind.rawValue): \(part.label ?? "(unlabelled)") [\(verdict)]")
                }
                for part in version.parts {
                    guard let parent = part.parentPartID, let from = nodes[parent], let to = nodes[part.partID] else { continue }
                    lines.append("  \(from) --> \(to)")
                }
                let steps = version.parts.filter { $0.kind == .step }.sorted { $0.firstPosition < $1.firstPosition }
                for (previous, next) in zip(steps, steps.dropFirst()) {
                    guard let from = nodes[previous.partID], let to = nodes[next.partID] else { continue }
                    lines.append("  \(from) -.-> \(to)")
                }
            }
        }
        for relation in relations {
            let from = node("state:" + relation.key.fromSceneID, "state \(relation.key.fromSceneID.prefix(8))", shape: ("((", "))"))
            let to = node("state:" + (relation.key.toSceneID ?? "unknown"),
                          relation.key.toSceneID.map { "state \($0.prefix(8))" } ?? "unknown state", shape: ("((", "))"))
            let label = "\(relation.key.verb.rawValue) \(relation.key.outcome.rawValue) ×\(relation.supports)"
                + (relation.contradictions > 0 ? " ✗\(relation.contradictions)" : "")
            lines.append("  \(from) -- \"\(label)\" --> \(to)")
        }
        return lines.joined(separator: "\n")
    }

    /// The edges the graph draws, by kind, for a reader that compares them with the rows: containment
    /// (one per part with a parent), order (one per pair of consecutive steps of a version) and relation
    /// (one per relation).
    public var edgeCounts: (containment: Int, order: Int, relations: Int) {
        var containment = 0, order = 0
        for attempt in attempts {
            for stored in attempt.versions {
                containment += stored.version.parts.filter { $0.parentPartID != nil }.count
                order += max(0, stored.version.parts.filter { $0.kind == .step }.count - 1)
            }
        }
        return (containment, order, relations.count)
    }
}
