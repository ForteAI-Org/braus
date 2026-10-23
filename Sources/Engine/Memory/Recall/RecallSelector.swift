//
//  RecallSelector.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// SelectionThresholds are the selector's calibrated constants, in the scale of one channel's relevance. They
/// are fixed on the development corpus before the final comparison and recorded with the configuration that
/// uses them; a result is never re-tuned on the final corpus.
public struct SelectionThresholds: Sendable, Equatable, Codable {
    /// Below it nothing in a source is relevant to the need: the need is absent from it.
    public var absolute: Double
    /// Read by selector 2 only (a step joined the selection while its relevance was within this of the best step's).
    /// Selector 3 delimits by the episodes the need names; the field stays for the calibrations that froze it.
    public var stepMargin: Double
    /// Read by selector 2 only (a whole part was proposed when its relevance, plus this, reached the best step's).
    /// Selector 3 proposes a whole part only when the episodes the need names span it.
    public var partMargin: Double
    /// Sources within this of the best one are adequate: the ranking orders them by coverage, preparations and
    /// evidence before relevance.
    public var adequacy: Double
    /// Adequate sources within this of each other, equal in coverage, preparations and evidence, are tied.
    public var tie: Double

    public init(absolute: Double, stepMargin: Double, partMargin: Double, adequacy: Double, tie: Double) {
        self.absolute   = absolute
        self.stepMargin = stepMargin
        self.partMargin = partMargin
        self.adequacy   = adequacy
        self.tie        = tie
    }
}

/// ScoredSource is a version with the relevance to one need of each of its steps and offered parts, in one
/// channel's scale, computed from the index for every part of the version, not only those it retrieved.
public struct ScoredSource: Sendable {
    public let source: RecallSource
    public let stepRelevance: [Int: Double]
    public let partRelevance: [String: Double]

    public init(source: RecallSource, stepRelevance: [Int: Double], partRelevance: [String: Double]) {
        self.source        = source
        self.stepRelevance = stepRelevance
        self.partRelevance = partRelevance
    }
}

/// RecallSelector decides, for one need, which ordered interval of which version to propose, by deterministic
/// rules over the D2 contracts. Facts decide what they can; the request's words decide the rest only where they name
/// the work unambiguously; similarity says whether a version is about the need at all, never how much of it to select
/// or that the need is covered. Documentation/Engine/RecallSelection.md gives each rule's data, conclusion and limit.
///
/// 1. **Exclusion.** A step is excluded with a certain reason: it fixes a choice (an item, a toggle's value) that a
///    value of the task concerning that choice contradicts (`certain_conflict`: a method that chooses JPEG for a task
///    that asks PNG), or it does what one of the task's constraints forbids (`constraint_excluded`, `RecallConstraint`).
///    Its whole episode goes with it, since the episode produces what the step chose; the version's other episodes stay
///    selectable; where the episodes are not known, the uncertain episodes next to it in its block go too. A choice
///    made with a parameter is never a conflict: a value the source never chose is a compatibility to check
///    (`compatibility_unknown`). Excluded episodes the need names or that are relevant to it are named in the outcome.
/// 2. **Episodes.** A version's steps are cut into episodes (`RecallSource.units`): a step that leaves its block's base
///    state unchanged is one, and every step from the one that leaves that state (opens a dialog, enters a mode) to the
///    one that returns to it is one. When the latest observation of the task's session shows a state that a step past
///    an episode's first started from, the episode is cut there (`RecallSource.episodes(from:)`): the steps before it
///    reached the state and are done. An observation describes the screen the selection starts from: when the need
///    names work before that state, the state will not hold then, and the version is read without the observation.
/// 3. **Delimitation.** A version is read only when its most relevant selectable step, or offered part holding one,
///    reaches the absolute threshold. The need names episodes (`Reading.naming`): its text, the task's values and the
///    placeholders taken out, is cut into clauses; a word several episodes of the version hold says what the version
///    works on, a word one episode alone holds points at it, and an application's name says where; each clause names
///    the episode alone in holding the most of its words that no other episode holds (a tie names none). A value of the
///    task the need mentions names the episode that alone reads it. Values only add to words the version recognizes as
///    naming its work: a word one episode alone holds, or one its labels give the work and no step spells. The
///    selection runs from the first named episode to the last; nothing is proposed when no episode is named, or when a
///    named episode is excluded (the need asks for work the version does incompatibly), or when an excluded, done or
///    other application's step lies between. Work before
///    the selection in its block is stated (`prepared_before`), never repeated unasked; work after it is left out.
/// 4. **Producers.** A part the selection starts in, ending before it does, whose outputs the task already holds is not
///    repeated (`output_ready`). An input the task does not hold, which the source's attempts state they took from the
///    output of an earlier part of the same version (`RecallSource.feed(of:)`: the binding's source and reference name
///    that output), brings that part and what follows it into the selection (`input_produced`); when the task holds
///    that output and the input is the output itself, the input takes its value (binding `produced`). Only declared
///    outputs and stated origins count: equal episodic values are no relation, a version that declares no output says
///    nothing of its producers, and an input whose origin is not stated is missing.
/// 5. **Prerequisites.** The selection starts in its block's base state, which the source reached by opening or
///    focusing the application or document (`entry_state`), or in the observed state it was cut at (`observed_state`):
///    conditions to prepare or confirm, not gaps. Steps of the same block before it are named (`prepared_before`): what
///    they left is stated by no contract. An episode whose start was not recorded in a known state, a step of a selected
///    episode the catalogue does not offer, or a selection that would start inside an episode is a gap: partial.
/// 6. **Binding.** The parameters the interval reads are bound to the task's current values (`RecallBinding`); a missing
///    or ambiguous one, or a value the task still lacks about a choice the selection fixes, leaves it ambiguous until
///    the agent resolves it. A constraint the selector does not check is carried as a condition.
/// 7. **Ranking.** Versions whose relevance is within `adequacy` of the best are ranked by coverage, then fewer
///    preparations, then evidence (a whole qualified part, confirmed reuses), then relevance, then the version's content
///    (fewer steps outside the selection, its label) before its random id; how many of the task's values a method takes
///    is no measure of the result it gives. Two tied selections that are variants of one method
///    (the same tools in order with the same fixed arguments but a choice: an item, a toggle's value, a menu path, a
///    button) lead to different results: when the need names the words of one side only (in its labels or in its
///    choices), that side is chosen; otherwise they are an ambiguity, no detail of either is delivered and both are
///    named. Tied selections that are different methods are not an ambiguity: the ranking proposes the first.
///
/// `SelectionThresholds.stepMargin` and `partMargin` are no longer read (selector 3): the extent of a selection is not a
/// matter of relevance.
public enum RecallSelector {

