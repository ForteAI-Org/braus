//
//  RecallChoice.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation

/// RecallChoice is the experimental Recall by the agent's choice (Documentation/Engine/RecallAgentChoice.md): the few
/// versions a query shortlists per need, the plan the agent that runs the task chooses from them, and the structural
/// validation of that plan. The agent judges what the request asks; Engine checks what the facts can: the proposal's
/// task, attempt, revision and age, each version still current, each step still offered and not excluded with a certain
/// reason, the need's application, the order of the tracts. Then every tract is evaluated by the automatic selector's
/// own rules (entry states, gaps, producers, bindings, compatibilities, constraints), and the need's coverage is derived
/// from them and from the agent's declaration, never from the declaration alone.
public enum RecallChoice {

    /// The version of the proposal's text, recorded with each proposal.
    public static let formatVersion = "recall-proposal-2"
    /// The selection rules of a choice, recorded with the query that delivers it. Version 2 (review of experiment A):
    /// an excluded step takes its episode out of every tract, a variant's fixed choice must be settled, and a need can
    /// be answered ambiguous with its alternatives.
    public static let selectorVersion = "recall-agent-choice-2"
    /// The most versions a proposal shortlists for one need, and for the whole query.
    public static let sourcesPerNeed = 3
    public static let sourceLimit = 6
    /// How long a proposal can be chosen from, in milliseconds.
    public static let validityMS: Int64 = 30 * 60 * 1000

    /// Shortlisted is one version a proposal shortlisted for one need: the proposal's own name for it (`s1`, …), its
    /// relevance to the need, and the interval the automatic selector suggested in it, when it named one.
    public struct Shortlisted: Sendable, Equatable {
        public let needPosition: Int
        public let key: String
        public let routeID: String
        public let relevance: Double
        public let suggested: ClosedRange<Int>?

        public init(needPosition: Int, key: String, routeID: String, relevance: Double, suggested: ClosedRange<Int>?) {
            self.needPosition = needPosition
            self.key          = key
            self.routeID      = routeID
            self.relevance    = relevance
            self.suggested    = suggested
        }
    }

    /// Proposal is a proposal as it is recorded and read back: whom it was made for, under which revision and attempt, when,
    /// for which needs, and what it shortlisted.
    public struct Proposal: Sendable {
        public let proposalID: String
        public let taskID: String
        public let attemptID: String
        public let revision: Int
        public let producer: TaskProducer
        public let reason: RecallReason
        public let remainingWork: String
        public let needs: [RecallNeed]
        public let shortlisted: [Shortlisted]
        public let recordedAtMS: Int64

        public init(proposalID: String, taskID: String, attemptID: String, revision: Int, producer: TaskProducer, reason: RecallReason,
                    remainingWork: String, needs: [RecallNeed], shortlisted: [Shortlisted], recordedAtMS: Int64) {
            self.proposalID    = proposalID
            self.taskID        = taskID
            self.attemptID     = attemptID
            self.revision      = revision
            self.producer      = producer
            self.reason        = reason
            self.remainingWork = remainingWork
            self.needs         = needs
            self.shortlisted   = shortlisted
            self.recordedAtMS  = recordedAtMS
        }

        /// The version the proposal names by `key`.
        public func routeID(of key: String) -> String? { shortlisted.first { $0.key == key }?.routeID }
    }

    /// Declared is how much of a need the agent says its tracts cover: all of it, part of it, or none; or that the
    /// need is ambiguous, its options given as alternatives for the person to choose between (no tract runs).
    public enum Declared: String, Sendable, Equatable, CaseIterable {
        case all, part, none, ambiguous
    }

    /// Tract is one interval the agent chose: of the version the proposal names `key`, from `first` to `last`, in the
    /// version's own positions (from 0).
    public struct Tract: Sendable, Equatable {
        public let key: String
        public let first: Int
        public let last: Int

        public init(key: String, first: Int, last: Int) {
            self.key   = key
            self.first = first
            self.last  = last
        }
    }

