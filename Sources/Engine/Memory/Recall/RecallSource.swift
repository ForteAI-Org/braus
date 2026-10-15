//
//  RecallSource.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// RecallSource is one version as the selector reads it: its steps in order with their parts, labels,
/// applications, operations and entry states, its parts with whether the catalogue offers each now, its
/// parameters with their roles, and the reuses of it the system confirmed. It is read from the authoritative
/// tables at the moment of the query, never from the index: an index only says which versions to read.
/// `observedValues` are the episodic values the source's own attempt bound, kept in memory to tell a known
/// value from a new one; they are never delivered or recorded with a query.
public struct RecallSource: Sendable {

    /// Entry is the functional state a step started from in the source: a structural scene, or unknown.
    public enum Entry: Sendable, Equatable {
        case state(String)
        case unknown
    }

    public struct Step: Sendable {
        public let position: Int
        public let partID: String
        public let label: String?
        public let bundleID: String?
        public let tool: AgentTool
        public let arguments: [OperationArgument]
        public let entry: Entry
        /// The functional state the step's call left the window in, as its sample after acting was placed.
        public let exit: Entry
        public let isOffered: Bool
        /// The functional identity of the element the source's call acted on, when the Brain identified it: what a
        /// later call must act on to carry out this step when the element's label changes with its value.
        public let elementKey: String?
        /// The content words of the control a choice is made on (a pop-up's title, a contextual menu's element): what a
        /// value of the task must name to concern this choice. A label's words are not enough: a value named `file_name`
        /// does not concern a filter chosen in a step labelled with the word file. Computed once.
        let choiceWords: Set<String>
        /// The step's own words: its label and its fixed texts, as a constraint is compared with them.
        let words: Set<String>
        /// The words that state the step's operation: its label's and its fixed texts', its parameters' placeholders left
        /// out, as a need names the step with them.
        let operationWords: Set<String>

        public init(position: Int, partID: String, label: String?, bundleID: String?, tool: AgentTool, arguments: [OperationArgument],
                    entry: Entry, exit: Entry = .unknown, isOffered: Bool, elementKey: String? = nil) {
            self.position  = position
            self.partID    = partID
            self.label     = label
            self.bundleID  = bundleID
            self.tool      = tool
            self.arguments = arguments
            self.entry     = entry
            self.exit      = exit
            self.isOffered = isOffered
            self.elementKey = elementKey
            let controlName: String? = switch tool {
                case .select     : "control"
                case .contextMenu: "target"
                default          : nil
            }
            let control: String? = controlName.flatMap { name in arguments.first { $0.name == name } }.flatMap {
                if case .literal(.text(let text)) = $0.value { return text } else { return nil }
            }
            self.choiceWords = Set(RecallText.tokens(control ?? ""))
            var texts = [label ?? ""]
            for argument in arguments {
                switch argument.value {
                    case .literal(.text(let text)), .menu(let text): texts.append(text)
                    default: continue
                }
            }
            self.words = Set(RecallText.tokens(texts.joined(separator: " ")))
            self.operationWords = Set(RecallText.operationTokens(texts.joined(separator: " ")))
        }

        /// The ids of the parameters the step's operation reads, in order, once each.
        public var parameterIDs: [String] {
            var ids: [String] = []
            for argument in arguments {
                switch argument.value {
                    case .parameter(let id): if !ids.contains(id) { ids.append(id) }
                    case .template(let segments):
                        for case .parameter(let id) in segments where !ids.contains(id) { ids.append(id) }
                    default: break
                }
            }
            return ids
        }

        /// The name of the argument a choice is made with, for a tool whose effect depends on it: the item of a
        /// pop-up or of a contextual menu.
        public var choiceArgument: String? {
            switch tool {
                case .select, .contextMenu: "item"
                default: nil
            }
        }

        /// The label of the control a choice is made on, as the source named it (a pop-up's title).
        public var choiceControl: String? {
            guard tool == .select else { return nil }
            return arguments.first { $0.name == "control" }.flatMap {
                if case .literal(.text(let text)) = $0.value { return text } else { return nil }
            }
        }
    }