    /// Context is what a query gives the selection of each of its needs: the task's values and the candidates they
    /// offer a binding, its constraints, and the states the latest observation of its session showed.
    public struct Context: Sendable {
        public let values: [TaskValue]
        public let candidates: [RecallBinding.Value]
        public let constraints: [RecallConstraint]
        public let observed: Set<ObservedState>
        /// The clauses of each need named at creation, as operation words, its values and placeholders left out, and the
        /// names of the task's values its text mentions: computed once, read by every version.
        private var needWords: [String: Wording]

        /// Wording is what a need's text says to the selection: its clauses and the values it mentions.
        struct Wording: Sendable {
            let clauses: [Set<String>]
            let mentioned: Set<String>
        }

        public init(values: [TaskValue] = [], constraints: [String] = [], observed: Set<ObservedState> = [], needs: [RecallNeed] = []) {
            self.values      = values
            self.candidates  = RecallBinding.candidates(values)
            self.constraints = RecallConstraint.parse(constraints)
            self.observed    = observed
            var words: [String: Wording] = [:]
            for need in needs { words[need.text] = Self.words(need.text, values: values) }
            self.needWords   = words
        }

        /// The context with the words of `need` computed, when they were not.
        func knowing(_ need: RecallNeed) -> Context {
            guard needWords[need.text] == nil else { return self }
            var known = self
            known.needWords[need.text] = Self.words(need.text, values: values)
            return known
        }

        /// A need's clauses and mentioned values, as a step's operation words and parameters are compared with them.
        func wording(of need: RecallNeed) -> Wording {
            needWords[need.text] ?? Self.words(need.text, values: values)
        }

        /// The context without the observed states: for a need that names work before the state the observation shows.
        func ignoringObservation() -> Context {
            Context(values: values, candidates: candidates, constraints: constraints, observed: [], needWords: needWords)
        }

        private init(values: [TaskValue], candidates: [RecallBinding.Value], constraints: [RecallConstraint], observed: Set<ObservedState>,
                     needWords: [String: Wording]) {
            self.values      = values
            self.candidates  = candidates
            self.constraints = constraints
            self.observed    = observed
            self.needWords   = needWords
        }

        static func words(_ text: String, values: [TaskValue]) -> Wording {
            Wording(clauses: RecallText.clauses(RecallText.masked(text, values: values)), mentioned: RecallText.mentions(text, values: values))
        }
    }

    /// Proposal is one version's candidate selection for the need, before the ranking.
    public struct Proposal: Sendable {
        public let source: RecallSource
        public let positions: ClosedRange<Int>
        public let wholePart: RecallSource.Part?
        public let relevance: Double
        public let preparations: Int
        public let requirements: [RecallRequirement]
        public var coverage: RecallCoverage
        public var reason: CoverageReason?
        /// The words of the need the version accounts for nowhere (review F11).
        public var unaccounted: [String] = []
        /// Work the need names that the interval leaves out, behind a block of another application it does not ask for.
        public var leftOut: ClosedRange<Int>?

        func selection(role: RecallSelection.Role) -> RecallSelection {
            RecallSelection(role: role, routeID: source.routeID, firstPosition: positions.lowerBound, lastPosition: positions.upperBound,
                            wholePartID: wholePart?.partID, relevance: relevance, preparations: preparations,
                            requirements: role == .selected ? requirements : [])
        }

        var coverageRank: Int {
            switch coverage {
                case .complete: 0
                case .ambiguous: 1
                default: 2
            }
        }

        var evidenceRank: Int { (wholePart != nil ? 1_000_000 : 0) + source.confirmedUses }
    }

    /// The most excluded episodes an outcome names.
    static let exclusionLimit = 4

    /// The certain reasons that exclude steps of a version for a need, by position: a fixed choice the task's values
    /// contradict, or what a constraint forbids. What a proposal states of each version, and what a choice cannot override.
    public static func exclusions(in source: RecallSource, need: RecallNeed, context: Context) -> [Int: [RecallRequirement]] {
        Reading(ScoredSource(source: source, stepRelevance: [:], partRelevance: [:]), need: need, context: context.knowing(need),
                thresholds: RecallChoice.unread).reasons
    }