    /// PlannedNeed is the agent's answer for one need of the proposal: its tracts in the order it will use them, how much
    /// of the need it says they cover, and, in its words, what remains (for an ambiguous need, the question for the
    /// person). An ambiguous need gives its options as `alternatives`, never as tracts. `settledBy` quotes the person's
    /// own words in the request that settle a fixed choice a variant makes otherwise.
    public struct PlannedNeed: Sendable, Equatable {
        public let position: Int
        public let tracts: [Tract]
        public let declared: Declared
        public let uncovered: String?
        public let alternatives: [Tract]
        public let settledBy: String?

        public init(position: Int, tracts: [Tract], declared: Declared, uncovered: String?, alternatives: [Tract] = [],
                    settledBy: String? = nil) {
            self.position     = position
            self.tracts       = tracts
            self.declared     = declared
            self.uncovered    = uncovered
            self.alternatives = alternatives
            self.settledBy    = settledBy
        }
    }

    /// Plan is the agent's choice for a proposal: one answer per need.
    public struct Plan: Sendable, Equatable {
        public let proposalID: String
        public let needs: [PlannedNeed]

        public init(proposalID: String, needs: [PlannedNeed]) {
            self.proposalID = proposalID
            self.needs      = needs
        }
    }

    /// Refusal is a plan Engine does not admit, with every reason: nothing of it is recorded or delivered, and no
    /// operation runs. `stale`: the proposal can no longer be chosen from (another revision or attempt, too old);
    /// `unknown`: no proposal of this producer has that id; `invalid`: the plan names what the proposal or the facts do
    /// not admit.
    public struct Refusal: Error, Sendable, Equatable {
        public enum Code: String, Sendable, Equatable {
            case unknown = "unknown_proposal", stale = "stale_proposal", invalid = "invalid_plan", chosen = "proposal_already_chosen"
        }
        public let code: Code
        public let problems: [String]

        public init(_ code: Code, _ problems: [String]) {
            self.code     = code
            self.problems = problems
        }
    }

    /// Chosen is one need of an admitted plan: its outcome as recorded (coverage derived by Engine, the tracts as the
    /// need's ordered selected rows) and the agent's declaration beside it.
    public struct Chosen: Sendable {
        public let outcome: NeedOutcome
        public let declared: Declared
        public let uncovered: String?
        public var settledBy: String? = nil
    }

    // MARK: Shortlist

    /// The versions to shortlist from what the search read: for each need, the most relevant versions it can select from
    /// (relevance of their offered parts, above nothing), at most `sourcesPerNeed`, and at most `sourceLimit` distinct
    /// versions in all, each named once (`s1`, `s2`, … in order of appearance). A version is shortlisted whether or not the
    /// automatic selector names a tract in it; its suggestion, when it made one in that version, is kept beside it.
    public static func shortlist(_ scored: [[ScoredSource]], suggestions: [NeedOutcome]) -> [Shortlisted] {
        var keys: [String: String] = [:]
        var shortlisted: [Shortlisted] = []
        for (need, sources) in scored.enumerated() {
            let ranked = sources.map { source -> (ScoredSource, Double) in
                let parts = source.source.parts.filter(\.isOffered).compactMap { source.partRelevance[$0.partID] }
                return (source, (Array(source.stepRelevance.values) + parts).max() ?? -.infinity)
            }.filter { $0.1 > 0 }.sorted { ($0.1, $1.0.source.routeID) > ($1.1, $0.0.source.routeID) }
            for (source, relevance) in ranked.prefix(sourcesPerNeed) {
                let route = source.source.routeID
                guard keys[route] != nil || keys.count < sourceLimit else { continue }
                let key = keys[route] ?? "s\(keys.count + 1)"
                keys[route] = key
                let suggestion = suggestions.indices.contains(need) ? suggestions[need].selected : nil
                shortlisted.append(Shortlisted(needPosition: need, key: key, routeID: route, relevance: relevance,
                                               suggested: suggestion?.routeID == route ? suggestion?.positions : nil))
            }
        }
        return shortlisted
    }

