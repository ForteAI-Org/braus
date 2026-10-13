//
//  BrainRelation.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import PerceptionCore

/// BrainVerb is the precise operation a relation was learned under: each act verb on its own, so a
/// double click that opens a file teaches nothing about the click that selects it, and every other UI
/// tool by its name. A shortcut is `press_key` with its modifiers in the relation's arguments.
public enum BrainVerb: String, Sendable, Equatable, Hashable, CaseIterable {
    case click
    case doubleClick  = "double_click"
    case tripleClick  = "triple_click"
    case rightClick   = "right_click"
    case setToggle    = "set_toggle"
    case select
    case typeText     = "type_text"
    case insertText   = "insert_text"
    case pressKey     = "press_key"
    case scroll
    case drag
    case contextMenu  = "context_menu"
    case menu
    case press

    /// The verb of an act verb.
    public init(_ verb: ActionVerb) {
        switch verb {
            case .click      : self = .click
            case .doubleClick: self = .doubleClick
            case .tripleClick: self = .tripleClick
            case .rightClick : self = .rightClick
            case .setToggle  : self = .setToggle
        }
    }
}

/// BrainRelationOutcome is what a relation leads to, as the verification that supports it judged it: a
/// structural effect of a family, a control's state set, a state already present (a no-op, from a state
/// to itself), a value read back, a contextual item chosen, the window set changed. A diff belongs to
/// the transition that made it; a direct reading keeps its own kind and is never called a diff.
public enum BrainRelationOutcome: String, Sendable, Equatable, Hashable, CaseIterable {
    case effect
    case stateSet         = "state_set"
    case alreadySatisfied = "already_satisfied"
    case valueSet         = "value_set"
    case itemChosen       = "item_chosen"
    case windowSetChanged = "window_set_changed"
}

/// BrainRelationKey is the identity of a relation: the application and its context (version and
/// locale, unknown alike), the functional state it starts from, the structural element it acts on (nil
/// for a verb aimed at the focus or the window), the verb and the arguments that change its meaning,
/// the state it reaches (nil when not recognized), the outcome and, for an effect, its family. The
/// values a call carried (a typed text, a document's name, a row's content, a count of lines) are no
/// part of it: they stay in the calls its proofs name, so new names never multiply relations.
public struct BrainRelationKey: Sendable, Equatable, Hashable {
    public let bundleID: String
    public let contextID: Int64?
    public let fromSceneID: String
    public let elementKey: String?
    public let verb: BrainVerb
    public let argumentsKey: String
    public let toSceneID: String?
    public let outcome: BrainRelationOutcome
    public let effectKind: String?

    public init(bundleID: String, contextID: Int64?, fromSceneID: String, elementKey: String?, verb: BrainVerb,
                argumentsKey: String, toSceneID: String?, outcome: BrainRelationOutcome, effectKind: String?) {
        self.bundleID     = bundleID
        self.contextID    = contextID
        self.fromSceneID  = fromSceneID
        self.elementKey   = elementKey
        self.verb         = verb
        self.argumentsKey = argumentsKey
        self.toSceneID    = outcome == .alreadySatisfied ? fromSceneID : toSceneID
        self.outcome      = outcome
        self.effectKind   = outcome == .effect ? effectKind : nil
    }

    /// The group the relation belongs to: the same start, element, verb and arguments, whatever it
    /// led to. Alternatives are the relations of one group.
    public var group: Group {
        Group(bundleID: bundleID, contextID: contextID, fromSceneID: fromSceneID, elementKey: elementKey, verb: verb,
              argumentsKey: argumentsKey)
    }

    /// Group is the identity of what was done where, apart from what it led to.
    public struct Group: Sendable, Equatable, Hashable {
        public let bundleID: String
        public let contextID: Int64?
        public let fromSceneID: String
        public let elementKey: String?
        public let verb: BrainVerb
        public let argumentsKey: String

        /// The key of the group's relations of one outcome: what a failed verification that found none
        /// to contradict waits for, so the relation that appears later is contradicted by it.
        public func key(outcome: BrainRelationOutcome) -> String {
            let canonical = [bundleID, contextID.map(String.init), fromSceneID, elementKey, verb.rawValue, argumentsKey,
                             outcome.rawValue].map(CanonicalText.field).joined(separator: "\n")
            return "group-\(StructuralDigest.fnv1a(canonical))-\(canonical.utf8.count)"
        }
    }