    /// The outcome for one need.
    public static func select(
        position  : Int,
        need      : RecallNeed,
        sources   : [ScoredSource],
        context   : Context,
        thresholds: SelectionThresholds
    ) -> NeedOutcome {
        var proposals: [Proposal] = []
        var excluded: [RecallSelection] = []
        let context = context.knowing(need)
        for scored in sources {
            let reading = Reading(scored, need: need, context: context, thresholds: thresholds)
            excluded += reading.excludedSelections()
            if let proposal = reading.proposal() { proposals.append(proposal) }
        }
        let named = Array(excluded.sorted { ($0.relevance, $1.routeID) > ($1.relevance, $0.routeID) }.prefix(exclusionLimit))
        guard let best = proposals.map(\.relevance).max() else {
            return NeedOutcome(position: position, need: need, coverage: .absent, reason: named.isEmpty ? nil : .excluded, selected: nil,
                               alternatives: [], excluded: named)
        }
        let ranked = proposals.filter { $0.relevance >= best - thresholds.adequacy }.sorted(by: precedes)
        var first = ranked[0]
        let tied = ranked.dropFirst().filter {
            $0.coverageRank == first.coverageRank && $0.preparations == first.preparations
                && $0.evidenceRank == first.evidenceRank && abs($0.relevance - first.relevance) <= thresholds.tie
        }
        let variants = tied.filter { variance(first, $0) != nil }
        if let second = variants.first, let (onlyFirst, onlySecond) = variance(first, second) {
            let needTokens = Set(RecallText.tokens(need.text))
            let wantsFirst = !onlyFirst.isDisjoint(with: needTokens)
            let wantsSecond = !onlySecond.isDisjoint(with: needTokens)
            if wantsSecond && !wantsFirst {
                first = second
            } else if wantsFirst == wantsSecond {
                let alternatives = [first] + variants
                return NeedOutcome(position: position, need: need, coverage: .ambiguous, reason: .alternatives, selected: nil,
                                   alternatives: alternatives.prefix(4).map { $0.selection(role: .alternative) }, excluded: named)
            }
        }
        return NeedOutcome(position: position, need: need, coverage: first.coverage, reason: first.reason,
                           selected: first.selection(role: .selected), alternatives: [], excluded: named, unaccounted: first.unaccounted,
                           leftOut: first.leftOut)
    }

    /// When two proposals are variants of one method, the words that tell each from the other: those of the labels
    /// of the steps that differ and of the choices they make. Nil when they are different methods (another tool, an
    /// order, a fixed argument other than a choice) or the same method with the same choices.
    static func variance(_ a: Proposal, _ b: Proposal) -> (Set<String>, Set<String>)? {
        let left = a.source.steps.filter { a.positions.contains($0.position) }
        let right = b.source.steps.filter { b.positions.contains($0.position) }
        guard left.count == right.count, !left.isEmpty else { return nil }
        var onlyLeft: Set<String> = [], onlyRight: Set<String> = []
        var differs = false
        for (x, y) in zip(left, right) {
            guard x.tool == y.tool else { return nil }
            let fixedX = fixed(x), fixedY = fixed(y)
            guard Set(fixedX.keys) == Set(fixedY.keys) else { return nil }
            for (name, value) in fixedX where !LabelTextKey.same(value, fixedY[name] ?? "") {
                guard choices.contains(name) else { return nil }
                differs = true
                onlyLeft.formUnion(RecallText.tokens(value + " " + (x.label ?? "")))
                onlyRight.formUnion(RecallText.tokens((fixedY[name] ?? "") + " " + (y.label ?? "")))
            }
        }
        guard differs else { return nil }
        let common = onlyLeft.intersection(onlyRight)
        return (onlyLeft.subtracting(common), onlyRight.subtracting(common))
    }

    /// The arguments a step makes a choice with: what a variant of a method may change.
    static let choices: Set<String> = ["item", "value", "path", "button"]

    /// A step's fixed arguments: the literals that are not the element it acts on.
    static func fixed(_ step: RecallSource.Step) -> [String: String] {
        let elements: Set<String> = ["target", "control", "from", "to", "section"]
        var fixed: [String: String] = [:]
        for argument in step.arguments where !elements.contains(argument.name) {
            switch argument.value {
                case .literal(let value):
                    let text: String = switch value {
                        case .text(let text): text
                        case .integer(let number): String(number)
                        case .real(let number): String(number)
                        case .boolean(let flag): String(flag)
                    }
                    fixed["\(argument.name)#\(argument.position)"] = text
                    if argument.position == 0 { fixed[argument.name] = text; fixed.removeValue(forKey: "\(argument.name)#0") }
                case .menu(let path):
                    fixed[argument.name] = path
                default:
                    continue
            }
        }
        return fixed
    }

    /// The order of adequate proposals (R49): coverage, then fewer preparations (an input still missing or ambiguous, a
    /// gap, a switch of application, an unknown compatibility, steps before the selection count as one each, so the method
    /// that uses what the task holds comes before one that needs more preparing), evidence, relevance. Between proposals
    /// equal in all of these, the version learned for that work alone comes first: fewer of its steps lie outside the
    /// proposal, then its label, then its id. Learning gives versions random ids, so the archive's content, not the ids,
    /// decides. How many of the task's values a method takes is no measure of the result it gives.
    static func precedes(_ a: Proposal, _ b: Proposal) -> Bool {
        if a.coverageRank != b.coverageRank { return a.coverageRank < b.coverageRank }
        if a.preparations != b.preparations { return a.preparations < b.preparations }
        if a.evidenceRank != b.evidenceRank { return a.evidenceRank > b.evidenceRank }
        if a.relevance != b.relevance { return a.relevance > b.relevance }
        let outsideA = a.source.steps.count - a.positions.count, outsideB = b.source.steps.count - b.positions.count
        if outsideA != outsideB { return outsideA < outsideB }
        if a.source.procedureLabel != b.source.procedureLabel { return a.source.procedureLabel < b.source.procedureLabel }
        return a.source.routeID < b.source.routeID
    }

    // MARK: One version