    public struct Part: Sendable {
        public let partID: String
        public let kind: PartKind
        public let firstPosition: Int
        public let lastPosition: Int
        public let label: String?
        public let bundleID: String?
        public let isOffered: Bool

        public init(partID: String, kind: PartKind, firstPosition: Int, lastPosition: Int, label: String?, bundleID: String?,
                    isOffered: Bool) {
            self.partID        = partID
            self.kind          = kind
            self.firstPosition = firstPosition
            self.lastPosition  = lastPosition
            self.label         = label
            self.bundleID      = bundleID
            self.isOffered     = isOffered
        }
    }

    public struct Parameter: Sendable {
        public let parameterID: String
        public let name: String
        public let role: String
        public let kind: TaskValueKind
        public let direction: ParameterDirection
        public let unit: String?
        public let observedValues: [String]
        /// For an output, the part that produced it, as the contract says.
        public let producedBy: String?
        /// Where the value came from in each attempt of the version that bound it, as its binding states.
        public let origins: [Origin]
        /// The content words of the name and of the role, as the binding compares them: computed once.
        let nameKey: String
        let roleKey: String
        let words: Set<String>

        public init(parameterID: String, name: String, role: String, kind: TaskValueKind, direction: ParameterDirection, unit: String?,
                    observedValues: [String], producedBy: String? = nil, origins: [Origin] = []) {
            self.parameterID    = parameterID
            self.name           = name
            self.role           = role
            self.kind           = kind
            self.direction      = direction
            self.unit           = unit
            self.observedValues = observedValues
            self.producedBy     = producedBy
            self.origins        = origins
            self.nameKey        = RecallText.tokens(name).joined(separator: " ")
            self.roleKey        = RecallText.tokens(role).joined(separator: " ")
            self.words          = Set(RecallText.tokens(name + " " + role))
        }
    }

    /// Origin is where a parameter's value came from in one attempt of the version, as the attempt's binding states it
    /// (`memory_parameter_bindings`): the source, what the source names and its version, the attempt and its task, and
    /// the value when it was kept.
    public struct Origin: Sendable, Equatable {
        public let source: TaskValueSource
        public let reference: String?
        public let referenceVersion: String?
        public let attemptID: String
        public let taskID: String
        public let value: String?

        public init(source: TaskValueSource, reference: String?, referenceVersion: String? = nil, attemptID: String, taskID: String,
                    value: String?) {
            self.source           = source
            self.reference        = reference
            self.referenceVersion = referenceVersion
            self.attemptID        = attemptID
            self.taskID           = taskID
            self.value            = value
        }
    }

    /// Feed is the output of a part of the version that an input took its value from, as the attempts state it.
    public struct Feed: Sendable {
        public let output: Parameter
        /// Whether the input is that output itself (`previous_output`), not a value derived from it (`derived`): only
        /// then does an output the task already holds give the input its value.
        public let isSame: Bool
        /// The attempts' statements the feed rests on.
        public let origins: [Origin]
    }

    /// The output an input was fed by, or nil when the facts do not prove one. Every attempt that states where the
    /// input came from must name the same output of the version, produced by a part, with source `previous_output`
    /// (the output itself) or `derived` (a value derived from it). The reference names the output as the interpretation
    /// does, by its name, or as D1 names an output of a task, `<task id>/<output name>` with the attempt's own task. A
    /// statement of another source (the request, a message, an observation) or of another output contradicts it;
    /// `unknown` states nothing. Taken as itself, the output must be of the input's kind and, when both values were
    /// kept, have the input's value. Equal values alone never make a feed: two values can be equal by chance, and a
    /// producer declared for an output says nothing of who consumes it.
    public func feed(of input: Parameter) -> Feed? {
        guard input.direction != .output else { return nil }
        var found: Parameter?
        var same = true
        var statements: [Origin] = []
        for origin in input.origins where origin.source != .unknown {
            guard origin.source == .previousOutput || origin.source == .derived, let reference = origin.reference else { return nil }
            let task = origin.taskID + "/"
            let name = reference.utf8.starts(with: task.utf8) ? String(reference.utf8.dropFirst(task.utf8.count)) ?? "" : reference
            guard let output = parameters.first(where: { $0.direction == .output && $0.producedBy != nil && $0.name.utf8.elementsEqual(name.utf8) }),
                  found == nil || found?.parameterID == output.parameterID else { return nil }
            if origin.source == .previousOutput {
                guard output.kind == input.kind else { return nil }
                if let value = origin.value, !output.observedValues.isEmpty, !output.observedValues.contains(where: { $0.utf8.elementsEqual(value.utf8) }) {
                    return nil
                }
            } else {
                same = false
            }
            found = output
            statements.append(origin)
        }
        return found.map { Feed(output: $0, isSame: same, origins: statements) }
    }

