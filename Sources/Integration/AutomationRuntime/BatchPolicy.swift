import EngineCore
import Foundation
import Memory
import PerceptionCore
import Switches

/// BatchPolicy decides admission and continuation from facts supplied by either runner.
public nonisolated enum BatchPolicy {
    public typealias Stop = BatchStopReason
    public enum Decision: Sendable, Equatable { case proceed, stop(Stop) }
    public static let maximumSteps = 20
    public static let timeCap: Duration = .seconds(15)
    public static let stepAllowance: Duration = .seconds(3)
    public static let hostDrainLimit: Duration = .seconds(30)

    public struct StepFacts: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case act, select, menu, typeText = "type_text", insertText = "insert_text", pressKey = "press_key"
            case scroll, drag, contextMenu = "context_menu"
        }
        public let kind: Kind
        public let target: String?
        public let section: String?
        public let verb: String?
        public let item: String?
        public let chord: KeyChord?
        public let expectation: ScreenExpectation?

        public init(kind: Kind, target: String? = nil, section: String? = nil, verb: String? = nil,
                    item: String? = nil, chord: KeyChord? = nil, expectation: ScreenExpectation? = nil) {
            self.kind = kind
            self.target = target
            self.section = section
            self.verb = verb
            self.item = item
            self.chord = chord
            self.expectation = expectation
        }
    }

    public struct BatchPlanFacts: Sendable, Equatable {
        public let steps: [StepFacts]
        public let bundleID: String
        public init(steps: [StepFacts], bundleID: String) {
            self.steps = steps
            self.bundleID = bundleID
        }
    }

    public enum TargetResolution: Sendable, Equatable {
        case found(SceneElement), ambiguous(Int), missing, notNeeded
        public var element: SceneElement? { if case .found(let element) = self { element } else { nil } }
        public var isPresent: Bool { if case .found = self { true } else { false } }
    }

    public static func validate(_ plan: BatchPlanFacts, entryScene: SceneSnapshot) -> Decision {
        guard (1...maximumSteps).contains(plan.steps.count), plan.steps.allSatisfy({ expectationFits($0.expectation) }) else {
            return .stop(.refused)
        }
        for (index, step) in plan.steps.enumerated() {
            let target = resolveTarget(of: index, in: plan, entryScene: entryScene, scene: entryScene)
            if stepCommits(step, target: target.element, scene: entryScene),
               index != plan.steps.count - 1 || step.expectation == nil { return .stop(.committingNotLast) }
        }
        return .proceed
    }

    public static func resolveTarget(of index: Int, in plan: BatchPlanFacts, entryScene: SceneSnapshot,
                                     scene: SceneSnapshot) -> TargetResolution {
        guard plan.steps.indices.contains(index) else { return .missing }
        let step = plan.steps[index]
        guard var name = step.target else { return .notNeeded }
        var section = step.section
        var role: String?
        if index > 0 {
            if entryScene.elements.contains(where: { $0.id == name }) {
                switch entryScene.resolve(target: name, preferStateful: step.verb == "set_toggle", section: section,
                    preferNativeControls: step.kind == .act, preferTextEntry: step.kind == .typeText) {
                case .found(let original):
                    guard !original.isUnlabeled else { return .missing }
                    name = original.label
                    section = section ?? original.container ?? original.section
                    role = original.role
                case .ambiguous(let count): return .ambiguous(count)
                case .none: return .missing
                }
            } else if scene.elements.contains(where: { $0.id == name }) || isSceneID(name) { return .missing }
        }
        var current = scene
        if let role { current.elements = current.elements.filter { $0.role == role } }
        switch current.resolve(target: name, preferStateful: step.verb == "set_toggle", section: section,
                               preferNativeControls: step.kind == .act, preferTextEntry: step.kind == .typeText) {
        case .found(let element): return .found(element)
        case .ambiguous(let count): return .ambiguous(count)
        case .none: return .missing
        }
    }

    private static func isSceneID(_ target: String) -> Bool {
        guard let separator = target.firstIndex(of: "|") else { return false }
        return target.hasPrefix("?|@") || ElementKind(rawValue: String(target[..<separator])) != nil
    }

    public static func beforeStep(_ index: Int, of plan: BatchPlanFacts, scene: SceneSnapshot,
                                  target: TargetResolution, commits: Bool, earlier: [Outcome],
                                  elapsed: Duration) -> Decision {
        guard plan.steps.indices.contains(index), expectationFits(plan.steps[index].expectation) else { return .stop(.refused) }
        guard elapsed + stepAllowance <= timeCap else { return .stop(.timeCap) }
        guard scene.bundleID == plan.bundleID else { return .stop(.otherApp) }
        switch target {
        case .missing: return .stop(.targetMissing)
        case .ambiguous: return .stop(.ambiguous)
        default: break
        }
        if commits {
            guard index == plan.steps.count - 1, plan.steps[index].expectation != nil else {
                return .stop(.committingNotLast)
            }
            guard earlier.allSatisfy({ $0.effect == .confirmed }) else { return .stop(.committingAfterUnconfirmed) }
        }
        return .proceed
    }

    public static func afterStep(_ outcome: Outcome, expectedAbsent: Bool, unexpectedSurface: Bool,
                                 nextTargetPresent: Bool, isLastStep: Bool = false) -> Decision {
        if outcome.gesture == .notSent, outcome.effect != .confirmed {
            if outcome.recovery == .changeTarget(.ambiguous) { return .stop(.ambiguous) }
            if outcome.recovery == .changeTarget(.notFound) { return .stop(.targetMissing) }
            return .stop(.refused)
        }
        if unexpectedSurface { return .stop(.unexpectedSurface) }
        switch outcome.effect {
        case .confirmed: return .proceed
        case .absent: return expectedAbsent ? .proceed : .stop(.expectedAbsent)
        case .unknown: return isLastStep || nextTargetPresent ? .proceed : .stop(.unknownWithoutNextTarget)
        case .notApplicable: return .stop(.refused)
        }
    }

    /// A deadline does not turn an unrelated failure into a time error.
    public static func stopReason(for error: any Error, deadlineReached: Bool,
                                  personInControl: Bool) -> Stop {
        if personInControl { return .personInControl }
        if deadlineReached && error is CancellationError { return .timeCap }
        if let error = error as? URLError, error.code == .timedOut { return .timeCap }
        return .error
    }

    public static func stepCommits(_ step: StepFacts, target: SceneElement?, scene: SceneSnapshot) -> Bool {
        if let chord = step.chord {
            if ActionPolicy.isDestructive(chord) || ActionPolicy.closesTheTarget(chord) { return true }
            if chord.key == .return, chord.modifiers.isEmpty || chord.modifiers == .command { return true }
        }
        guard [.act, .select, .menu, .contextMenu].contains(step.kind) else { return false }
        let label = target?.label ?? step.target
        if step.kind == .act,
           ActionPolicy.isDestructive(label: label, bundleID: scene.bundleID,
                                      role: target?.role, container: target?.container) { return true }
        let command = step.item ?? (step.kind == .act ? label : nil)
        guard var command else { return false }
        if step.kind == .menu { command = command.components(separatedBy: ">").last?.trimmingCharacters(in: .whitespaces) ?? command }
        if [.select, .contextMenu].contains(step.kind), let target {
            return ActionPolicy.isDestructiveMenuItem(command, openedBy: target.label, bundleID: scene.bundleID,
                role: target.role, container: target.container) || closesWithoutSaving(command)
        }
        return ActionPolicy.isDestructive(label: command, bundleID: scene.bundleID,
                                          role: step.kind == .act ? target?.role : nil,
                                          container: target?.container)
            || closesWithoutSaving(command)
    }

    private static func closesWithoutSaving(_ command: String) -> Bool {
        ["don't save", "do not save", "non salvare", "replace", "sostituisci"].contains(ActionPolicy.normalizedLabel(command))
    }

    private static func expectationFits(_ expectation: ScreenExpectation?) -> Bool {
        switch expectation {
        case nil: return true
        case .window(let title, _): return title.count <= Todo.expectedLimit
        case .element(let label, .value(let value)): return label.count + value.count <= Todo.expectedLimit
        case .element(let label, _): return label.count <= Todo.expectedLimit
        }
    }

    public static func expectedAbsent(_ step: StepFacts, outcome: Outcome, sceneBefore: SceneSnapshot) -> Bool {
        guard outcome.effect == .absent, let expectation = step.expectation else { return false }
        let task: TaskResultCheck.Expectation
        switch expectation {
        case .element(let label, let expect): task = .element(app: nil, label: label, expect: expect)
        case .window(let title, let open): task = .window(app: nil, title: title, open: open)
        }
        return TaskResultCheck.judge(task, attemptID: "", windows: [sceneBefore.windowTitle], scene: sceneBefore).verdict == .passed
    }
}

/// BatchMode reads the rollout arms independently of the pure step decisions.
public nonisolated enum BatchMode {
    public enum Version: String, Sendable { case v1, v2 }
    public enum Form: String, Sendable { case tool, inGestures = "in_gestures" }
    /// Marks expansion into the shared runner without changing the installed rollout switches.
    @TaskLocal public static var isExpandingGestures = false

    public static func validateConfiguration() throws {
        guard !isEnabled || TaskCycleArm.current == .v2 else {
            throw BatchConfigurationError.taskCycleV2Required
        }
    }

    public static var isEnabled: Bool { SwitchBoard.current.arm("batch", default: Version.v1) == .v2 }
    public static var usesGestures: Bool {
        isEnabled && !isExpandingGestures && SwitchBoard.current.arm("batch_form", default: Form.tool) == .inGestures
    }
}