    /// The proposal of one version for the need, or nil when nothing in it is relevant and selectable.
    public static func proposal(for scored: ScoredSource, need: RecallNeed, context: Context, thresholds: SelectionThresholds) -> Proposal? {
        Reading(scored, need: need, context: context, thresholds: thresholds).proposal()
    }

    /// Reading is one version read for one need: its episodes from the observed state, the steps a certain reason
    /// excludes, the episodes the need names, the bindings of its parameters to the task's values, and which steps may be
    /// selected.
    struct Reading {
        let scored: ScoredSource
        let source: RecallSource
        let need: RecallNeed
        let context: Context
        let thresholds: SelectionThresholds
        let units: [RecallSource.Unit]
        let cuts: [RecallSource.Cut]
        /// The steps the observed state shows done.
        let reached: Set<Int>
        /// The certain reasons that exclude a step, by position.
        let reasons: [Int: [RecallRequirement]]
        /// The positions of every episode an excluded step belongs to.
        let excluded: Set<Int>
        /// The episodes the need names (rule 3), by index in `units`, in order.
        let named: [Int]
        let bindings: [String: RecallBinding.Outcome]
        /// The output of an earlier part each input took its value from in the source, as its attempts state it; and how
        /// each output binds to the task's values (bound: the task already holds it).
        let feeds: [String: RecallSource.Feed]
        let outputBindings: [String: RecallBinding.Outcome]
        let producers: [String: RecallSource.Part]
        /// The need's clauses, each as its operation words (its content words, the task's values and every placeholder
        /// left out), and the task's values its text mentions.
        let clauses: [Set<String>]
        let mentioned: Set<String>