    /// The relation's id: a digest of its canonical rendering, prefixed for reading. Two relations with
    /// equal ids are compared by their columns too.
    public var relationID: String {
        let canonical = [bundleID, contextID.map(String.init), fromSceneID, elementKey, verb.rawValue, argumentsKey, toSceneID,
                         outcome.rawValue, effectKind].map(CanonicalText.field).joined(separator: "\n")
        return "relation-\(StructuralDigest.fnv1a(canonical))-\(canonical.utf8.count)"
    }
}

/// BrainRelationPolicy is version 2 of the rule that turns one concluded call into what it teaches the
/// relations, a pure function of the call's recorded facts: the request, the state the call ended in,
/// its recording gaps and withheld values, its one verification, and the structural states its samples
/// were confirmed in. A positive verification supports one relation; a failed one contradicts the
/// relations of its group that predicted what failed; anything else teaches nothing and says why. A
/// recovery gesture that replaced the request never teaches the requested verb; a no-op teaches the
/// state already present and no gesture; an extraneous change the oracle could not attribute stays
/// unknown.
///
/// Version 2 identifies the element a call acted on as an instance of its capture
/// (`SceneElementKey.Identity`): a target that names several physical elements is ambiguous, one whose
/// structural key another element of the capture shares is indistinct, and neither teaches a relation.
/// It keeps in a relation's arguments what decides its effect for every family (`argumentRoles`): the
/// item chosen, the count of a key, the destination of a drag. And it tells an exclusion waiting for
/// evidence that may still arrive (a sample not yet placed, a call not yet concluded, a failure with no
/// relation yet to contradict) from one that is final.
public enum BrainRelationPolicy {

    public static let version = "brain-relations-2"

    /// Exclusion is why a call teaches no relation.
    public enum Exclusion: String, Sendable, Equatable, Hashable, CaseIterable {
        case notAnOperation        = "not_an_operation"
        case notConcluded          = "not_concluded"
        case callFailed            = "call_failed"
        case recordingGap          = "recording_gap"
        case noVerification        = "no_verification"
        case verdictUnknown        = "verdict_unknown"
        case noOracle              = "no_oracle"
        case substituteGesture     = "substitute_gesture"
        case deliveryUncertain     = "delivery_uncertain"
        case valueWithheld         = "value_withheld"
        case noBeforeState         = "no_before_state"
        case awaitingState         = "awaiting_state"
        case noStructuralElement   = "no_structural_element"
        case ambiguousElement      = "ambiguous_element"
        case indistinctElement     = "indistinct_element"
        case nothingToContradict   = "nothing_to_contradict"
        case notLearnable          = "not_learnable"
        case noApplication         = "no_application"

        /// Whether the evidence the exclusion lacks may still arrive, so the call is evaluated again
        /// when it does: a complete sample not yet placed in a state, a call not yet concluded, a failed
        /// verification with no relation of its group yet. Every other exclusion is final for the
        /// policy that made it.
        public var isRecoverable: Bool {
            switch self {
                case .awaitingState, .notConcluded, .nothingToContradict: true
                default: false
            }
        }
    }

    /// ArgumentRole is what one argument of an operation is to a relation: fixed, in the relation's key,
    /// because it decides the effect (a toggle's requested state, a key, the item of a choice); a
    /// parameter, out of the key, because a new value repeats the method (a typed text, a count of lines,
    /// a drag's distance); or the element, the structural identity of what is acted on.
    public enum ArgumentRole: String, Sendable, Equatable, CaseIterable {
        case fixed, parameter, element
    }