    public let routeID: String
    public let procedureLabel: String
    public let steps: [Step]
    public let parts: [Part]
    public let parameters: [Parameter]
    public let confirmedUses: Int
    /// Result is one check of the source's result as a reuse receives it: a template over the source's parameters
    /// (`TaskResultCheck.Expectation.template`) and when it was made, after which step of the version; at the end when it
    /// followed the last one.
    public struct Result: Sendable, Equatable {
        public let expectation: TaskResultCheck.Expectation
        /// The version's step the check followed, nil when it followed none.
        public let afterStep: Int?
        public let atEnd: Bool

        public init(expectation: TaskResultCheck.Expectation, afterStep: Int?, atEnd: Bool) {
            self.expectation = expectation
            self.afterStep   = afterStep
            self.atEnd       = atEnd
        }

        /// The check in one line with when to make it: `at the end: file_written …`, `after step 2, at a checkpoint: element …`.
        public func line(_ expectation: TaskResultCheck.Expectation? = nil) -> String {
            let when = atEnd ? "at the end" : afterStep.map { "after step \($0 + 1), at a checkpoint before what shows it goes away" }
                ?? "at the end"
            return "\(when): \((expectation ?? self.expectation).line)"
        }
    }

    /// What the source's attempt checked its result by (`TaskResultCheck`), as templates over its parameters with when each
    /// was made: how a reuse verifies the same kind of result. Empty when the attempt named none.
    public var results: [Result] = []
    /// The verdict those checks gave the procedure, nil when there were none.
    public var resultVerdict: VerificationVerdict?

    /// The blocks of consecutive steps on one application, as intervals: the subprocedures, or the whole
    /// procedure when it is one block.
    public let blocks: [ClosedRange<Int>]
    /// The episodes of every block, in order (`Unit`): computed once, read by every selection.
    public let units: [Unit]

    public init(routeID: String, procedureLabel: String, steps: [Step], parts: [Part], parameters: [Parameter], confirmedUses: Int) {
        let steps = steps.sorted { $0.position < $1.position }
        self.routeID        = routeID
        self.procedureLabel = procedureLabel
        self.steps          = steps
        self.parts          = parts
        self.parameters     = parameters
        self.confirmedUses  = confirmedUses
        let blocks          = Self.blocks(steps: steps, parts: parts)
        self.blocks         = blocks
        self.units          = Self.units(steps: steps, blocks: blocks)
    }

    static func blocks(steps: [Step], parts: [Part]) -> [ClosedRange<Int>] {
        let subprocedures = parts.filter { $0.kind == .subprocedure }.sorted { $0.firstPosition < $1.firstPosition }
        if !subprocedures.isEmpty { return subprocedures.map { $0.firstPosition...$0.lastPosition } }
        guard let first = steps.first?.position, let last = steps.last?.position else { return [] }
        return [first...last]
    }

    /// The block holding a step.
    public func block(of position: Int) -> ClosedRange<Int> {
        blocks.first { $0.contains(position) } ?? (position...position)
    }

    public func step(_ position: Int) -> Step? {
        steps.first { $0.position == position }
    }