        init(_ scored: ScoredSource, need: RecallNeed, context: Context, thresholds: SelectionThresholds) {
            let source = scored.source
            self.scored     = scored
            self.source     = source
            self.need       = need
            self.thresholds = thresholds
            let wording     = context.wording(of: need)
            let clauses     = wording.clauses
            self.clauses    = clauses
            self.mentioned  = wording.mentioned
            func inApplication(_ bundle: String?) -> Bool { need.bundleID == nil || bundle == nil || bundle == need.bundleID }
            var bindings: [String: RecallBinding.Outcome] = [:]
            for parameter in source.parameters where parameter.direction != .output {
                bindings[parameter.parameterID] = RecallBinding.bind(parameter, among: context.candidates)
            }
            self.bindings = bindings
            let parts = Dictionary(uniqueKeysWithValues: source.parts.map { ($0.partID, $0) })
            let outputs = source.parameters.filter { $0.direction == .output && $0.producedBy.flatMap { parts[$0] } != nil }
            var producers: [String: RecallSource.Part] = [:]
            var outputBindings: [String: RecallBinding.Outcome] = [:]
            for output in outputs {
                producers[output.parameterID] = output.producedBy.flatMap { parts[$0] }
                outputBindings[output.parameterID] = RecallBinding.bind(output, among: context.candidates)
            }
            var feeds: [String: RecallSource.Feed] = [:]
            for input in source.parameters where input.direction != .output {
                // An untyped task output cannot supply the unit evidence this input requires.
                guard input.unit?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                      !RecallBinding.hasIdentityCandidate(input, among: context.candidates) else { continue }
                guard let read = source.steps.first(where: { $0.parameterIDs.contains(input.parameterID) })?.position,
                      let feed = source.feed(of: input), let part = producers[feed.output.parameterID], part.lastPosition < read else { continue }
                feeds[input.parameterID] = feed
            }
            self.feeds          = feeds
            self.outputBindings = outputBindings
            self.producers      = producers
            // The task's values bound to a parameter of the version speak of that parameter, not of a fixed choice.
            let boundNames = Set(bindings.values.compactMap { outcome -> String? in
                guard case .bound(let value, _) = outcome else { return nil }
                return value.isDerived ? String(value.name.split(separator: ".").first ?? "") : value.name
            })
            var reasons: [Int: [RecallRequirement]] = [:]
            for step in source.steps {
                var mine: [RecallRequirement] = []
                if let name = step.choiceArgument, let argument = step.arguments.first(where: { $0.name == name }),
                   case .literal(.text(let fixed)) = argument.value {
                    for value in context.candidates where !value.isDerived && !boundNames.contains(value.name) {
                        guard !value.words.isDisjoint(with: step.choiceWords), let text = value.text, !LabelTextKey.same(text, fixed) else { continue }
                        mine.append(RecallRequirement(kind: .certainConflict, stepPosition: step.position, bundleID: step.bundleID,
                                                      taskValueName: value.name))
                    }
                }
                for constraint in context.constraints where constraint.forbids(step) {
                    mine.append(RecallRequirement(kind: .constraintExcluded, stepPosition: step.position, bundleID: step.bundleID,
                                                  constraintPosition: constraint.position))
                }
                if !mine.isEmpty { reasons[step.position] = mine }
            }
            self.reasons = reasons
            /// The episodes the need names among those of `units` in its application and not done, and those of them its words
            /// name. A word several of them hold says what the version works on, not which of its work is asked; a word one of
            /// them alone holds points at it; the name of an application the version runs in says where, not what. Each clause
            /// of the need names the episode alone in holding the most of its words that no other holds; when two hold as many,
            /// the clause names neither. A value of the task the need's text mentions names the episode that reads it, through
            /// the parameters bound to it, when no other does: the request states that episode's data (the title a step types,
            /// the invoice a step selects), while a value several episodes read (a name typed, then shared; a format chosen and
            /// its extension typed) points at none. Values only add to words the version recognizes as pointing at its work: a
            /// word one episode alone holds, or one the procedure's or a part's label gives the work and no step spells ("Create
            /// the event" over "Start a new event"). A need with neither (a request in another language than the labels, or one
            /// that shares only the object every episode works on: moving the event a version creates) names nothing in it.
            func naming(_ units: [RecallSource.Unit], reached: Set<Int>) -> [Int] {
                var words: [Int: Set<String>] = [:]
                var readers: [String: Set<Int>] = [:]
                for (index, unit) in units.enumerated() {
                    let steps = unit.positions.compactMap { source.step($0) }.filter { inApplication($0.bundleID) && !reached.contains($0.position) }
                    guard !steps.isEmpty else { continue }
                    words[index] = steps.reduce(into: Set<String>()) { $0.formUnion($1.operationWords) }
                    for id in steps.flatMap(\.parameterIDs) { readers[id, default: []].insert(index) }
                }
                let applications = Set(source.steps.compactMap(\.bundleID).flatMap { RecallText.tokens(RecallDocument.applicationName($0)) })
                // The words the version's own summaries give its work and no step spells: "Create the event" over the steps
                // "Start a new event" and "Add the event to the calendar".
                let spelled = source.steps.reduce(into: Set<String>()) { $0.formUnion($1.operationWords) }
                let summarized = Set(([source.procedureLabel] + source.parts.filter { $0.kind != .step }.compactMap(\.label))
                    .flatMap { RecallText.operationTokens($0) }).subtracting(spelled)
                var named: Set<Int> = []
                var recognized = false
                for clause in clauses.map({ $0.subtracting(applications) }) {
                    let held = words.mapValues { $0.intersection(clause) }
                    let alone = held.reduce(into: [Int: Set<String>]()) { result, entry in
                        let others = held.filter { $0.key != entry.key }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
                        let own = entry.value.subtracting(others)
                        if !own.isEmpty { result[entry.key] = own }
                    }
                    if !alone.isEmpty || !clause.isDisjoint(with: summarized) { recognized = true }
                    guard let best = alone.values.map(\.count).max() else { continue }
                    let leaders = alone.filter { $0.value.count == best }
                    if leaders.count == 1, let index = leaders.first?.key { named.insert(index) }
                }
                guard recognized else { return [] }
                var valueReaders: [String: Set<Int>] = [:]
                for (id, outcome) in bindings {
                    guard case .bound(let value, _) = outcome else { continue }
                    let name = value.isDerived ? String(value.name.split(separator: ".").first ?? "") : value.name
                    if wording.mentioned.contains(name) { valueReaders[name, default: []].formUnion(readers[id] ?? []) }
                }
                for reading in valueReaders.values where reading.count == 1 { named.formUnion(reading) }
                return named.sorted()
            }
            var episodes = source.episodes(from: context.observed)
            var reached = Set(episodes.cuts.flatMap { Array($0.reached) })
            var found = naming(episodes.units, reached: reached)
            // An observation describes the screen the selection starts from. When the need names work before the state it
            // shows, that state will not hold when the selection reaches it: the version is read whole, without it.
            if let cut = episodes.cuts.first, found.contains(where: { episodes.units[$0].positions.upperBound < cut.reached.lowerBound }) {
                episodes = (source.units, [])
                reached = []
                found = naming(episodes.units, reached: reached)
                self.context = context.ignoringObservation()
            } else {
                self.context = context
            }
            units        = episodes.units
            cuts         = episodes.cuts
            self.reached = reached
            // An excluded step takes its episode with it. Where the episodes are not known (a step whose start was not recorded in a
            // known state is an uncertain episode of its own), the episode it belongs to may run on into the uncertain episodes
            // after it, and, when its own start is unknown, back into those before it: they go with it, within its block. An
            // episode known to start in the block's base state is a boundary.
            var excluded: Set<Int> = []
            let episodeUnits = episodes.units
            for (index, unit) in episodeUnits.enumerated() where unit.positions.contains(where: { reasons[$0] != nil }) {
                excluded.formUnion(unit.positions)
                let block = source.block(of: unit.positions.lowerBound)
                var low = index
                while episodeUnits[low].isUncertain, low > 0, block.contains(episodeUnits[low - 1].positions.lowerBound) {
                    low -= 1
                    excluded.formUnion(episodeUnits[low].positions)
                }
                var high = index
                while high < episodeUnits.count - 1, episodeUnits[high + 1].isUncertain, block.contains(episodeUnits[high + 1].positions.lowerBound) {
                    high += 1
                    excluded.formUnion(episodeUnits[high].positions)
                }
            }
            self.excluded = excluded
            self.named = found
        }

        func inApplication(_ bundle: String?) -> Bool { need.bundleID == nil || bundle == nil || bundle == need.bundleID }

        /// Whether a step may be part of a selection: offered, in the need's application, not excluded, not done.
        func selectable(_ position: Int) -> Bool {
            guard let step = source.step(position) else { return false }
            return step.isOffered && inApplication(step.bundleID) && !excluded.contains(position) && !reached.contains(position)
        }

        func relevance(_ position: Int) -> Double? {
            selectable(position) ? scored.stepRelevance[position] : nil
        }

        /// The version's relevance to the need: its most relevant selectable step, or offered procedure or subprocedure
        /// holding one. It says whether the version is about the need at all (rule 3), never how much of it to select.
        var versionRelevance: Double {
            let steps = source.steps.compactMap { relevance($0.position) }
            let parts = source.parts.filter { part in
                part.kind != .step && part.isOffered && (part.firstPosition...part.lastPosition).contains(where: selectable)
            }.compactMap { scored.partRelevance[$0.partID] }
            return (steps + parts).max() ?? -.infinity
        }