    /// For every family, what each argument of its request is to a relation. Nothing else of a request
    /// is kept by a relation: the section a target was looked for in is a search hint.
    public static let argumentRoles: [BrainVerb: [(argument: String, role: ArgumentRole)]] = [
        .click: [("target", .element)], .doubleClick: [("target", .element)], .tripleClick: [("target", .element)],
        .rightClick: [("target", .element)],
        .setToggle: [("target", .element), ("value", .fixed)],
        .select: [("control", .element), ("item", .fixed)],
        .typeText: [("target", .element), ("replace", .fixed), ("text", .parameter)],
        .insertText: [("text", .parameter), ("expected_value", .parameter)],
        .pressKey: [("key", .fixed), ("modifiers", .fixed), ("count", .fixed)],
        .scroll: [("direction", .fixed), ("target", .element), ("lines", .parameter)],
        .drag: [("from", .element), ("to", .element), ("dx", .fixed), ("dy", .fixed), ("distance", .parameter)],
        .contextMenu: [("target", .element), ("item", .fixed)],
        .menu: [("path", .fixed)],
        .press: [("button", .fixed)],
    ]

    /// Facts is what the rule reads of one call.
    public struct Facts: Sendable {
        public let callEventID: String
        public let bundleID: String?
        public let contextID: Int64?
        public let request: AgentCallRequest
        public let status: AgentCallStatus
        public let hasRecordingGap: Bool
        /// Whether a target's text or the observed effect was withheld from the record.
        public let hasWithheldTarget: Bool
        public let verification: QualificationPolicy.VerificationFact?
        /// What the verification expected and observed, as the oracle wrote them (a family for a scene
        /// difference, "unchanged" for a window that did not change).
        public let expected: String?
        public let observed: String?
        /// The family of the effect the call record keeps, when it observed one.
        public let observedEffectKind: String?
        /// The element the call resolved: its role and label.
        public let targetRole: String?
        public let targetLabel: String?
        /// The structural states the call's samples were confirmed in, before and after acting.
        public let fromSceneID: String?
        public let toSceneID: String?
        /// Whether a sample not confirmed in a state is complete and not associated yet: its state may
        /// still come, unlike a sample that is missing, incomplete or uncertain.
        public let beforeAwaitsState: Bool
        public let afterAwaitsState: Bool
        /// The elements of the sample taken before acting, to place the target structurally.
        public let beforeElements: [CaptureElement]

        public init(callEventID: String, bundleID: String?, contextID: Int64?, request: AgentCallRequest, status: AgentCallStatus,
                    hasRecordingGap: Bool, hasWithheldTarget: Bool, verification: QualificationPolicy.VerificationFact?,
                    expected: String?, observed: String?, observedEffectKind: String?, targetRole: String?, targetLabel: String?,
                    fromSceneID: String?, toSceneID: String?, beforeAwaitsState: Bool = false, afterAwaitsState: Bool = false,
                    beforeElements: [CaptureElement]) {
            self.callEventID        = callEventID
            self.bundleID           = bundleID
            self.contextID          = contextID
            self.request            = request
            self.status             = status
            self.hasRecordingGap    = hasRecordingGap
            self.hasWithheldTarget  = hasWithheldTarget
            self.verification       = verification
            self.expected           = expected
            self.observed           = observed
            self.observedEffectKind = observedEffectKind
            self.targetRole         = targetRole
            self.targetLabel        = targetLabel
            self.fromSceneID        = fromSceneID
            self.toSceneID          = toSceneID
            self.beforeAwaitsState  = beforeAwaitsState
            self.afterAwaitsState   = afterAwaitsState
            self.beforeElements     = beforeElements
        }
    }

    /// Decision is what one call teaches.
    public enum Decision: Sendable, Equatable {
        /// The relation this call supports.
        case supports(BrainRelationKey)
        /// The group whose relations of the outcome the verification failed are contradicted: those with
        /// that outcome and, for an effect, that family (any family when nothing was expected).
        case contradicts(BrainRelationKey.Group, outcome: BrainRelationOutcome, effectKind: String?)
        case excluded(Exclusion)
    }

