//
//  RecallChoiceService.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation
import Memory
import SQLiteMemory

/// The experiment of the Recall by the agent's choice (Documentation/Engine/RecallAgentChoice.md): a proposal searched as a
/// query is, recorded before anything is delivered; then the agent's plan, checked against the proposal and the facts read
/// again, recorded with the query that delivers it, and delivered.
extension RecallService {

    /// ProposalAnswer is a proposal's text and its record, with how long its phases took.
    public struct ProposalAnswer: Sendable {
        public let delivery: RecallProposalDelivery
        public let recorded: SQLiteRecallRepository.RecordedProposal
        public let phases: Phases
    }

    /// ChoiceAnswer is the delivery of an admitted choice and the query that records it.
    public struct ChoiceAnswer: Sendable {
        public let delivery: RecallChoiceDelivery
        public let queryID: String
        public let recordedNow: Bool
    }

    /// Searches for the request's needs as a query does, shortlists the versions per need, records the proposal and answers
    /// its text. Nothing is selected for the agent and nothing is delivered as a plan.
    public func propose(_ request: RecallRequest, producer: TaskProducer) async throws -> ProposalAnswer {
        let started = ContinuousClock.now
        let proposalID = UUID().uuidString
        _ = await memory.flush(within: Self.observationFlush)
        let since = memory.clock.calendarMS() - Self.observationFreshnessMS
        let observed = try await memory.perform { try await $0.recall.observedState(of: producer.source, stream: producer.streamID, since: since) }
        var prepared = try await prepare(request, observed: observed.map { [$0] } ?? [])
        let clock = ContinuousClock.now
        let suggestions = outcomes(prepared)
        let shortlisted = RecallChoice.shortlist(scored(prepared) ?? [], suggestions: suggestions)
        prepared.phases.selection = clock.duration(to: .now)
        let sources = Dictionary(uniqueKeysWithValues: prepared.sources.map { ($0.routeID, $0) })
        let note = prepared.notes.isEmpty ? nil : prepared.notes.joined(separator: "; ")
        let proposal = RecallChoice.Proposal(proposalID: proposalID, taskID: request.taskID, attemptID: request.attemptID,
                                             revision: request.revision, producer: producer, reason: request.reason,
                                             remainingWork: request.remainingWork, needs: prepared.needs, shortlisted: shortlisted,
                                             recordedAtMS: memory.clock.calendarMS())
        let search = RecallDelivery.Search(status: prepared.searchStatus.rawValue, channel: prepared.channel.rawValue,
                                           partsConsidered: prepared.considered, versionsRead: prepared.sources.count, note: note)
        let index = index(prepared.status, searchStatus: prepared.searchStatus, generation: prepared.cache?.generation)
        var delivery = Self.render(proposal, sources: sources, suggestions: suggestions, context: prepared.context, values: request.values,
                                   search: search, index: index)
        var bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        if bytes > RecallContract.channelLimitBytes {
            // Over the channel's limit nothing of the sources is sent, and the answer says so: never a silent cut.
            delivery = RecallProposalDelivery(proposal: proposalID, revision: request.revision, index: index, search: search,
                                              needs: delivery.needs, sources: [],
                                              guidance: "The shortlisted sources exceed what one answer can carry, so none is given. Search "
                                                + "again with memory_task recall and fewer or narrower needs, or carry on with the tools.")
            bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        }
        let elapsed = started.duration(to: .now)
        let recorded = SQLiteRecallRepository.RecordedProposal(
            proposal: proposal, generationID: prepared.channel == .none ? nil : prepared.cache?.generation.generationID, channel: prepared.channel,
            searchStatus: prepared.searchStatus,
            searchNote: note ?? (prepared.searchStatus == .completed ? nil : prepared.searchStatus.rawValue),
            candidatesConsidered: prepared.considered, bytes: bytes,
            durationUS: elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000)
        let recording = ContinuousClock.now
        try await memory.perform { try await $0.recall.recordProposal(recorded) }
        prepared.phases.recording = recording.duration(to: .now)
        return ProposalAnswer(delivery: delivery, recorded: recorded, phases: prepared.phases)
    }