    /// Unit is an episode of a block that is never split: one step that leaves the block's base state unchanged, or
    /// every step from the one that leaves it (opens a dialog, enters a mode) to the one that returns to it. A unit
    /// whose start is not known to be in the base state is `uncertain`: what prepares it was not recorded.
    public struct Unit: Sendable, Equatable {
        public let positions: ClosedRange<Int>
        public let isUncertain: Bool
    }

    /// The units of every block, in order. The base state of a block is its first step's entry state, which the
    /// source reached by opening or focusing the application; the state after a step is its own sample's, or the
    /// next step's entry when that was not placed.
    static func units(steps: [Step], blocks: [ClosedRange<Int>]) -> [Unit] {
        let byPosition = Dictionary(steps.map { ($0.position, $0) }, uniquingKeysWith: { first, _ in first })
        /// The state after a step: its own sample's, else the next step's entry in the same block; nil when unknown.
        func state(after position: Int, in block: ClosedRange<Int>) -> String? {
            if case .state(let id)? = byPosition[position]?.exit { return id }
            guard position < block.upperBound, case .state(let id)? = byPosition[position + 1]?.entry else { return nil }
            return id
        }
        var units: [Unit] = []
        for block in blocks {
            guard case .state(let base)? = byPosition[block.lowerBound]?.entry else {
                units += block.map { Unit(positions: $0...$0, isUncertain: $0 != block.lowerBound) }
                continue
            }
            var position = block.lowerBound
            while position <= block.upperBound {
                guard byPosition[position]?.entry == .state(base) else {
                    units.append(Unit(positions: position...position, isUncertain: true))
                    position += 1
                    continue
                }
                var last = position
                while last < block.upperBound, let after = state(after: last, in: block), after != base { last += 1 }
                units.append(Unit(positions: position...last, isUncertain: false))
                position = last + 1
            }
        }
        return units
    }

    /// Cut is where the observed state meets a version: a step past an episode's first that started from the state
    /// the latest observation shows. The steps of the episode before it reached that state and are done.
    public struct Cut: Sendable, Equatable {
        public let position: Int
        public let state: ObservedState
        public let reached: ClosedRange<Int>
    }

    /// The episodes of the version as they stand from the observed states, and where they were cut. An episode known
    /// to start in its block's base state, with a step past its first that started from an observed state, is cut at
    /// the first such step: the steps before it are one episode, done; from it on, the steps are the episodes of that
    /// state, as a block's are of its base (one step that keeps it, or from the one that leaves it to the one that
    /// returns). Nothing is cut when no state is observed, or none the version's steps started from.
    public func episodes(from observed: Set<ObservedState>) -> (units: [Unit], cuts: [Cut]) {
        guard !observed.isEmpty else { return (units, []) }
        var result: [Unit] = []
        var cuts: [Cut] = []
        for unit in units {
            let found = unit.isUncertain ? nil : unit.positions.dropFirst().lazy.compactMap { position -> (Int, ObservedState)? in
                guard let step = self.step(position), case .state(let scene) = step.entry, let bundle = step.bundleID else { return nil }
                let state = ObservedState(bundleID: bundle, sceneID: scene)
                return observed.contains(state) ? (position, state) : nil
            }.first
            guard let (position, state) = found else {
                result.append(unit)
                continue
            }
            let reached = unit.positions.lowerBound...(position - 1)
            result.append(Unit(positions: reached, isUncertain: false))
            let rest = position...unit.positions.upperBound
            result += Self.units(steps: steps.filter { rest.contains($0.position) }, blocks: [rest])
            cuts.append(Cut(position: position, state: state, reached: reached))
        }
        return (result, cuts)
    }

    /// The offered part whose interval is exactly `positions`, the coarsest first: what a selection is whole.
    public func wholePart(_ positions: ClosedRange<Int>) -> Part? {
        parts.filter { $0.isOffered && $0.firstPosition == positions.lowerBound && $0.lastPosition == positions.upperBound }
            .min { $0.kind.rank < $1.kind.rank }
    }
}