        /// The excluded episodes the need names or that are relevant to it, each with the certain reasons of its steps.
        func excludedSelections() -> [RecallSelection] {
            units.enumerated().compactMap { index, unit -> RecallSelection? in
                let reasons = unit.positions.flatMap { self.reasons[$0] ?? [] }
                guard !reasons.isEmpty else { return nil }
                let relevant = unit.positions.compactMap { position -> Double? in
                    guard let step = source.step(position), step.isOffered, inApplication(step.bundleID), !reached.contains(position) else { return nil }
                    return scored.stepRelevance[position]
                }.max() ?? -.infinity
                guard named.contains(index) || relevant >= thresholds.absolute,
                      max(relevant, versionRelevance) >= thresholds.absolute else { return nil }
                return RecallSelection(role: .excluded, routeID: source.routeID, firstPosition: unit.positions.lowerBound,
                                       lastPosition: unit.positions.upperBound, wholePartID: nil, relevance: max(relevant, versionRelevance),
                                       preparations: 0, requirements: reasons)
            }
        }

        func proposal() -> Proposal? {
            // Retrieval: a version is read only when it is relevant to the need at all.
            let relevance = versionRelevance
            guard relevance >= thresholds.absolute else { return nil }
            // Delimitation: from the first episode the need names to the last. No named episode: the need's words do not say
            // which of this version's work it asks, and nothing is proposed from it. A named episode a certain reason excludes,
            // by its words or by a value it alone reads: the need asks for work this version does incompatibly, and nothing is
            // proposed from it (the exclusion is named).
            guard let first = named.first, let last = named.last else { return nil }
            guard !named.contains(where: { units[$0].positions.contains(where: excluded.contains) }) else { return nil }
            var positions = units[first].positions.lowerBound...units[last].positions.upperBound
            // Every step between belongs to the tract: one excluded, done or of another application than the need's breaks it.
            guard positions.allSatisfy({ position in
                !excluded.contains(position) && !reached.contains(position) && inApplication(source.step(position)?.bundleID)
            }) else { return nil }
            // A block of another application inside the tract none of whose episodes the need names is work the need does not ask
            // for, between work it does (review F10: a download between an export and the email of the export). One interval
            // cannot leave it out, so the tract keeps the named work after the last such block, and the named work before it is
            // left out, said, and its outputs stay missing with their producer named: partial. The agent's choice (experiment
            // A) can take both as separate tracts.
            var leftOut: ClosedRange<Int>?
            for block in source.blocks where block.lowerBound > positions.lowerBound && block.upperBound < positions.upperBound {
                let namedInside = named.contains { units[$0].positions.overlaps(block) }
                guard !namedInside else { continue }
                leftOut = positions.lowerBound...(block.lowerBound - 1)
                positions = (block.upperBound + 1)...positions.upperBound
            }
            var requirements: [RecallRequirement] = []
            // A step the catalogue does not offer is never delivered: the offered run around the first named episode remains,
            // and the steps it leaves out are gaps.
            let start = named.first { units[$0].positions.lowerBound >= positions.lowerBound } ?? first
            let anchor = units[start].positions.first { source.step($0)?.isOffered == true } ?? units[start].positions.lowerBound
            var low = anchor, high = anchor
            while low > positions.lowerBound, source.step(low - 1)?.isOffered == true { low -= 1 }
            while high < positions.upperBound, source.step(high + 1)?.isOffered == true { high += 1 }
            for missing in positions where (missing < low || missing > high) && source.step(missing)?.isOffered != true {
                requirements.append(RecallRequirement(kind: .prerequisiteOutOfCatalogue, stepPosition: missing,
                                                      bundleID: source.step(missing)?.bundleID))
            }
            positions = low...high
            positions = producing(positions, requirements: &requirements)
            // A clause whose work the version does not know may ask for work the selection does not do: the rotation a
            // synonym asked for ("turn … clockwise") is not covered because the export is (review F11). The rule cannot
            // read the synonym, so it declares a gap and names the word; the agent's choice (A) is what can.
            var proposal = evaluated(positions, requirements: requirements, relevance: relevance, unaccounted: unaccounted)
            if let leftOut {
                proposal.leftOut = leftOut
                if proposal.coverage != .partial { (proposal.coverage, proposal.reason) = (.partial, .gaps) }
            }
            return proposal
        }