    /// Checks the agent's plan against its proposal and the facts read now, records the query that delivers it and
    /// answers the delivery. Another plan for a chosen proposal is refused. A plan already recorded for the proposal (a
    /// retry) is checked as a new one, against the task's current revision, the proposal's age and the versions read
    /// now: after a revision of the task it is stale and a new Recall is needed. When it is admitted, it is answered
    /// under the recorded query only if what it delivers now is what was recorded; otherwise it is stale too. A retry
    /// records nothing. Throws `RecallChoice.Refusal` with every reason when the plan is not admitted.
    public func choose(_ plan: RecallChoice.Plan, taskID: String, attemptID: String, revision: Int, values: [TaskValue],
                       constraints: [String], producer: TaskProducer) async throws -> ChoiceAnswer {
        let started = ContinuousClock.now
        guard let recordedProposal = try await memory.perform({ try await $0.recall.proposal(plan.proposalID) }),
              recordedProposal.proposal.producer.isExactly(producer), recordedProposal.proposal.taskID == taskID else {
            throw RecallChoice.Refusal(.unknown, ["no proposal \(plan.proposalID) of yours was made for this task; propose again"])
        }
        let proposal = recordedProposal.proposal
        guard recordedProposal.searchStatus != .unavailable, recordedProposal.searchStatus != .failed else {
            throw RecallChoice.Refusal(.stale, ["the proposal's search could not answer (\(recordedProposal.searchNote ?? "no index")); "
                                               + "nothing can be chosen from it: plan with the current scene and tools"])
        }
        let normalized = RecallChoice.Plan(proposalID: plan.proposalID, needs: plan.needs.sorted { $0.position < $1.position })
        var earlierQuery: String?
        if let earlier = try await memory.perform({ try await $0.recall.choice(ofProposal: plan.proposalID) }) {
            guard earlier.plan == normalized else {
                throw RecallChoice.Refusal(.chosen, ["proposal \(plan.proposalID) was already chosen with another plan (query \(earlier.queryID)); "
                                                     + "propose again to choose otherwise"])
            }
            earlierQuery = earlier.queryID
        }
        let routes = Array(Set(proposal.shortlisted.map(\.routeID)))
        let read = try await memory.perform { try await $0.recall.sources(routes) }
        let sources = Dictionary(uniqueKeysWithValues: read.map { ($0.routeID, $0) })
        let superseded = try await memory.perform { try await $0.recall.superseded(routes) }
        _ = await memory.flush(within: Self.observationFlush)
        let since = memory.clock.calendarMS() - Self.observationFreshnessMS
        let observed = try await memory.perform { try await $0.recall.observedState(of: producer.source, stream: producer.streamID, since: since) }
        let context = RecallSelector.Context(values: values, constraints: constraints, observed: observed.map { [$0] } ?? [], needs: proposal.needs)
        // A retry is checked as a new choice: a later revision, an expired proposal, a superseded version or a retired step
        // refuses it, and the agent proposes again.
        let chosen: [RecallChoice.Chosen]
        switch RecallChoice.validate(normalized, against: proposal, sources: sources, superseded: superseded, producer: producer,
                                     attemptID: attemptID, revision: revision, context: context, nowMS: memory.clock.calendarMS()) {
            case .failure(let refusal): throw refusal
            case .success(let admitted): chosen = admitted
        }
        let outcomes = chosen.map(\.outcome)
        let request = try RecallRequest(taskID: taskID, attemptID: attemptID, revision: proposal.revision, reason: proposal.reason,
                                        remainingWork: proposal.remainingWork, needs: proposal.needs, values: values, constraints: constraints)
        let coverage = NeedOutcome.overall(outcomes)
        let queryID = UUID().uuidString
        var state = coverage == .absent || coverage == .unknown ? "nothing" : "delivered"
        var delivery = Self.render(chosen, queryID: queryID, proposal: proposal, sources: sources, request: request, state: state,
                                   recorded: earlierQuery == nil)
        var bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        if bytes > RecallContract.channelLimitBytes {
            state = "not_delivered"
            delivery = Self.render(chosen, queryID: queryID, proposal: proposal, sources: sources, request: request, state: state,
                                   recorded: earlierQuery == nil)
            bytes = (try? JSONEncoder().encode(delivery).count) ?? 0
        }
        let elapsed = started.duration(to: .now)
        var recorded = SQLiteRecallRepository.RecordedQuery(
            queryID: queryID, request: request, producer: producer, generationID: recordedProposal.generationID, channel: recordedProposal.channel,
            searchStatus: recordedProposal.searchStatus, searchNote: recordedProposal.searchNote,
            candidatesConsidered: recordedProposal.candidatesConsidered, coverage: coverage, delivery: state, deliveryBytes: bytes,
            durationUS: elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000, needs: outcomes)
        recorded.selectorVersion = RecallChoice.selectorVersion
        if let earlierQuery {
            // The same revision, the plan admitted again: answered under the recorded query only when what it delivers now
            // is what was recorded (the same tracts, conditions and task values by name). Otherwise it is no receipt.
            let stored = try await memory.perform { try await $0.recall.facts(ofQuery: earlierQuery) }
            guard stored == SQLiteRecallRepository.facts(of: recorded) else {
                throw RecallChoice.Refusal(.stale, ["what this plan delivers now differs from what query \(earlierQuery) recorded when it was "
                                                    + "chosen (the scene or the catalogue changed); propose again"])
            }
            return ChoiceAnswer(delivery: Self.render(chosen, queryID: earlierQuery, proposal: proposal, sources: sources, request: request,
                                                      state: state, recorded: false),
                                queryID: earlierQuery, recordedNow: false)
        }
        let at = memory.clock.calendarMS()
        let query = recorded
        if let earlier = try await memory.perform({ try await $0.recall.recordChoice(query, proposalID: plan.proposalID, declarations: chosen,
                                                                                      at: at) }) {
            // Another call chose this proposal meanwhile.
            guard earlier.plan == normalized else {
                throw RecallChoice.Refusal(.chosen, ["proposal \(plan.proposalID) was already chosen with another plan (query \(earlier.queryID)); "
                                                     + "propose again to choose otherwise"])
            }
            delivery = Self.render(chosen, queryID: earlier.queryID, proposal: proposal, sources: sources, request: request, state: state,
                                   recorded: false)
            return ChoiceAnswer(delivery: delivery, queryID: earlier.queryID, recordedNow: false)
        }
        return ChoiceAnswer(delivery: delivery, queryID: queryID, recordedNow: true)
    }