    /// The verb and the fixed arguments of a request, as a relation keys them (`argumentRoles`); nil for
    /// a tool that is no operation. A drag to a target is keyed by its destination's identity, which only
    /// a capture can give: `destination` is it, nil for a drag with none.
    public static func verbAndArguments(of request: AgentCallRequest, destination: String? = nil) -> (verb: BrainVerb, arguments: String)? {
        switch request {
            case .act(_, let verb, let value, _):
                return (BrainVerb(verb), value.map { "value=\($0.rawValue)" } ?? "")
            case .select(_, let item):
                return (.select, "item=\(LabelText.normalize(item))")
            case .typeText(_, _, _, let replace):
                return (.typeText, "replace=\(replace)")
            case .insertText:
                return (.insertText, "")
            case .pressKey(let key, let modifiers, let count):
                return (.pressKey, "key=\(key.word);modifiers=\(modifiers.map(\.rawValue).joined(separator: "+"));count=\(count)")
            case .scroll(let direction, _, let target, _):
                return (.scroll, "direction=\(direction.rawValue);over=\(target == nil ? "window" : "target")")
            case .drag(_, let end, _):
                switch end {
                    case .target: return (.drag, "to=\(destination ?? "target")")
                    case .offset(let dx, let dy): return (.drag, "to=offset;dx=\(sign(dx));dy=\(sign(dy))")
                }
            case .contextMenu(_, let item, _):
                return (.contextMenu, "item=\(LabelText.normalize(item))")
            case .menu(let path):
                return (.menu, "path=" + path.split(separator: ">", omittingEmptySubsequences: false).map { LabelText.menuTitleKey(String($0)) }.joined(separator: ">"))
            case .press(let button):
                return (.press, "button=\(LabelText.normalize(button))")
            default:
                return nil
        }
    }

    /// The direction of one axis of an offset: its distance is a parameter, its sign is what it does.
    private static func sign(_ value: Double) -> String { value > 0 ? "+" : value < 0 ? "-" : "0" }

    /// Whether the verb acts on an element the call named, which the relation must place structurally;
    /// keys, insertions, menus, buttons by title and a scroll over the window act on the focus or the
    /// window.
    public static func needsElement(_ request: AgentCallRequest) -> Bool {
        switch request {
            case .act, .select, .typeText, .drag, .contextMenu: true
            case .scroll(_, _, let target, _): target != nil
            default: false
        }
    }

    /// Placement is a target's key in the capture before acting, or why it has none.
    private enum Placement {
        case key(String)
        case excluded(Exclusion)
    }

    /// The key a target's resolution gives, or the exclusion: none, several physical elements, or one
    /// the structure does not tell from another.
    private static func element(_ resolution: SceneElementKey.Resolution) -> Placement {
        switch resolution {
            case .none: .excluded(.noStructuralElement)
            case .ambiguous: .excluded(.ambiguousElement)
            case .resolved(let identity): identity.key.map(Placement.key) ?? .excluded(.indistinctElement)
        }
    }