        /// What an interval of the version requires, and its coverage: its entry or observed state, the steps of its block
        /// before it, its switches of application, the gaps inside it, the producers of the inputs it lacks, its bindings,
        /// compatibilities and the constraints it does not check. The automatic selection evaluates the interval it
        /// delimited, with `unaccounted` the clauses' verbs the version does not know (each leaves it partial); the agent's
        /// choice (`RecallChoice`) evaluates a tract the agent chose, with `planned` the earlier tracts of the same version
        /// in the same need: a producer one of them wholly includes is a producer the plan includes.
        func evaluated(_ positions: ClosedRange<Int>, requirements initial: [RecallRequirement], relevance: Double,
                       planned: [ClosedRange<Int>] = [], unaccounted: [String] = []) -> Proposal {
            var requirements = initial
            // What the selection starts from: an episode not known to start in its base state is a gap.
            let inside = units.filter { positions.contains($0.positions.lowerBound) }
            for unit in inside where unit.isUncertain {
                requirements.append(RecallRequirement(kind: .unknownEntryState, stepPosition: unit.positions.lowerBound,
                                                      bundleID: source.step(unit.positions.lowerBound)?.bundleID))
            }
            if let started = units.first(where: { $0.positions.contains(positions.lowerBound) }), started.positions.lowerBound < positions.lowerBound,
               !requirements.contains(where: { $0.stepPosition == positions.lowerBound }) {
                requirements.append(RecallRequirement(kind: .unknownEntryState, stepPosition: positions.lowerBound,
                                                      bundleID: source.step(positions.lowerBound)?.bundleID))
            }
            if let first = source.step(positions.lowerBound), first.entry == .notApplicable {
                requirements.insert(RecallRequirement(kind: .adapterAvailable, stepPosition: first.position,
                                                      bundleID: first.bundleID ?? first.tool.rawValue), at: 0)
            } else if let first = source.step(positions.lowerBound),
                      !requirements.contains(where: { $0.stepPosition == positions.lowerBound && $0.isGap }) {
                if case .state(let scene) = first.entry, let bundle = first.bundleID,
                   context.observed.contains(ObservedState(bundleID: bundle, sceneID: scene)) {
                    requirements.insert(RecallRequirement(kind: .observedState, stepPosition: first.position, sceneID: scene, bundleID: bundle),
                                        at: 0)
                } else {
                    let scene: String? = if case .state(let id) = first.entry { id } else { nil }
                    requirements.insert(RecallRequirement(kind: .entryState, stepPosition: first.position, sceneID: scene, bundleID: first.bundleID),
                                        at: 0)
                }
            }
            // Steps of the same block before the selection, other than those the observed state shows done.
            let block = source.block(of: positions.lowerBound)
            if let before = (block.lowerBound..<positions.lowerBound).last(where: { !reached.contains($0) }) {
                requirements.append(RecallRequirement(kind: .preparedBefore, stepPosition: before, bundleID: source.step(before)?.bundleID))
            }
            for block in source.blocks where positions.contains(block.lowerBound) && block.lowerBound > positions.lowerBound {
                let step = source.step(block.lowerBound)
                let kind: RecallRequirement.Kind = step?.entry == .notApplicable ? .adapterAvailable : .applicationSwitch
                requirements.append(RecallRequirement(kind: kind, stepPosition: block.lowerBound,
                                                      bundleID: step?.bundleID ?? step?.tool.rawValue))
            }

            // The parameters the interval reads, bound to the task's values; the choices made with them or fixed.
            let steps = source.steps.filter { positions.contains($0.position) }
            // P2-02, P2-05: a field filled from an earlier step's result is filled from this run's, and an account the source
            // named is resolved again: conditions of the reuse, never values of the source.
            for step in steps {
                if step.fields.contains(where: { if case .stepResult = $0.kind { true } else { false } }) {
                    requirements.append(RecallRequirement(kind: .stepResultPending, stepPosition: step.position))
                }
                if step.requiresAccountResolution { requirements.append(RecallRequirement(kind: .accountToResolve, stepPosition: step.position)) }
            }
            let parameters = Dictionary(uniqueKeysWithValues: source.parameters.map { ($0.parameterID, $0) })
            var read: [String] = []
            for step in steps { for id in step.parameterIDs where !read.contains(id) { read.append(id) } }
            var boundNames: Set<String> = []
            var bound: [String: RecallBinding.Value] = [:]
            for id in read {
                guard let parameter = parameters[id], parameter.direction != .output, var outcome = bindings[id] else { continue }
                if case .missing = outcome, let feed = feeds[id], let part = producers[feed.output.parameterID] {
                    if feed.isSame, case .bound(let value, _)? = outputBindings[feed.output.parameterID] {
                        // The task holds the output this input was in the source.
                        outcome = .bound(value, match: .produced)
                    } else if positions.contains(part.firstPosition)
                                || planned.contains(where: { $0.contains(part.firstPosition) && $0.contains(part.lastPosition) }) {
                        // The producer is in the interval, or in an earlier tract of the same plan.
                        requirements.append(RecallRequirement(kind: .inputProduced, stepPosition: part.firstPosition, parameterID: id))
                        continue
                    }
                }
                switch outcome {
                    case .bound(let value, let match):
                        bound[id] = value
                        boundNames.insert(value.isDerived ? String(value.name.split(separator: ".").first ?? "") : value.name)
                        requirements.append(RecallRequirement(kind: .parameterBound, parameterID: id, taskValueName: value.name,
                                                              bindingMatch: match))
                    case .missing:
                        requirements.append(RecallRequirement(kind: .parameterMissing, parameterID: id))
                    case .ambiguous(let names):
                        requirements.append(RecallRequirement(kind: .parameterAmbiguous, parameterID: id, candidates: names))
                }
            }
            let lacking = context.values.filter { $0.kind == .missing }
            for step in steps {
                guard let name = step.choiceArgument, let argument = step.arguments.first(where: { $0.name == name }) else { continue }
                switch argument.value {
                    case .parameter(let id):
                        guard let parameter = parameters[id], let value = bound[id]?.text, !parameter.observedValues.isEmpty else { continue }
                        let known = parameter.observedValues.contains { LabelTextKey.same($0, value) }
                        if !known { requirements.append(RecallRequirement(kind: .compatibilityUnknown, stepPosition: step.position, parameterID: id)) }
                    case .literal(.text):
                        // A value the task still lacks that concerns this choice: whether the fixed choice fits is open.
                        for value in lacking where !boundNames.contains(value.name) {
                            let words = Set(RecallText.tokens(value.name + " " + (value.role ?? "")))
                            guard !words.isDisjoint(with: step.choiceWords) else { continue }
                            requirements.append(RecallRequirement(kind: .unboundTaskInput, stepPosition: step.position, taskValueName: value.name))
                        }
                    default:
                        continue
                }
            }
            for constraint in context.constraints where constraint.hasUnchecked {
                requirements.append(RecallRequirement(kind: .constraintUnchecked, constraintPosition: constraint.position))
            }

            let coverage: RecallCoverage
            let reason: CoverageReason?
            if requirements.contains(where: \.isGap) || !unaccounted.isEmpty {
                (coverage, reason) = (.partial, .gaps)
            } else if requirements.contains(where: \.isUnresolvedInput) {
                (coverage, reason) = (.ambiguous, .unresolvedInput)
            } else {
                (coverage, reason) = (.complete, nil)
            }
            let preparations = requirements.filter {
                $0.isGap || $0.isUnresolvedInput || [.applicationSwitch, .compatibilityUnknown, .preparedBefore].contains($0.kind)
            }.count
            var proposal = Proposal(source: source, positions: positions, wholePart: source.wholePart(positions), relevance: relevance,
                                    preparations: preparations, requirements: requirements, coverage: coverage, reason: reason)
            proposal.unaccounted = unaccounted
            return proposal
        }

