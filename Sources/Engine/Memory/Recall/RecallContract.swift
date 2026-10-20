//
//  RecallContract.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallContract is the versioned contract of the Recall: what an agent asks for a task, what the Engine
/// answers, and the limits it declares. A query names the task and its revision, why it is made, the work that
/// remains and the needs it splits into; the answer separates how far the search went from what it covered, and
/// carries, per need, the one selection proposed with everything it requires. Nothing here reads a chat: the
/// agent resolves the request from its conversation and states it in the task.
public enum RecallContract {
    public static let version = 1

    /// The selection rules' version, recorded with every query so a result can be traced to its rules.
    public static let selectorVersion = "recall-selector-5"

    /// The most needs one query may name: more is refused, not cut.
    public static let maximumNeeds = 8

    /// The candidates of each need the search considers before selecting, at most: a declared limit of the
    /// search's perimeter, never a proof that nothing else exists.
    public static let candidateLimit = 48

    /// The largest answer a tool result carries, in UTF-8 bytes of its JSON: the channel's technical limit.
    /// Details that would exceed it are not delivered and the answer says so; nothing is cut silently.
    public static let channelLimitBytes = 262_144
}

/// RecallReason is why a query is made: the preparation before the task's operations, or a reason the agent
/// records for a later one (the request changed, an input changed, a new important need, or the path in hand
/// cannot be used). An update of the Brain, a parameter resolved or a switch of application are no reason.
public enum RecallReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case initial
    case requestChanged = "request_changed"
    case inputChanged   = "input_changed"
    case newNeed        = "new_need"
    case pathUnusable   = "path_unusable"
}

/// RecallNeed is one sub-result the agent needs, in its own words, with the application it must happen in when
/// the request imposes one. A query with no need named searches for the remaining work as one need.
public struct RecallNeed: Sendable, Equatable {
    public let text: String
    public let bundleID: String?

    public init(text: String, bundleID: String? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskContextError.invalid(.emptyText(field: "need"))
        }
        guard text.utf8.count <= TaskContextContract.maximumTextBytes else { throw TaskContextError.invalid(.tooLong(field: "need")) }
        self.text     = text
        self.bundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A need from a text its request already checked: non-empty and within the contract's bound.
    fileprivate init(checked text: String) {
        self.text     = text
        self.bundleID = nil
    }
}

/// ObservedState is the functional state the latest observation of a task's session showed: an application and its
/// structural scene, read from the facts, never declared by the agent.
public struct ObservedState: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let sceneID: String

    public init(bundleID: String, sceneID: String) {
        self.bundleID = bundleID
        self.sceneID  = sceneID
    }
}

/// RecallRequest is one query as the producer offers it: the task, attempt and revision it serves, why it is made,
/// the remaining work, the needs, the task's values (its inputs, the outputs of earlier work that are ready, the
/// values still missing), its constraints, and the applications the request imposes. The values are bound to
/// what is selected by name and role; they are never searched with. `notes` are what the request's boundary could not
/// settle and the answer must say, such as an application a need named that could not be resolved.
public struct RecallRequest: Sendable {
    public let taskID: String
    public let attemptID: String
    public let revision: Int
    public let reason: RecallReason
    public let remainingWork: String
    public let needs: [RecallNeed]
    public let values: [TaskValue]
    public let constraints: [String]
    public let notes: [String]

    public init(taskID: String, attemptID: String, revision: Int, reason: RecallReason, remainingWork: String, needs: [RecallNeed] = [],
                values: [TaskValue] = [], constraints: [String] = [], notes: [String] = []) throws {
        guard !remainingWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskContextError.invalid(.emptyText(field: "remaining"))
        }
        guard remainingWork.utf8.count <= TaskContextContract.maximumTextBytes else {
            throw TaskContextError.invalid(.tooLong(field: "remaining"))
        }
        guard needs.count <= RecallContract.maximumNeeds else { throw TaskContextError.invalid(.tooMany(field: "needs")) }
        self.taskID        = taskID
        self.attemptID     = attemptID
        self.revision      = revision
        self.reason        = reason
        self.remainingWork = remainingWork
        self.needs         = needs
        self.values        = values
        self.constraints   = constraints
        self.notes         = notes
    }

    /// The needs searched: the ones named, or the remaining work as the only one.
    public var searchedNeeds: [RecallNeed] {
        needs.isEmpty ? [RecallNeed(checked: remainingWork)] : needs
    }
}

/// RecallChannel is which index answered: the semantic one, the lexical one, both combined, or none.
public enum RecallChannel: String, Sendable, Equatable, Hashable, CaseIterable {
    case semantic, lexical, hybrid, none
}

