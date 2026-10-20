//
//  SceneDifference.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

/// SceneDifference names the effect of an event from the text scenes before and after it: the
/// causal link a memory learns from. Pure and deterministic over scenes, never over pixels, so it
/// is testable with synthetic scene pairs.
///
/// Only stable labels count as appearing or vanishing. A pro-audio canvas repaints meters and
/// timecodes every frame, and measurements are not UI; without that filter three identical clicks
/// produced three unique effects and no transition could ever earn trust.
public enum SceneDifference {

    /// The attributable effect, or nil when nothing attributable changed. `target` preserves the
    /// selected control and its scope when several controls share `targetID`. Without it, the ID
    /// must identify one before element. A state flip needs one counterpart in that same scope.
    /// `countsValueChange` also names a text field that reads another value; a key press has no
    /// target, so only it asks.
    /// `countsNativeTextChange` also names a static text whose native value changed: only for a scene
    /// source whose texts show the app's state (the MacDriver's display of a result), never for the
    /// Seat's, whose texts include clocks, timecodes and "saved a minute ago" lines that change alone.
    public static func effect(
        before                : SceneSnapshot,
        after                 : SceneSnapshot,
        targetID              : String?,
        target                : SceneElement? = nil,
        countsValueChange     : Bool = false,
        countsNativeTextChange: Bool = false
    ) -> SceneEffect? {
        if LabelText.letters(before.windowTitle) != LabelText.letters(after.windowTitle) {
            return .windowTitleChanged(title: String(after.windowTitle.prefix(40)))
        }

        if before.bundleID == after.bundleID, before.windowTitle == after.windowTitle,
           let selected = target ?? unique(before.elements.filter { $0.id == targetID }),
           let stateBefore = selected.state {
            let matches: (SceneElement) -> Bool = {
                $0.kind == selected.kind && $0.role == selected.role
                    && $0.container == selected.container && $0.collectionPath == selected.collectionPath
                    && LabelText.normalize($0.label) == LabelText.normalize(selected.label)
            }
            // The selected scope must be unique on both sides; a shared ID cannot name another track.
            if unique(before.elements.filter(matches)) == selected,
               let counterpart = unique(after.elements.filter(matches)),
               let stateAfter = counterpart.state, stateAfter != stateBefore {
                return .stateFlip(from: stateBefore, to: stateAfter)
            }
        }

        let beforeIDs    = Set(before.elements.map(\.id))
        let beforeLabels = Set(before.elements.map { LabelText.normalize($0.label) }.filter { !$0.isEmpty })
        let fresh = after.elements.filter { element in
            guard !beforeIDs.contains(element.id), !element.isUnlabeled, LabelText.isStableLabel(element.label) else {
                return false
            }
            let normalized = LabelText.normalize(element.label)
            return !normalized.isEmpty && !beforeLabels.contains(normalized)
        }
        if fresh.count >= 3 {
            let xs = fresh.map(\.bounds.x), ys = fresh.map(\.bounds.y)
            let clustered = spread(xs) <= 0.45 && spread(ys) <= 0.7
            let labels = canonicalLabels(fresh)
            return clustered ? .menuOpened(labels: labels) : .elementsAppeared(labels: labels)
        }
        if fresh.count >= 1 { return .elementsAppeared(labels: canonicalLabels(fresh)) }

        let afterIDs    = Set(after.elements.map(\.id))
        let afterLabels = Set(after.elements.map { LabelText.normalize($0.label) }.filter { !$0.isEmpty })
        let gone = before.elements.filter { element in
            guard !afterIDs.contains(element.id), !element.isUnlabeled, LabelText.isStableLabel(element.label) else {
                return false
            }
            let normalized = LabelText.normalize(element.label)
            return !normalized.isEmpty && !afterLabels.contains(normalized)
        }
        if gone.count >= 3 { return .elementsDisappeared(labels: canonicalLabels(gone)) }
        if countsValueChange, let changed = valueChanged(before: before, after: after) { return changed }
        if countsNativeTextChange, let changed = nativeTextChanged(before: before, after: after) { return changed }
        if textSelectionChanged(before: before, after: after) { return .textSelectionChanged }
        return nil
    }