    // MARK: Validation

    /// The plan admitted against the proposal and the facts read now, or every reason it is not.
    /// - `sources`: the versions the proposal names, read again from the authoritative tables (a missing one is no longer
    ///   readable); `superseded`: those a later version replaced since.
    /// - `attemptID`, `revision`: the producer's open attempt and the task's current revision.
    /// - `context`: the task's current values, constraints and observed state.
    public static func validate(_ plan: Plan, against proposal: Proposal, sources: [String: RecallSource], superseded: Set<String>,
                                producer: TaskProducer, attemptID: String, revision: Int, context: RecallSelector.Context,
                                nowMS: Int64) -> Result<[Chosen], Refusal> {
        guard proposal.producer.isExactly(producer) else {
            return .failure(Refusal(.unknown, ["no proposal \(plan.proposalID) of yours belongs to this attempt; propose again"]))
        }
        // A proposal of an earlier attempt of the task (before a restart and a resumption) has expired: never reused.
        guard proposal.attemptID == attemptID else {
            return .failure(Refusal(.stale, ["the proposal was made in an earlier attempt of this task; propose again"]))
        }
        var stale: [String] = []
        if proposal.revision != revision {
            stale.append("the task is at revision \(revision), the proposal was made at revision \(proposal.revision)")
        }
        if nowMS - proposal.recordedAtMS > validityMS { stale.append("the proposal is older than \(validityMS / 60_000) minutes") }
        guard stale.isEmpty else { return .failure(Refusal(.stale, stale + ["propose again"])) }

        var problems: [String] = []
        let answered = Dictionary(grouping: plan.needs, by: \.position)
        for (position, answers) in answered where answers.count > 1 { problems.append("need \(position + 1) is answered \(answers.count) times") }
        for position in answered.keys where !proposal.needs.indices.contains(position) { problems.append("the proposal has no need \(position + 1)") }
        for position in proposal.needs.indices where answered[position] == nil { problems.append("need \(position + 1) has no answer") }
        for planned in plan.needs where proposal.needs.indices.contains(planned.position) {
            let need = proposal.needs[planned.position]
            let label = "need \(planned.position + 1)"
            switch planned.declared {
                case .none:
                    if !planned.tracts.isEmpty { problems.append("\(label) is said covered by none of its tracts") }
                case .ambiguous:
                    if !planned.tracts.isEmpty {
                        problems.append("\(label) is said ambiguous with tracts to run: give its options as alternatives, none as a tract")
                    }
                    if planned.alternatives.count < 2 {
                        problems.append("\(label) is said ambiguous with \(planned.alternatives.count) alternative(s): give at least two")
                    }
                    if planned.uncovered == nil { problems.append("\(label) is said ambiguous without the question for the person (uncovered)") }
                case .all, .part:
                    if planned.tracts.isEmpty { problems.append("\(label) is said covered (\(planned.declared.rawValue)) by no tract") }
            }
            if planned.declared == .all, planned.uncovered != nil { problems.append("\(label) is said wholly covered with something uncovered") }
            if planned.declared != .ambiguous, !planned.alternatives.isEmpty {
                problems.append("\(label) gives alternatives but is not said ambiguous")
            }
            if planned.settledBy != nil, planned.tracts.isEmpty { problems.append("\(label) settles a choice but runs no tract") }
            problems += check(planned.tracts, of: "tract", label: label, need: need, proposal: proposal, sources: sources,
                              superseded: superseded, context: context, ordered: true)
            problems += check(planned.alternatives, of: "alternative", label: label, need: need, proposal: proposal, sources: sources,
                              superseded: superseded, context: context, ordered: false)
            if planned.declared == .all || planned.declared == .part {
                problems += unsettledChoices(planned, label: label, need: need, proposal: proposal, sources: sources, values: context.values)
            }
        }
        guard problems.isEmpty else { return .failure(Refusal(.invalid, problems)) }

        var chosen: [Chosen] = []
        for planned in plan.needs.sorted(by: { $0.position < $1.position }) {
            let need = proposal.needs[planned.position]
            var tracts: [RecallSelection] = []
            var earlier: [String: [ClosedRange<Int>]] = [:]
            var partial = planned.declared == .part
            var unresolved = false
            for tract in planned.tracts {
                guard let route = proposal.routeID(of: tract.key), let source = sources[route] else { continue }
                let relevance = proposal.shortlisted.first { $0.routeID == route }?.relevance ?? 0
                let reading = RecallSelector.Reading(ScoredSource(source: source, stepRelevance: [:], partRelevance: [:]), need: need,
                                                     context: context.knowing(need), thresholds: Self.unread)
                let evaluated = reading.evaluated(tract.first...tract.last, requirements: [], relevance: relevance,
                                                  planned: earlier[route] ?? [])
                earlier[route, default: []].append(tract.first...tract.last)
                if evaluated.coverage == .partial { partial = true }
                if evaluated.coverage == .ambiguous { unresolved = true }
                tracts.append(evaluated.selection(role: .selected))
            }
            if planned.declared == .ambiguous {
                // The person chooses between the options: none runs, each is recorded as an alternative.
                let alternatives = planned.alternatives.compactMap { tract -> RecallSelection? in
                    guard let route = proposal.routeID(of: tract.key), let source = sources[route] else { return nil }
                    let relevance = proposal.shortlisted.first { $0.routeID == route }?.relevance ?? 0
                    let reading = RecallSelector.Reading(ScoredSource(source: source, stepRelevance: [:], partRelevance: [:]), need: need,
                                                         context: context.knowing(need), thresholds: Self.unread)
                    return reading.evaluated(tract.first...tract.last, requirements: [], relevance: relevance, planned: [])
                        .selection(role: .alternative)
                }
                let outcome = NeedOutcome(position: planned.position, need: need, coverage: .ambiguous, reason: .alternatives, selected: nil,
                                          alternatives: alternatives, excluded: [], plan: [])
                chosen.append(Chosen(outcome: outcome, declared: planned.declared, uncovered: planned.uncovered))
                continue
            }
            let (coverage, reason): (RecallCoverage, CoverageReason?) =
                tracts.isEmpty ? (.absent, nil) : partial ? (.partial, .gaps) : unresolved ? (.ambiguous, .unresolvedInput) : (.complete, nil)
            let outcome = NeedOutcome(position: planned.position, need: need, coverage: coverage, reason: reason, selected: nil,
                                      alternatives: [], excluded: [], plan: tracts)
            chosen.append(Chosen(outcome: outcome, declared: planned.declared, uncovered: planned.uncovered, settledBy: planned.settledBy))
        }
        return .success(chosen)
    }