/// SearchStatus is how far a search went, apart from what it found: completed within its declared perimeter,
/// limited (a backlog, a channel unavailable while another answered, the candidate limit reached), unavailable
/// (no index could answer), or failed. Only a completed or limited search can find that nothing applies.
public enum SearchStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case completed, limited, unavailable, failed
}

/// RecallCoverage is what the selection covers of the remaining work, never a promise that the result will be
/// reached: complete within its conditions, partial with gaps, ambiguous (a choice or an input the request leaves
/// open), absent (nothing useful in the searched perimeter), or unknown when the search could not answer.
public enum RecallCoverage: String, Sendable, Equatable, Hashable, CaseIterable {
    case complete, partial, ambiguous, absent, unknown
}

/// CoverageReason is why a coverage is not complete: gaps (an entry state or a prerequisite nothing covers),
/// alternatives (methods the request does not choose between), an unresolved input (a parameter missing or
/// ambiguous), or, for an absence, that the relevant knowledge was excluded (a certain conflict with the task's
/// values, a step its constraints forbid) rather than not found.
public enum CoverageReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case gaps, alternatives, excluded
    case unresolvedInput = "unresolved_input"
}

/// RecallRequirement is one thing a selection requires or states, as it is recorded.
public struct RecallRequirement: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        /// The functional state the selection's first step starts from: to reach or observe before it.
        case entryState                 = "entry_state"
        /// The source changed application here between two blocks, by opening or focusing it.
        case applicationSwitch          = "application_switch"
        /// A step's entry state nothing recorded: whether earlier steps prepared it is unknown.
        case unknownEntryState          = "unknown_entry_state"
        /// A step that would prepare the selection is not offered by the catalogue.
        case prerequisiteOutOfCatalogue = "prerequisite_out_of_catalogue"
        case parameterBound             = "parameter_bound"
        case parameterMissing           = "parameter_missing"
        case parameterAmbiguous         = "parameter_ambiguous"
        /// A choice made with another value in the source: whether the new value works there is unknown.
        case compatibilityUnknown       = "compatibility_unknown"
        /// A value the task still lacks concerns a choice the selection fixes: whether the method fits is unresolved
        /// until the agent resolves the value.
        case unboundTaskInput           = "unbound_task_input"
        /// The selection starts from the state the latest observation of the task's session shows: the source's
        /// steps that reached that state from the episode's start are not repeated.
        case observedState              = "observed_state"
        /// Steps of the same block came before the selection in the source and are not part of it: what they left
        /// (a document edited, a file selected) is not stated by any contract and must already be in place.
        case preparedBefore             = "prepared_before"
        /// An input the task does not hold was produced in the source by an earlier part, which the selection
        /// includes from its first step.
        case inputProduced              = "input_produced"
        /// The task already holds what an earlier part of the source produced: that part is not repeated.
        case outputReady                = "output_ready"
        /// A constraint the selector does not check, wholly or in part: a condition for the agent.
        case constraintUnchecked        = "constraint_unchecked"
        /// Of an excluded selection: a step fixes a choice that a value of the task certainly contradicts.
        case certainConflict            = "certain_conflict"
        /// Of an excluded selection: a step does what one of the task's constraints forbids.
        case constraintExcluded         = "constraint_excluded"
        /// An adapter's step (P2-01): its adapter must be available now; it starts from
        /// no screen state, so it raises no switch of application.
        case adapterAvailable           = "adapter_available"
        /// A step uses the result of an earlier step of this run (P2-02): fill it from that step's own result when it
        /// ran, never from the source's episode; before then it is pending.
        case stepResultPending          = "step_result_pending"
        /// Resolve the account for this task, including a source's default or unknown account; the source's is never
        /// delivered, and the same site, profile or service does not imply the same account.
        case accountToResolve           = "account_to_resolve"
    }

    /// BindingMatch is how a parameter was bound to the task's value: by the same name, by the same role, through
    /// a value derived from a file the task names (its name, extension or folder), or through the output of an earlier
    /// part that gave the input its value in the source, which the task holds.
    public enum BindingMatch: String, Sendable, Equatable, Hashable, CaseIterable {
        case name, role, derived, produced
    }

    public let kind: Kind
    public let stepPosition: Int?
    public let parameterID: String?
    public let sceneID: String?
    public let bundleID: String?
    public let taskValueName: String?
    public let bindingMatch: BindingMatch?
    /// The position of the request's constraint a requirement is about.
    public let constraintPosition: Int?
    /// For an ambiguous parameter, the names of the task's values it could take; not recorded, only said.
    public let candidates: [String]

    public init(kind: Kind, stepPosition: Int? = nil, parameterID: String? = nil, sceneID: String? = nil, bundleID: String? = nil,
                taskValueName: String? = nil, bindingMatch: BindingMatch? = nil, constraintPosition: Int? = nil,
                candidates: [String] = []) {
        self.kind               = kind
        self.stepPosition       = stepPosition
        self.parameterID        = parameterID
        self.sceneID            = sceneID
        self.bundleID           = bundleID
        self.taskValueName      = taskValueName
        self.bindingMatch       = bindingMatch
        self.constraintPosition = constraintPosition
        self.candidates         = candidates
    }

    /// Whether this requirement leaves knowledge missing: the selection is partial.
    public var isGap: Bool { kind == .unknownEntryState || kind == .prerequisiteOutOfCatalogue }

    /// Whether this requirement leaves an input of the task unresolved: the selection is ambiguous until it is.
    public var isUnresolvedInput: Bool { kind == .parameterMissing || kind == .parameterAmbiguous || kind == .unboundTaskInput }

    /// Whether this requirement is a certain reason to exclude the steps it names.
    public var isExclusion: Bool { kind == .certainConflict || kind == .constraintExcluded }
}