    /// A text read from the accessibility tree, present once in each scene with the same id, or else
    /// alone at the same place, whose value differs: a display that now reads another result. The
    /// place covers an id that moved with its siblings: on = Calculator shows the expression in an
    /// area above the display, so the display's path shifts and its old id names the expression.
    /// Only a native reading carries a text's value; a recognized text has its words in the label
    /// alone and never counts, so pixels that repaint differently name no effect.
    private static func nativeTextChanged(before: SceneSnapshot, after: SceneSnapshot) -> SceneEffect? {
        guard before.bundleID == after.bundleID else { return nil }
        for text in before.elements where text.kind == .text {
            let matches: (SceneElement) -> Bool = { $0.id == text.id && $0.kind == .text }
            guard before.elements.filter(matches).count == 1 else { continue }
            let current = after.elements.filter(matches)
            guard current.count == 1, let counterpart = current.first,
                  let previous = text.value, let value = counterpart.value, previous != value
            else { continue }
            return .valueChanged(label: text.label, value: value)
        }
        let readBefore = before.elements.filter { $0.kind == .text && $0.value != nil }
        let readAfter  = after.elements.filter { $0.kind == .text && $0.value != nil }
        for text in readBefore {
            let here: (SceneElement) -> Bool = { samePlace($0.bounds, text.bounds) }
            guard readBefore.filter(here).count == 1 else { continue }
            let current = readAfter.filter(here)
            guard current.count == 1, let counterpart = current.first,
                  let previous = text.value, let value = counterpart.value, previous != value
            else { continue }
            return .valueChanged(label: text.label, value: value)
        }
        return nil
    }

    /// Two texts on the same line that overlap: a right-aligned display keeps its line while its
    /// width follows the digits, so the frames need not match.
    private static func samePlace(_ first: NormalizedRect, _ second: NormalizedRect) -> Bool {
        first.midY > second.y && first.midY < second.maxY
            && second.midY > first.y && second.midY < first.maxY
            && first.x < second.maxX && second.x < first.maxX
    }

    /// A text field present once in each scene with the same id, kind and role, whose value is
    /// readable on both sides and differs. A caret move alone leaves the value, so it is no change.
    private static func valueChanged(before: SceneSnapshot, after: SceneSnapshot) -> SceneEffect? {
        guard before.bundleID == after.bundleID else { return nil }
        for field in before.elements where field.kind == .control
            && AccessibilityAugmentation.textEntryRoles.contains(field.role ?? "") {
            let matches: (SceneElement) -> Bool = {
                $0.id == field.id && $0.kind == field.kind && $0.role == field.role
            }
            guard before.elements.filter(matches).count == 1 else { continue }
            let current = after.elements.filter(matches)
            guard current.count == 1, let counterpart = current.first,
                  let previous = field.value, let value = counterpart.value, previous != value
            else { continue }
            return .valueChanged(label: counterpart.label, value: value)
        }
        return nil
    }

    /// Both readings must belong to one field with the same exact text. Missing,
    /// invalid or duplicate native facts do not establish a selection change.
    private static func textSelectionChanged(before: SceneSnapshot, after: SceneSnapshot) -> Bool {
        guard before.bundleID == after.bundleID, before.windowTitle == after.windowTitle else { return false }
        let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        for field in before.elements where field.kind == .control && roles.contains(field.role ?? "") {
            let matches: (SceneElement) -> Bool = {
                $0.id == field.id && $0.kind == field.kind && $0.role == field.role
            }
            guard before.elements.filter(matches).count == 1 else { continue }
            let current = after.elements.filter(matches)
            guard current.count == 1, let counterpart = current.first,
                  field.value == counterpart.value,
                  let previousRange = SceneElement.validRange(field.selectedRange, value: field.value),
                  let currentRange = SceneElement.validRange(counterpart.selectedRange, value: counterpart.value)
            else { continue }
            if previousRange != currentRange { return true }
        }
        return false
    }

    /// Sorted, deduplicated, capped names: the canonical identity of an appearance. Prose next to a
    /// menu item (a description ending in a period, or a long line) is dropped when any name remains.
    static func canonicalLabels(_ elements: [SceneElement], cap: Int = 6) -> [String] {
        let named = elements.map(\.label).filter { $0.count <= 24 && !$0.hasSuffix(".") }
        let pool = named.isEmpty ? elements.map(\.label) : named
        return Array(Set(pool).sorted().prefix(cap))
    }

    private static func unique(_ elements: [SceneElement]) -> SceneElement? {
        elements.count == 1 ? elements[0] : nil
    }

    private static func spread(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return maximum - minimum
    }
}