    /// The problems of a need's tracts (or alternatives): each names a source of the proposal, still current, a range of its
    /// steps, every step offered, in the need's application and outside what a certain reason excludes (the excluded step
    /// and the episode it belongs to); tracts of one source go in its order without overlapping.
    static func check(_ tracts: [Tract], of kind: String, label: String, need: RecallNeed, proposal: Proposal, sources: [String: RecallSource],
                      superseded: Set<String>, context: RecallSelector.Context, ordered: Bool) -> [String] {
        var problems: [String] = []
        var last: [String: Int] = [:]
        for (index, tract) in tracts.enumerated() {
            let named = "\(label), \(kind) \(index + 1)"
            guard let route = proposal.routeID(of: tract.key) else { problems.append("\(named): the proposal names no source \(tract.key)"); continue }
            guard let source = sources[route] else { problems.append("\(named): version \(route) can no longer be read"); continue }
            if superseded.contains(route) { problems.append("\(named): version \(route) was superseded since the proposal") }
            guard tract.first >= 0, tract.first <= tract.last, tract.last < source.steps.count else {
                problems.append("\(named): steps \(tract.first + 1)–\(tract.last + 1) are not steps of \(tract.key), which has \(source.steps.count)")
                continue
            }
            if ordered, let previous = last[route], tract.first <= previous {
                problems.append("\(named): tracts of one source go in its order without overlapping (step \(tract.first + 1) after \(previous + 1))")
            }
            last[route] = tract.last
            let reading = RecallSelector.Reading(ScoredSource(source: source, stepRelevance: [:], partRelevance: [:]), need: need,
                                                 context: context.knowing(need), thresholds: Self.unread)
            for position in tract.first...tract.last {
                guard let step = source.step(position) else { continue }
                if !step.isOffered { problems.append("\(named): step \(position + 1) of \(tract.key) is no longer offered") }
                if let bundle = need.bundleID, let app = step.bundleID, app != bundle {
                    problems.append("\(named): step \(position + 1) runs in \(app), and \(label) is bound to \(bundle)")
                }
                for reason in reading.reasons[position] ?? [] {
                    switch reason.kind {
                        case .certainConflict:
                            problems.append("\(named): step \(position + 1) fixes a choice the task's \(reason.taskValueName ?? "value") contradicts")
                        default:
                            problems.append("\(named): step \(position + 1) does what constraint \((reason.constraintPosition ?? 0) + 1) forbids")
                    }
                }
                // A step of the episode an excluded step belongs to produces the same result, so leaving the excluded step out
                // does not make the rest compatible (review R3). The version's other episodes stay selectable.
                if reading.reasons[position] == nil, reading.excluded.contains(position) {
                    let excludedBy = Self.excludingSteps(of: position, in: reading)
                    problems.append("\(named): step \(position + 1) belongs to the work of step\(excludedBy.count == 1 ? "" : "s") "
                                    + excludedBy.map { String($0 + 1) }.joined(separator: ", ")
                                    + ", which does what the task excludes; its result is incompatible, so none of its steps is admitted")
                }
            }
        }
        return problems
    }