        /// The words that state the work of a clause of the need (its first content word, the verb of an imperative request)
        /// which the version accounts for nowhere: in no step's label or fixed text, no part's label, no parameter's name or
        /// role, and no application's name. The task's values are masked first. An object written otherwise ("photo" for
        /// "image") is not such a word; an action written otherwise ("turn … clockwise" for "rotate … right") is.
        var unaccounted: [String] {
            var vocabulary = source.steps.reduce(into: Set<String>()) { $0.formUnion($1.operationWords) }
            vocabulary.formUnion(([source.procedureLabel] + source.parts.compactMap(\.label)).flatMap { RecallText.operationTokens($0) })
            vocabulary.formUnion(source.parameters.flatMap { RecallText.tokens($0.name.replacingOccurrences(of: "_", with: " ") + " " + $0.role) })
            let applications = Set(source.steps.compactMap(\.bundleID).flatMap { RecallText.tokens(RecallDocument.applicationName($0)) })
            var words: [String] = []
            for lead in RecallText.clauseLeads(RecallText.masked(need.text, values: context.values)) {
                guard let token = RecallText.tokens(lead).first, !vocabulary.contains(token), !applications.contains(token),
                      !words.contains(lead) else { continue }
                words.append(lead)
            }
            return words
        }

        /// The interval without the producers of what the task holds, and with those of what it needs (rule 4).
        func producing(_ positions: ClosedRange<Int>, requirements: inout [RecallRequirement]) -> ClosedRange<Int> {
            guard !producers.isEmpty else { return positions }
            var positions = positions
            // A part the selection starts in, ending before it does, whose every output the task holds: the selection starts
            // after it.
            while true {
                let leading = source.parts.filter { part in
                    part.kind != .procedure && part.firstPosition <= positions.lowerBound && part.lastPosition >= positions.lowerBound
                        && part.lastPosition < positions.upperBound && units.contains { $0.positions.lowerBound == part.lastPosition + 1 }
                }.sorted { $0.lastPosition > $1.lastPosition }
                func ready(_ part: RecallSource.Part) -> [(String, RecallBinding.Value, RecallRequirement.BindingMatch)] {
                    producers.filter { $0.value.partID == part.partID }.keys.sorted().compactMap { id in
                        if case .bound(let value, let match)? = outputBindings[id] { (id, value, match) } else { nil }
                    }
                }
                guard let part = leading.first(where: { part in
                    let produced = producers.filter { $0.value.partID == part.partID }.count
                    return produced > 0 && ready(part).count == produced
                }) else { break }
                for (id, value, match) in ready(part) {
                    requirements.append(RecallRequirement(kind: .outputReady, stepPosition: part.firstPosition, parameterID: id,
                                                          taskValueName: value.name, bindingMatch: match))
                }
                positions = (part.lastPosition + 1)...positions.upperBound
            }
            // An input the task does not hold, fed in the source by an earlier part's output it does not hold either: the
            // selection includes that part when nothing else lies between them (review F10). Steps between the producer and
            // the selection are included only when they belong to an episode of either, since an episode is not split; any
            // other step there is work the need does not ask for and the dependency does not need. Then the input stays
            // missing and its producer is named (`dependency(of:)`), without proposing that work. A producer of another
            // input lying between is included first, which makes the farther one adjacent.
            var extended = true
            while extended {
                extended = false
                for id in source.steps.filter({ positions.contains($0.position) }).flatMap(\.parameterIDs) {
                    guard case .missing? = bindings[id], let feed = feeds[id], let part = producers[feed.output.parameterID],
                          part.firstPosition < positions.lowerBound else { continue }
                    // An output the task holds is not produced again, even when the input is derived from it.
                    if case .bound? = outputBindings[feed.output.parameterID] { continue }
                    guard (part.firstPosition..<positions.lowerBound).allSatisfy(selectable) else { continue }
                    // A producer that reaches the selection leaves nothing between them.
                    let between = min(part.lastPosition + 1, positions.lowerBound)..<positions.lowerBound
                    guard between.allSatisfy({ position in
                        units.contains { $0.positions.contains(position)
                            && ($0.positions.overlaps(part.firstPosition...part.lastPosition) || $0.positions.contains(positions.lowerBound)) }
                    }) else { continue }
                    positions = part.firstPosition...positions.upperBound
                    extended = true
                    break
                }
            }
            return positions
        }

        /// The part that produced, in the source, the value an input missing from the task took, as the source's attempts
        /// state it: a dependency to prepare when the selection does not include its producer.
        func dependency(of parameterID: String) -> RecallSource.Part? {
            guard case .missing? = bindings[parameterID], let feed = feeds[parameterID] else { return nil }
            if case .bound? = outputBindings[feed.output.parameterID] { return nil }
            return producers[feed.output.parameterID]
        }
    }
}

/// LabelTextKey compares two values a choice is made with as an application shows them: case, diacritics and
/// surrounding space aside.
enum LabelTextKey {
    static func same(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key(a) == key(b)
    }
}