    /// Whether `id` names a proposal recorded for the task: what a use that names it instead of a query is told.
    public func isProposal(_ id: String, of taskID: String) async -> Bool {
        guard let recorded = try? await memory.perform({ try await $0.recall.proposal(id) }) else { return false }
        return recorded.proposal.taskID == taskID
    }

    // MARK: Rendering

    /// A proposal's text: per need the versions shortlisted and the suggestion; per version every step on one line.
    static func render(_ proposal: RecallChoice.Proposal, sources: [String: RecallSource], suggestions: [NeedOutcome],
                       context: RecallSelector.Context, values: [TaskValue], search: RecallDelivery.Search,
                       index: RecallDelivery.Index) -> RecallProposalDelivery {
        let candidates = RecallBinding.candidates(values)
        let needs = proposal.needs.enumerated().map { index, need -> RecallProposalDelivery.Need in
            let mine = proposal.shortlisted.filter { $0.needPosition == index }
            let suggested = mine.first { $0.suggested != nil }.map { item -> String in
                let range = item.suggested ?? 0...0
                let coverage = suggestions.indices.contains(index) ? suggestions[index].coverage.rawValue : "unknown"
                return "\(item.key) steps \(range.lowerBound + 1)–\(range.upperBound + 1) (\(coverage))"
            }
            var rendered = RecallProposalDelivery.Need(need: index + 1, text: need.text, app: need.bundleID.map(RecallDocument.applicationName),
                                                       sources: mine.map(\.key), suggested: suggested)
            // The plan item that chooses the suggestion, else the first source's steps a choice admits: one call to record
            // the reuse. A source with steps not offered gives its admitted runs, covering part of the need; one with none
            // gives no plan.
            let chosen = mine.first { $0.suggested != nil } ?? mine.first
            if let chosen, let source = sources[chosen.routeID], let first = source.steps.first?.position, let last = source.steps.last?.position {
                let runs = chosen.suggested.map { [$0] } ?? RecallChoice.admissibleRuns(of: source, need: need, context: context)
                if !runs.isEmpty {
                    // A suggestion covers the need as its coverage says; the source's own runs only when they are all of it.
                    let whole = chosen.suggested != nil
                        ? suggestions.indices.contains(index) && suggestions[index].coverage == .complete
                        : runs == [first...last]
                    let tracts = runs.map { #"{"source":"\#(chosen.key)","from":\#($0.lowerBound + 1),"to":\#($0.upperBound + 1)}"# }
                    let left = source.steps.map(\.position).filter { position in !runs.contains { $0.contains(position) } }
                    // Only the steps a source does not offer are named: a suggestion's other steps are offered, just not suggested.
                    let uncovered = whole || chosen.suggested != nil || left.isEmpty ? ""
                        : #","uncovered":"steps \#(left.map { String($0 + 1) }.joined(separator: ", ")) of \#(chosen.key) "#
                            + #"are not offered: do that work yourself""#
                    rendered.readyPlan = #"{"need":\#(index + 1),"tracts":[\#(tracts.joined(separator: ","))],"covered":"\#(whole ? "all" : "part")""#
                        + uncovered + "}"
                }
            }
            return rendered
        }
        var seen: Set<String> = []
        var rendered: [RecallProposalDelivery.Source] = []
        for item in proposal.shortlisted where !seen.contains(item.key) {
            seen.insert(item.key)
            guard let source = sources[item.routeID] else { continue }
            var excluded: [Int: [String]] = [:]
            for shortlisted in proposal.shortlisted where shortlisted.routeID == item.routeID {
                let need = proposal.needs[shortlisted.needPosition]
                for (position, reasons) in RecallSelector.exclusions(in: source, need: need, context: context) {
                    for reason in reasons {
                        let text = reason.kind == .certainConflict ? "fixes a choice the task's \(reason.taskValueName ?? "value") contradicts"
                            : "does what constraint \((reason.constraintPosition ?? 0) + 1) forbids"
                        if !(excluded[position] ?? []).contains(text) { excluded[position, default: []].append(text) }
                    }
                }
            }
            rendered.append(Self.render(source, key: item.key, relevance: proposal.shortlisted.filter { $0.routeID == item.routeID }.map(\.relevance).max() ?? item.relevance,
                                        excluded: excluded, candidates: candidates, values: values))
        }
        let guidance = search.status == SearchStatus.unavailable.rawValue || search.status == SearchStatus.failed.rawValue
            ? RecallProposalDelivery.unsearchedGuidance : rendered.isEmpty ? RecallProposalDelivery.nothingGuidance : RecallProposalDelivery.guidance
        return RecallProposalDelivery(proposal: proposal.proposalID, revision: proposal.revision, index: index, search: search, needs: needs,
                                      sources: rendered, guidance: guidance)
    }

    /// One shortlisted version, whole: its episodes, each step on one line, its parameters with how they bind, the outputs
    /// it declared and the inputs they fed, and its evidence.
    static func render(_ source: RecallSource, key: String, relevance: Double, excluded: [Int: [String]], candidates: [RecallBinding.Value],
                       values: [TaskValue]) -> RecallProposalDelivery.Source {
        let parameters = Dictionary(uniqueKeysWithValues: source.parameters.map { ($0.parameterID, $0) })
        func name(_ id: String) -> String { parameters[id]?.name ?? id }
        let steps = source.steps.map { step -> String in
            var line = "\(step.position + 1) [\(step.bundleID.map(RecallDocument.applicationName) ?? "?")] \(Self.operation(of: step, name: name))"
            if let label = step.label { line += " — \(label)" }
            if case .unknown = step.entry { line += " (entry not recorded)" }
            if !step.isOffered { line += " (not offered)" }
            if let reasons = excluded[step.position] { line += " (excluded: \(reasons.joined(separator: "; ")))" }
            return line
        }
        let episodes = source.units.map { unit in
            let range = unit.positions.lowerBound == unit.positions.upperBound ? "\(unit.positions.lowerBound + 1)"
                : "\(unit.positions.lowerBound + 1)–\(unit.positions.upperBound + 1)"
            return range + (unit.isUncertain ? "?" : "")
        }.joined(separator: " | ")
        var lines: [String] = []
        for parameter in source.parameters where parameter.direction != .output {
            var line = "{\(parameter.name)} (\(parameter.role)): "
            switch RecallBinding.bind(parameter, among: candidates) {
                case .bound(let value, let match):
                    let secret = values.first { $0.name == value.name }?.sensitivity == .secret
                    line += "bound to \(value.name) = \(secret ? "[withheld]" : value.text ?? "?") (by \(match.rawValue))"
                case .missing:
                    line += "missing from the task"
                case .ambiguous(let names):
                    line += "ambiguous among \(names.joined(separator: ", "))"
            }
            if let feed = source.feed(of: parameter), let part = feed.output.producedBy.flatMap({ id in source.parts.first { $0.partID == id } }) {
                line += "; in the source it \(feed.isSame ? "was" : "was derived from") {\(feed.output.name)}, produced at steps "
                    + "\(part.firstPosition + 1)–\(part.lastPosition + 1)"
            }
            lines.append(line)
        }
        let outputs = source.parameters.filter { $0.direction == .output }.compactMap { output -> String? in
            guard let part = output.producedBy.flatMap({ id in source.parts.first { $0.partID == id } }) else { return nil }
            return "{\(output.name)} (\(output.role)): produced at steps \(part.firstPosition + 1)–\(part.lastPosition + 1)"
        }
        let apps = Array(NSOrderedSet(array: source.steps.compactMap { $0.bundleID.map(RecallDocument.applicationName) })).compactMap { $0 as? String }
        let evidence = Self.evidence(of: source)
            + (source.confirmedUses > 0 ? "; carried out and verified in \(source.confirmedUses) earlier reuse(s)" : "")
        var rendered = RecallProposalDelivery.Source(source: key, version: source.routeID, procedure: source.procedureLabel, apps: apps,
                                                     relevance: (relevance * 1000).rounded() / 1000, episodes: episodes, steps: steps,
                                                     parameters: lines, outputs: outputs.isEmpty ? nil : outputs, evidence: evidence)
        rendered.result = source.results.isEmpty ? nil : source.results.map { $0.line() }
        return rendered
    }

    /// What a source's admission rests on, in words: its result checked by Braus, or its operations' own checks alone.
    static func evidence(of source: RecallSource) -> String {
        switch source.resultVerdict {
            case .passed?: "its result checked by Braus (\(source.results.map(\.expectation.kind).joined(separator: ", "))) and its steps' own checks"
            case .failed?: "its result checked by Braus failed: only steps verified on their own are offered"
            default: "steps individually qualified (each operation's own check; the task named no result Braus could read)"
        }
    }

    /// A step's recorded operation as one line: its tool and its arguments, fixed texts quoted, the task's values as
    /// `{parameter}`, menu paths as written.
    static func operation(of step: RecallSource.Step, name: (String) -> String) -> String {
        let arguments = step.arguments.filter(RecallService.isDelivered).map { argument -> String in
            let value: String = switch argument.value {
                case .literal(.text(let text)): "\"\(text)\""
                case .literal(.integer(let number)): String(number)
                case .literal(.real(let number)): String(number)
                case .literal(.boolean(let flag)): String(flag)
                case .parameter(let id): "{\(name(id))}"
                case .template(let segments): segments.map { segment -> String in
                    switch segment {
                        case .literal(let text): text
                        case .parameter(let id): "{\(name(id))}"
                    }
                }.joined()
                case .menu(let path): path
                case .anchor: "(an element)"
            }
            return "\(argument.name)=\(value)"
        }
        return ([step.tool.rawValue] + arguments).joined(separator: " ")
    }

    /// An admitted choice's delivery: per need, Engine's coverage, the agent's declaration, and each tract as a selection.
    static func render(_ chosen: [RecallChoice.Chosen], queryID: String, proposal: RecallChoice.Proposal, sources: [String: RecallSource],
                       request: RecallRequest, state: String, recorded: Bool) -> RecallChoiceDelivery {
        let candidates = RecallBinding.candidates(request.values)
        let delivered = state != "not_delivered"
        let needs = chosen.map { item -> RecallChoiceDelivery.Need in
            let tracts = delivered ? item.outcome.plan.compactMap { selection in
                sources[selection.routeID].map { Self.render(selection, source: $0, candidates: candidates, values: request.values,
                                                             constraints: request.constraints) }
            } : []
            var need = RecallChoiceDelivery.Need(need: item.outcome.need.text, app: item.outcome.need.bundleID,
                                                 coverage: item.outcome.coverage.rawValue, reason: item.outcome.reason?.rawValue,
                                                 declared: item.declared.rawValue, uncovered: item.uncovered, tracts: tracts)
            need.settledBy = item.settledBy
            if !item.outcome.alternatives.isEmpty {
                need.alternatives = item.outcome.alternatives.compactMap { alternative -> RecallDelivery.Alternative? in
                    guard let source = sources[alternative.routeID] else { return nil }
                    let labels = source.steps.filter { alternative.positions.contains($0.position) }.compactMap(\.label)
                    return RecallDelivery.Alternative(version: source.routeID, procedure: source.procedureLabel,
                                                      steps: "\(alternative.firstPosition + 1)–\(alternative.lastPosition + 1)",
                                                      labels: Array(labels.prefix(6)))
                }
            }
            return need
        }
        return RecallChoiceDelivery(query: queryID, proposal: proposal.proposalID, revision: proposal.revision,
                                    coverage: NeedOutcome.overall(chosen.map(\.outcome)).rawValue, delivery: state, recorded: recorded, needs: needs,
                                    guidance: !delivered
                                        ? "The chosen details exceed what one answer can carry, so none of them is given. Choose fewer tracts."
                                        : chosen.contains { $0.declared == .ambiguous }
                                        ? "An ambiguous need runs nothing: ask the person the question in uncovered, add the answer to the task "
                                            + "with memory_task update, and propose again. " + RecallDelivery.guidance
                                        : RecallDelivery.guidance)
    }
}