    // MARK: Variants

    /// Choice is a fixed choice two variants make differently at one aligned step: a select's item, a toggle's value, or
    /// the last item of a menu path. `context` holds the content words of what the choice is made on: the select's control,
    /// the toggle's target, or the menu path before its last item.
    struct Choice: Equatable {
        let step: Int
        let argument: String
        let mine: String
        let theirs: String
        var context: Set<String> = []
    }

    /// The problems of a need's tracts that do the work another shortlisted version of the need does with a different
    /// fixed choice (review R5: print all pages or the current one, export to PDF or to Word), when nothing settles the
    /// choice. What can settle it (review F14: the evidence follows the choice and its role, never the person's data):
    /// - a task value concerning the choice that names it: a value whose name, the identifier the task gives it, shares a
    ///   content word with the control or menu the choice is made on, and that neither version binds to a parameter (those
    ///   values are the versions' data: a file named Word is no format). A value's role is free text and is not read for
    ///   this; a value not shown to concern the choice settles nothing and contradicts nothing;
    /// - the request's words naming this option and not the other, read with every task value taken out of them;
    /// - `settledBy`, a quotation of the request that is not the request as a whole. Engine checks that the words are the
    ///   request's, not what they mean: that reading is the agent's, recorded beside the choice as its own.
    /// A value concerning the choice that names the other variant's option is a contradiction. When none of these holds, the
    /// choice stays open: the plan is refused, and the agent asks the person (an ambiguous need) or quotes them.
    static func unsettledChoices(_ planned: PlannedNeed, label: String, need: RecallNeed, proposal: Proposal, sources: [String: RecallSource],
                                 values: [TaskValue]) -> [String] {
        var problems: [String] = []
        let others = proposal.shortlisted.filter { $0.needPosition == planned.position }
        // The request's words with every task value taken out: a value is the person's data, not a functional choice.
        let request = words(RecallText.masked(need.text, values: values) + " " + RecallText.masked(proposal.remainingWork, values: values))
        let secrets = Set(values.filter { $0.sensitivity == .secret }.map(\.name))
        let candidates = RecallBinding.candidates(values).filter { !$0.isDerived && !secrets.contains($0.name) && $0.text != nil }
        // The quotation must be words of the request and not the request as a whole, which states no choice by itself.
        let whole = planned.settledBy.map { quote in [need.text, proposal.remainingWork].map(normalized).contains(normalized(quote)) } ?? false
        let quoted = planned.settledBy.map { quote in
            let text = normalized(need.text + " \n " + proposal.remainingWork)
            return normalized(quote).count >= 3 && text.contains(normalized(quote))
        } ?? false
        if planned.settledBy != nil, !quoted {
            problems.append("\(label): settled_by is not words of the request; quote the person's own words that make the choice")
        }
        if whole {
            problems.append("\(label): settled_by quotes the whole request, which states no choice by itself; quote only the words that "
                            + "state the choice, or answer the need as ambiguous")
        }
        for (index, tract) in planned.tracts.enumerated() {
            guard let route = proposal.routeID(of: tract.key), let source = sources[route], tract.first >= 0, tract.first <= tract.last,
                  tract.last < source.steps.count else { continue }
            var seen: Set<String> = [route]
            for other in others where !seen.contains(other.routeID) {
                seen.insert(other.routeID)
                guard let variant = sources[other.routeID], let found = variantWindow(of: tract.first...tract.last, in: source, among: variant)
                else { continue }
                // The values the two versions bind to their parameters are their data, never the evidence of a fixed choice.
                let data = Set((source.parameters + variant.parameters).filter { $0.direction != .output }.compactMap { parameter -> String? in
                    guard case .bound(let value, _) = RecallBinding.bind(parameter, among: candidates) else { return nil }
                    return value.name
                })
                for choice in found.choices {
                    let mine = words(choice.mine), theirs = words(choice.theirs)
                    let concerning = candidates.filter { value in
                        !data.contains(value.name) && !Set(RecallText.tokens(value.name)).isDisjoint(with: choice.context)
                    }
                    func named(_ literal: String) -> Bool {
                        concerning.contains { value in value.text.map { !words($0).isEmpty && words($0) == words(literal) } ?? false }
                    }
                    if named(choice.theirs), !named(choice.mine) {
                        problems.append("\(label), tract \(index + 1): step \(choice.step + 1) of \(tract.key) chooses \"\(choice.mine)\", and the "
                                        + "task's values name \"\(choice.theirs)\", which \(other.key) chooses")
                        continue
                    }
                    let settled = named(choice.mine) || (!mine.isEmpty && mine.isSubset(of: request) && !theirs.isSubset(of: request))
                        || (quoted && !whole)
                    guard !settled else { continue }
                    problems.append("\(label), tract \(index + 1): \(tract.key) steps \(tract.first + 1)–\(tract.last + 1) and \(other.key) steps "
                                    + "\(found.range.lowerBound + 1)–\(found.range.upperBound + 1) do the same work with a different fixed choice "
                                    + "(\(choice.argument) \"\(choice.mine)\" or \"\(choice.theirs)\"), which neither the task's values nor the request's "
                                    + "words settle. Answer the need as ambiguous with both as alternatives and the question for the person "
                                    + "in uncovered, or give in settled_by the person's own words from the request that make this choice")
                }
            }
        }
        return problems
    }

