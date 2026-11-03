import Foundation
import PerceptionCore

/// SceneEvidence observes differences independently of which effect the engine admits for learning.
public enum SceneEvidence {
    /// Compares two captures using the current quality contract; refused pairs retain no differences or effect.
    public static func observe(before: PerceivedWindow, after: PerceivedWindow, target: SceneElement?,
                               learnableEffect: SceneEffect?) -> GestureEvidence {
        guard ActVerification.comparable(before: before.capture, after: after.capture) else {
            return GestureEvidence(changes: [], comparable: false, learnableEffect: nil, verdictChangePosition: nil)
        }
        let was = before.scene, now = after.scene
        var changes: [ObservedChange] = []
        var verdictPosition: Int?
        func scope(_ element: SceneElement) -> ObservedChange.Scope {
            guard let target else { return .window }
            if element.id == target.id { return .target }
            if let container = target.container { return element.container == container ? .targetContainer : .elsewhere }
            return element.section == target.section ? .targetContainer : .elsewhere
        }
        func append(_ kind: ObservedChange.Kind, _ element: SceneElement, in scene: SceneSnapshot,
                    family: String, stability: ObservedChange.Stability, suppliesEffect: Bool = false) {
            if suppliesEffect, verdictPosition == nil { verdictPosition = changes.count }
            changes.append(ObservedChange(kind: kind, subject: SubjectKey.of(element, in: scene, target: target),
                scope: scope(element), stability: stability, family: family))
        }
        if was.windowTitle != now.windowTitle {
            if case .windowTitleChanged = learnableEffect { verdictPosition = changes.count }
            changes.append(ObservedChange(kind: .structural, subject: "window.-@root#1", scope: .window,
                                          stability: .instanceValue, family: "windowTitleChanged"))
        }
        var matched: Set<Int> = []
        let fresh = now.elements.filter { current in !was.elements.contains { $0.id == current.id } }
        let stableFresh = fresh.filter { !$0.isUnlabeled && LabelText.isStableLabel($0.label) }
        let clustered = stableFresh.count >= 3
            && spread(stableFresh.map(\.bounds.x)) <= 0.45 && spread(stableFresh.map(\.bounds.y)) <= 0.7
        let appearance = learnableEffect?.family == "menuOpened" || clustered ? "menuOpened" : "elementsAppeared"
        for element in now.elements {
            let index = counterpart(of: element, in: was, other: now)
            guard let index else {
                if was.elements.contains(where: { $0.id == element.id && $0.kind == element.kind
                    && $0.role == element.role && $0.container == element.container }) { continue }
                let supplies: Bool
                switch learnableEffect {
                    case .elementsAppeared(let labels), .menuOpened(let labels): supplies = labels.contains(element.label)
                    default: supplies = false
                }
                append(isRecognized(element) ? .recognizedText : .structural, element, in: now, family: appearance,
                       stability: stability(of: element), suppliesEffect: supplies)
                continue
            }
            matched.insert(index)
            let old = was.elements[index]
            if let from = old.state, let to = element.state, from != to {
                let supplies: Bool
                if case .stateFlip = learnableEffect { supplies = target.map { sameScope(old, $0) } ?? false }
                else { supplies = false }
                append(.state, element, in: now, family: "stateFlip", stability: stability(of: element),
                       suppliesEffect: supplies)
            }
            if was.bundleID == now.bundleID, let prior = old.value, let value = element.value, prior != value,
               element.kind == .text || (element.kind == .control
                    && AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "")) {
                let supplies: Bool
                if case .valueChanged(let label, let learned) = learnableEffect {
                    supplies = learned == value && (label == old.label || label == element.label)
                } else { supplies = false }
                append(element.kind == .text ? .nativeText : .fieldValue, element, in: now,
                       family: "valueChanged", stability: .instanceValue, suppliesEffect: supplies)
            } else if old.label != element.label {
                let supplies: Bool
                switch learnableEffect {
                    case .elementsAppeared(let labels), .menuOpened(let labels): supplies = labels.contains(element.label)
                    default: supplies = false
                }
                let kind: ObservedChange.Kind = isRecognized(element) ? .recognizedText
                    : element.kind == .text ? .nativeText : .structural
                append(kind, element, in: now, family: supplies ? appearance : "valueChanged",
                       stability: stability(of: element), suppliesEffect: supplies)
            }
            if was.bundleID == now.bundleID, was.windowTitle == now.windowTitle,
               old.value == element.value, let value = element.value,
               valid(old.selectedRange, in: value), valid(element.selectedRange, in: value),
               old.selectedRange != element.selectedRange {
                append(.selection, element, in: now, family: "textSelectionChanged", stability: .instanceValue,
                       suppliesEffect: learnableEffect == .textSelectionChanged)
            }
        }
        for (index, element) in was.elements.enumerated() where !matched.contains(index) {
            if now.elements.contains(where: { $0.id == element.id && $0.kind == element.kind
                && $0.role == element.role && $0.container == element.container }) { continue }
            let supplies: Bool
            if case .elementsDisappeared(let labels) = learnableEffect { supplies = labels.contains(element.label) }
            else { supplies = false }
            append(isRecognized(element) ? .recognizedText : .structural, element, in: was,
                   family: "elementsDisappeared", stability: stability(of: element), suppliesEffect: supplies)
        }
        return GestureEvidence(changes: changes, comparable: true, learnableEffect: learnableEffect,
                               verdictChangePosition: verdictPosition)
    }

    private static func counterpart(of element: SceneElement, in scene: SceneSnapshot, other: SceneSnapshot) -> Int? {
        func unique(_ matches: (SceneElement) -> Bool) -> Int? {
            let indices = scene.elements.indices.filter { matches(scene.elements[$0]) }
            return indices.count == 1 && other.elements.filter(matches).count == 1 ? indices.first : nil
        }
        if element.kind == .text, element.value != nil,
           let index = unique({ $0.kind == .text && $0.value != nil && samePlace($0.bounds, element.bounds) }) {
            return index
        }
        if let index = unique({ $0.id == element.id && $0.kind == element.kind && $0.role == element.role
            && $0.container == element.container }) { return index }
        if let index = unique({ sameScope($0, element) }) { return index }
        if isRecognized(element) {
            return unique { isRecognized($0) && samePlace($0.bounds, element.bounds) }
        }
        return nil
    }

    private static func sameScope(_ first: SceneElement, _ second: SceneElement) -> Bool {
        first.kind == second.kind && first.role == second.role && first.container == second.container
            && first.collectionPath == second.collectionPath && LabelText.normalize(first.label) == LabelText.normalize(second.label)
    }

    private static func isRecognized(_ element: SceneElement) -> Bool {
        element.kind == .text && element.value == nil && element.role == nil && element.labelOrigin == nil
    }

    private static func stability(of element: SceneElement) -> ObservedChange.Stability {
        if isRecognized(element) { return .unreliable }
        if element.labelOrigin == .value || !LabelText.isStableLabel(element.label)
            || element.label.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil {
            return .instanceValue
        }
        return .stableLabel
    }

    private static func valid(_ range: NSRange?, in value: String) -> Bool {
        guard let range, range.location >= 0, range.length >= 0, range.location <= value.utf16.count else { return false }
        return range.length <= value.utf16.count - range.location
    }

    private static func samePlace(_ first: NormalizedRect, _ second: NormalizedRect) -> Bool {
        first.midY > second.y && first.midY < second.maxY && second.midY > first.y && second.midY < first.maxY
            && first.x < second.maxX && second.x < first.maxX
    }

    private static func spread(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return maximum - minimum
    }
}