    /// What a call teaches.
    public static func decide(_ facts: Facts) -> Decision {
        guard facts.request.tool.isOperation, verbAndArguments(of: facts.request) != nil else {
            return .excluded(.notAnOperation)
        }
        guard let bundleID = facts.bundleID else { return .excluded(.noApplication) }
        switch facts.status {
            case .completed: break
            case .failed, .cancelled, .interrupted: return .excluded(.callFailed)
            default: return .excluded(.notConcluded)
        }
        if facts.hasRecordingGap { return .excluded(.recordingGap) }
        guard let verification = facts.verification else { return .excluded(.noVerification) }
        if verification.condition == .none { return .excluded(.noOracle) }
        if verification.condition == .recoveryInsteadOfRequest || verification.performed == .substitute {
            return .excluded(.substituteGesture)
        }
        if verification.performed == .uncertain || verification.limits.contains(.deliveryUncertain) {
            return .excluded(.deliveryUncertain)
        }
        if facts.hasWithheldTarget || verification.limits.contains(.valueWithheld) { return .excluded(.valueWithheld) }
        if verification.verdict == .unknown { return .excluded(.verdictUnknown) }
        guard let from = facts.fromSceneID else {
            return .excluded(facts.beforeAwaitsState ? .awaitingState : .noBeforeState)
        }
        if facts.toSceneID == nil, facts.afterAwaitsState, verification.condition != .requestedStateAlreadyPresent {
            return .excluded(.awaitingState)
        }
        var element: String?
        if needsElement(facts.request) {
            guard let label = facts.targetLabel else { return .excluded(.noStructuralElement) }
            switch Self.element(SceneElementKey.target(role: facts.targetRole, label: label, in: facts.beforeElements)) {
                case .key(let key): element = key
                case .excluded(let exclusion): return .excluded(exclusion)
            }
        }
        var destination: String?
        if case .drag(_, .target(let label), _) = facts.request {
            switch Self.element(SceneElementKey.target(role: nil, label: label, in: facts.beforeElements)) {
                case .key(let key): destination = key
                case .excluded(let exclusion): return .excluded(exclusion)
            }
        }
        guard let (verb, arguments) = verbAndArguments(of: facts.request, destination: destination) else {
            return .excluded(.notAnOperation)
        }
        let outcome: BrainRelationOutcome
        var effectKind: String?
        switch verification.condition {
            case .structuralEffect:
                outcome = .effect
                // The family the call's record observed, else the one its own verification names as observed.
                effectKind = verification.verdict == .passed
                    ? facts.observedEffectKind ?? facts.observed.flatMap { effectFamilies.contains($0) ? $0 : nil }
                    : facts.expected
            case .submenuOpened:
                outcome = .effect
                effectKind = "menuOpened"
            case .stateAfterGesture: outcome = .stateSet
            case .requestedStateAlreadyPresent: outcome = .alreadySatisfied
            case .valueReadBack: outcome = .valueSet
            case .menuItemChosen: outcome = .itemChosen
            case .windowSetChanged: outcome = .windowSetChanged
            default: return .excluded(.notLearnable)
        }
        let group = BrainRelationKey.Group(bundleID: bundleID, contextID: facts.contextID, fromSceneID: from, elementKey: element,
                                           verb: verb, argumentsKey: arguments)
        switch verification.verdict {
            case .passed:
                guard verification.isPositive else { return .excluded(.notLearnable) }
                if outcome == .effect, effectKind == nil { return .excluded(.notLearnable) }
                return .supports(BrainRelationKey(
                    bundleID: bundleID, contextID: facts.contextID, fromSceneID: from, elementKey: element, verb: verb,
                    argumentsKey: arguments, toSceneID: facts.toSceneID, outcome: outcome, effectKind: effectKind
                ))
            case .failed:
                return .contradicts(group, outcome: outcome, effectKind: outcome == .effect ? facts.expected : nil)
            case .unknown:
                return .excluded(.verdictUnknown)
        }
    }

    /// The effect families a relation names, as the observed effects of a call name them. A value change is
    /// named by its family alone: the field and the text it reads stay in the call's record.
    public static let effectFamilies: Set<String> = ["windowTitleChanged", "stateFlip", "menuOpened", "elementsAppeared",
                                                     "elementsDisappeared", "textSelectionChanged", "valueChanged"]

    /// How many independent supporting proofs a relation needs before it is offered as ordinary
    /// knowledge: one for a menu that opened, which was watched appearing, two for any other outcome.
    public static func threshold(outcome: BrainRelationOutcome, effectKind: String?) -> Int {
        outcome == .effect && effectKind == "menuOpened" ? 1 : 2
    }
}

/// BrainRelation is one relation as stored, with its proofs counted: the identity, the instants it was
/// first and last supported or contradicted, and how many distinct calls support and contradict it.
public struct BrainRelation: Sendable, Equatable {

    /// Standing is what the counts allow: below the threshold a candidate, kept and not offered; at it
    /// and never contradicted, exposed; at it and contradicted, limited, offered only as a possibility.
    public enum Standing: String, Sendable, Equatable, Hashable, CaseIterable {
        case candidate, exposed, limited
    }

    public let relationID: String
    public let key: BrainRelationKey
    public let firstSeenMS: Int64
    public let lastSeenMS: Int64
    public let supports: Int
    public let contradictions: Int

    public init(relationID: String, key: BrainRelationKey, firstSeenMS: Int64, lastSeenMS: Int64, supports: Int,
                contradictions: Int) {
        self.relationID     = relationID
        self.key            = key
        self.firstSeenMS    = firstSeenMS
        self.lastSeenMS     = lastSeenMS
        self.supports       = supports
        self.contradictions = contradictions
    }