    /// The window of `variant` that does the work of `range` of `source` step by step with at least one different fixed
    /// choice, when there is one: the same tools and arguments, the task's values in the same places (whatever their
    /// names), anchors as anchors, and only a select's item, a toggle's value or a menu path's last item differing.
    static func variantWindow(of range: ClosedRange<Int>, in source: RecallSource, among variant: RecallSource)
        -> (range: ClosedRange<Int>, choices: [Choice])? {
        let mine = range.compactMap(source.step)
        guard mine.count == range.count, variant.steps.count >= mine.count else { return nil }
        for start in 0...(variant.steps.count - mine.count) {
            var choices: [Choice] = []
            var aligned = true
            for (offset, step) in mine.enumerated() {
                guard let theirs = variant.step(start + offset), let found = differences(step, theirs) else { aligned = false; break }
                choices += found
            }
            if aligned, !choices.isEmpty { return (start...(start + mine.count - 1), choices) }
        }
        return nil
    }

    /// The fixed choices two steps make differently, or nil when they are not the same operation.
    static func differences(_ mine: RecallSource.Step, _ theirs: RecallSource.Step) -> [Choice]? {
        guard mine.tool == theirs.tool, mine.arguments.map(\.name) == theirs.arguments.map(\.name) else { return nil }
        var choices: [Choice] = []
        for (a, b) in zip(mine.arguments, theirs.arguments) {
            switch (a.value, b.value) {
                case (.parameter, .parameter), (.template, .template), (.anchor, .anchor):
                    continue
                case (.menu(let x), .menu(let y)):
                    guard x != y else { continue }
                    guard let choice = lastItems(x, y) else { return nil }
                    choices.append(Choice(step: mine.position, argument: a.name, mine: choice.0, theirs: choice.1, context: menuContext(x)))
                case (.literal(let x), .literal(let y)):
                    let one = literalText(x), other = literalText(y)
                    guard one != other else { continue }
                    if a.name == "path" {
                        // A menu path recorded as text: the same menu, another last item.
                        guard let choice = lastItems(one, other) else { return nil }
                        choices.append(Choice(step: mine.position, argument: a.name, mine: choice.0, theirs: choice.1, context: menuContext(one)))
                        continue
                    }
                    guard a.name == "item" || a.name == "value" else { return nil }
                    // What the choice is made on: the select's control (the selector's own choice words), or the element.
                    let made = mine.choiceWords.isEmpty
                        ? Set(mine.arguments.filter { ["control", "target"].contains($0.name) }.compactMap { argument -> String? in
                            if case .literal(.text(let text)) = argument.value { return text } else { return nil }
                        }.flatMap(RecallText.tokens))
                        : mine.choiceWords
                    choices.append(Choice(step: mine.position, argument: a.name, mine: one, theirs: other, context: made))
                default:
                    return nil
            }
        }
        return choices
    }