/// RecallSelection is the ordered interval of one version's steps proposed for a need (or, as an alternative, one
/// an ambiguity names; as an exclusion, relevant steps a certain conflict or a constraint removed), the part it is
/// whole when it is one, its relevance, the preparations it needs and every requirement.
public struct RecallSelection: Sendable, Equatable {

    public enum Role: String, Sendable, Equatable { case selected, alternative, excluded }

    public let role: Role
    public let routeID: String
    public let firstPosition: Int
    public let lastPosition: Int
    public let wholePartID: String?
    public let relevance: Double
    public let preparations: Int
    public let requirements: [RecallRequirement]

    public init(role: Role, routeID: String, firstPosition: Int, lastPosition: Int, wholePartID: String?, relevance: Double,
                preparations: Int, requirements: [RecallRequirement]) {
        self.role          = role
        self.routeID       = routeID
        self.firstPosition = firstPosition
        self.lastPosition  = lastPosition
        self.wholePartID   = wholePartID
        self.relevance     = relevance
        self.preparations  = preparations
        self.requirements  = requirements
    }

    public var positions: ClosedRange<Int> { firstPosition...lastPosition }
}

/// NeedOutcome is what the selection did for one need: its coverage and why, the selection proposed, the
/// alternatives an ambiguity names, and the relevant steps excluded with the certain reason of each.
public struct NeedOutcome: Sendable, Equatable {
    public let position: Int
    public let need: RecallNeed
    public let coverage: RecallCoverage
    public let reason: CoverageReason?
    public let selected: RecallSelection?
    public let alternatives: [RecallSelection]
    public let excluded: [RecallSelection]
    /// The need's words the selected version accounts for nowhere: why a selection otherwise complete is partial. Said, not
    /// recorded.
    public let unaccounted: [String]
    /// For a need of the agent's choice (`RecallChoice`), its tracts in the order the agent will use them, recorded as the
    /// need's selected rows; `selected` is then nil.
    public let plan: [RecallSelection]
    /// Steps the need names that the selection leaves out, behind work of another application it does not ask for: why it is
    /// partial. Said, not recorded.
    public let leftOut: ClosedRange<Int>?

    public init(position: Int, need: RecallNeed, coverage: RecallCoverage, reason: CoverageReason?, selected: RecallSelection?,
                alternatives: [RecallSelection], excluded: [RecallSelection] = [], unaccounted: [String] = [],
                plan: [RecallSelection] = [], leftOut: ClosedRange<Int>? = nil) {
        self.position     = position
        self.need         = need
        self.coverage     = coverage
        self.reason       = reason
        self.selected     = selected
        self.alternatives = alternatives
        self.excluded     = excluded
        self.unaccounted  = unaccounted
        self.plan         = plan
        self.leftOut      = leftOut
    }

    /// The selected rows the need records and delivers: the agent's tracts, or the one selection.
    public var delivered: [RecallSelection] { plan.isEmpty ? (selected.map { [$0] } ?? []) : plan }

    /// The coverage of a query from its needs': complete when every need is; absent when none is covered at all;
    /// ambiguous when one is; partial otherwise.
    public static func overall(_ needs: [NeedOutcome]) -> RecallCoverage {
        guard !needs.isEmpty else { return .absent }
        if needs.contains(where: { $0.coverage == .unknown }) { return .unknown }
        if needs.allSatisfy({ $0.coverage == .complete }) { return .complete }
        if needs.allSatisfy({ $0.coverage == .absent }) { return .absent }
        if needs.contains(where: { $0.coverage == .ambiguous }) { return .ambiguous }
        return .partial
    }
}