    public var standing: Standing {
        guard supports >= BrainRelationPolicy.threshold(outcome: key.outcome, effectKind: key.effectKind) else { return .candidate }
        return contradictions == 0 ? .exposed : .limited
    }

    /// A short rendering of the outcome, for the scene and diagnostics: the verb's arguments, the outcome
    /// and where it leads, never a value.
    public var summary: String {
        let what: String = switch key.outcome {
            case .effect: key.effectKind ?? "effect"
            case .stateSet: "sets its state"
            case .alreadySatisfied: "already in the requested state"
            case .valueSet: "sets its value"
            case .itemChosen: "chooses the item"
            case .windowSetChanged: "changes the windows"
        }
        var arguments = key.argumentsKey.isEmpty ? "" : " [\(key.argumentsKey)]"
        let parameters = (BrainRelationPolicy.argumentRoles[key.verb] ?? []).filter { $0.role == .parameter }.map(\.argument)
            .filter { $0 != "distance" || key.argumentsKey.hasPrefix("to=offset") }
        if !parameters.isEmpty { arguments += " (any " + parameters.joined(separator: ", any ") + ")" }
        let destination: String = switch (key.toSceneID, key.outcome) {
            case (_, .alreadySatisfied): ""
            case (nil, _): " → unknown state"
            case (let to?, _) where to == key.fromSceneID: " → same state"
            case (_?, _): " → another state"
        }
        return "\(key.verb.rawValue)\(arguments): \(what)\(destination)"
    }
}

/// BrainRelationApplication is one evaluation of what a call teaches the relations: the relation it
/// supported, the relations it contradicted, or nothing and why, under one policy, made for one cause.
/// A call's evaluations form a history (`sequence` from 1); its latest one is what counts, so a call
/// supports or contradicts a relation once however often it is evaluated.
public struct BrainRelationApplication: Sendable, Equatable {

    public enum Outcome: String, Sendable, Equatable, Hashable, CaseIterable {
        case supported, contradicted, excluded
    }

    /// Cause is why an evaluation was made: the call's own acquisition, the recovery of one a stopped
    /// process or a lost queue never made, evidence that arrived since the last one, or a new policy.
    public enum Cause: String, Sendable, Equatable, Hashable, CaseIterable {
        case acquisition, recovery, evidence, policy
    }

    public let callEventID: String
    public let sequence: Int
    public let policyVersion: String
    public let cause: Cause
    public let outcome: Outcome
    public let exclusion: BrainRelationPolicy.Exclusion?
    public let relationIDs: [String]

    public init(callEventID: String, sequence: Int = 1, policyVersion: String, cause: Cause = .acquisition, outcome: Outcome,
                exclusion: BrainRelationPolicy.Exclusion?, relationIDs: [String]) {
        self.callEventID   = callEventID
        self.sequence      = sequence
        self.policyVersion = policyVersion
        self.cause         = cause
        self.outcome       = outcome
        self.exclusion     = exclusion
        self.relationIDs   = relationIDs
    }

    /// Whether the evidence this evaluation lacked may still arrive.
    public var isRecoverable: Bool { exclusion?.isRecoverable ?? false }

    /// Whether another evaluation would decide the same: the same outcome, reason, relations and policy.
    public func decidesAsWell(_ other: BrainRelationApplication) -> Bool {
        outcome == other.outcome && exclusion == other.exclusion && relationIDs == other.relationIDs
            && policyVersion == other.policyVersion
    }
}

/// BrainRelationReading is how the scene and the engine read relations: by the functional state a
/// capture is, and by the elements of it, never the whole Brain of an application. A reader that fails
/// answers no opinion, so neither seam may fail an action.
public protocol BrainRelationReading: Sendable {

    /// The functional state a capture of an application is: the one structural scene the matcher finds
    /// the same, or nil when none or several are, or the capture is incomplete.
    func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String?

    /// The state a stored sample was confirmed in by its association, or nil.
    func state(of sample: CaptureSampleKey) async throws -> String?

    /// The relations of a state, for the given element keys (and the relations with no element when
    /// `includingContext`), with their proofs counted.
    func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                   includingContext: Bool) async throws -> [BrainRelation]
}