    /// The content words of a menu path before its last item: the menu a choice among its items is made in.
    static func menuContext(_ path: String) -> Set<String> {
        Set(RecallText.tokens(path.components(separatedBy: " > ").dropLast().joined(separator: " ")))
    }

    /// The last items of two menu paths that differ only there, or nil.
    static func lastItems(_ x: String, _ y: String) -> (String, String)? {
        let left = x.components(separatedBy: " > "), right = y.components(separatedBy: " > ")
        guard left.count == right.count, left.count > 1, left.dropLast() == right.dropLast(), let one = left.last, let other = right.last
        else { return nil }
        return (one, other)
    }

    static func literalText(_ value: BrainArgument.Value) -> String {
        switch value {
            case .text(let text): text
            case .integer(let number): String(number)
            case .real(let number): String(number)
            case .boolean(let flag): String(flag)
        }
    }

    /// A text's words, lowercased, letters and digits only.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// A text lowercased with its runs of spaces and punctuation as one space, to find a quotation in it.
    static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// The excluded steps whose work `position` belongs to: those with a certain reason in the run of excluded positions
    /// around it (an episode, and the uncertain episodes next to it that go with it).
    static func excludingSteps(of position: Int, in reading: RecallSelector.Reading) -> [Int] {
        var low = position, high = position
        while reading.excluded.contains(low - 1) { low -= 1 }
        while reading.excluded.contains(high + 1) { high += 1 }
        return (low...high).filter { reading.reasons[$0] != nil }
    }

    /// Thresholds a choice never reads: the agent's tracts are not delimited by relevance.
    static let unread = SelectionThresholds(absolute: 0, stepMargin: 0, partMargin: 0, adequacy: 0, tie: 0)
}
