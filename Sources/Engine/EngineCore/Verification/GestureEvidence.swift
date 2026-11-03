import PerceptionCore

/// ObservedChange describes one observed difference without retaining its value or label.
public struct ObservedChange: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case structural, state, fieldValue = "field_value", nativeText = "native_text"
        case selection, recognizedText = "recognized_text"

        public init?(_ effect: SceneEffect) {
            switch effect {
                case .windowTitleChanged, .menuOpened, .elementsAppeared, .elementsDisappeared: self = .structural
                case .stateFlip: self = .state
                case .valueChanged: self = .fieldValue
                case .textSelectionChanged: self = .selection
            }
        }
    }

    public enum Scope: String, Sendable { case target, targetContainer = "target_container", window, elsewhere }
    public enum Stability: String, Sendable {
        case stableLabel = "stable_label", instanceValue = "instance_value", selfChanging = "self_changing", unreliable
    }

    public let kind: Kind
    public let subject: String
    public let scope: Scope
    public let stability: Stability
    public let family: String
}

/// GestureEvidence retains all observed changes beside the effect already attributed by the engine.
public struct GestureEvidence: Sendable, Equatable {
    public let changes: [ObservedChange]
    public let comparable: Bool
    public let learnableEffect: SceneEffect?
    public let verdictChangePosition: Int?
    public var verdictEffect: ObservedChange? {
        verdictChangePosition.flatMap { changes.indices.contains($0) ? changes[$0] : nil }
    }
    public let lookedAgain: Bool
    public let waited: Duration?
    public let settleEnding: SettleResult?

    init(changes: [ObservedChange], comparable: Bool, learnableEffect: SceneEffect?, verdictChangePosition: Int?,
         lookedAgain: Bool = false, waited: Duration? = nil, settleEnding: SettleResult? = nil) {
        self.changes = changes
        self.comparable = comparable
        self.learnableEffect = learnableEffect
        self.verdictChangePosition = verdictChangePosition
        self.lookedAgain = lookedAgain
        self.waited = waited
        self.settleEnding = settleEnding
    }

    /// Attaches the final verification wait without changing the observed differences or learned effect.
    public func withWait(lookedAgain: Bool, waited: Duration?, ending: SettleResult?) -> GestureEvidence {
        GestureEvidence(changes: changes, comparable: comparable, learnableEffect: learnableEffect,
            verdictChangePosition: verdictChangePosition, lookedAgain: lookedAgain, waited: waited, settleEnding: ending)
    }
}

/// SubjectKey names a control by structure alone, never by its label, value or container name.
public enum SubjectKey {
    public static func of(_ element: SceneElement, in scene: SceneSnapshot, target: SceneElement?) -> String {
        var containers: [String] = []
        for item in scene.elements {
            if let container = item.container, !containers.contains(container) { containers.append(container) }
        }
        let container = element.container.flatMap { containers.firstIndex(of: $0) }.map { "c\($0 + 1)" } ?? "root"
        let peers = scene.elements.filter {
            $0.kind == element.kind && $0.role == element.role && $0.container == element.container
        }
        let place = target?.id == element.id ? "t" : String((peers.firstIndex(of: element) ?? 0) + 1)
        let role = element.role.flatMap { $0.unicodeScalars.count <= 256 ? $0 : nil } ?? "-"
        return "\(element.kind.rawValue).\(role)@\(container)#\(place)"
    }
}
