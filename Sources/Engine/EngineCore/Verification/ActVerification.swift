//
//  ActVerification.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import PerceptionCore

/// ActVerification decides whether a gesture landed, from the scenes before and after it.
///
/// Success requires a structural effect: an element appeared, vanished, flipped, or the title
/// changed, or a known native text selection changed. Identical tokens mean the window did not
/// change at all. A token that differs with no attributable effect leaves the result unverified:
/// content may have changed, or a repaint may
/// have occurred. That uncertainty proves neither successful delivery nor absence of an effect.
public enum ActVerification {

    /// What the two scenes say about the gesture.
    public enum Verdict: Sendable, Equatable {
        /// A structural effect was observed. When an expectation was given and its family differs,
        /// `matchesExpectation` is false and the caller reports the surprise.
        case landed(SceneEffect, matchesExpectation: Bool)
        /// The scene is byte-identical: the window did not change.
        case ghost
        /// Pixels changed without a classified structural effect; the result remains unverified.
        case unattributable
    }

    /// Whether a capture's own facts forbid drawing a structural conclusion by comparing it with another
    /// (M2): it is explicitly partial or failed, whatever the cause (a list that did not answer, a budget),
    /// or its facts contradict each other. What it did not read may hold what moved, appeared or vanished.
    /// A capture that states nothing (`unknown`, the legacy quality) is compared as before: a limit of this
    /// rule, never called complete.
    public static func refusesComparison(_ capture: CaptureQuality) -> Bool {
        capture.inconsistency != nil || capture.completeness == .partial || capture.completeness == .failed
    }

    /// Whether two captures may be compared for a structural verdict: neither refuses it.
    public static func comparable(before: CaptureQuality, after: CaptureQuality) -> Bool {
        !refusesComparison(before) && !refusesComparison(after)
    }

    /// Judges an action from two perceptions. When either capture refuses a comparison the verdict is
    /// `unattributable` before anything is compared, the tokens included: two partial reads that look the
    /// same prove no absence of an effect, and a branch that answers again is no element that appeared.
    public static func verdict(
        before  : PerceivedWindow,
        after   : PerceivedWindow,
        effect  : SceneEffect?,
        expected: SceneEffect? = nil
    ) -> Verdict {
        guard comparable(before: before.capture, after: after.capture) else { return .unattributable }
        return verdict(before: before.scene, after: after.scene, effect: effect, expected: expected)
    }

    /// Judges an action. `targetID` enables the state-flip reading; `expected` is a learned effect
    /// to compare families against, when memory has one.
    public static func verdict(
        before  : SceneSnapshot,
        after   : SceneSnapshot,
        targetID: String?,
        expected: SceneEffect? = nil
    ) -> Verdict {
        verdict(
            before  : before,
            after   : after,
            effect  : SceneDifference.effect(before: before, after: after, targetID: targetID),
            expected: expected
        )
    }

    /// Judges an action from an effect the caller already named, for a caller that adjusted the
    /// scene difference with facts the scenes alone do not hold (whether a pop-up window is open).
    public static func verdict(
        before  : SceneSnapshot,
        after   : SceneSnapshot,
        effect  : SceneEffect?,
        expected: SceneEffect? = nil
    ) -> Verdict {
        if after.token == before.token { return .ghost }
        guard let effect else { return .unattributable }
        let matches = expected.map { $0.family == effect.family } ?? true
        return .landed(effect, matchesExpectation: matches)
    }

    /// The outcome a verdict earns, with the sentence a model needs next.
    public static func outcome(for verdict: Verdict, label: String, after: SceneSnapshot?) -> ActOutcome {
        switch verdict {
            case .landed(let effect, true):
                if case .stateFlip = effect, let format = formatToggleOutcome("clicked", label: label, after: after) {
                    return format
                }
                return ActOutcome(.foundActed, "clicked '\(label)': \(effect.summary)", scene: after)
            case .landed(let effect, false):
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': observed \(effect.summary), not the expected effect; "
                        + "re-perceive and re-decide",
                    scene: after
                )
            case .ghost:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': this window did NOT change (identical scene)",
                    scene: after
                )
            case .unattributable:
                return ActOutcome(
                    .actedUnverified,
                    "clicked '\(label)': the window's pixels changed but nothing structural did; "
                        + "verify the intended result before deciding on further input",
                    scene: after
                )
        }
    }

    /// The outcome of a text format toggle whose own state flipped, or nil for any other control.
    ///
    /// A bold, italic or underline control acts on the selected text, which no scene reads. Its own
    /// state was observed to flip while the text kept its font (TextEdit's format bar reported `on`
    /// and the line stayed Helvetica; the cause is not shown), so the flip is not the effect: the
    /// gesture stays unverified, the check gains `commandEffectUnchecked`, and the sentence names the
    /// menu command that applies the format.
    public static func formatToggleOutcome(
        _ performed: String,
        label      : String,
        after      : SceneSnapshot?,
        check      : OperationCheck? = nil
    ) -> ActOutcome? {
        guard let path = formatMenuPath(for: label) else { return nil }
        return ActOutcome(
            .actedUnverified,
            "\(performed) '\(label)': only the control's own state changed; the selected text's format was "
                + "not read. Check the text before more input; to apply the format, use menu \"\(path)\"",
            scene: after,
            check: check?.adding([.commandEffectUnchecked])
        )
    }

    /// The menu command that applies the format a text format toggle labelled `label` stands for, or
    /// nil for any other control.
    public static func formatMenuPath(for label: String) -> String? {
        formatMenuPaths[LabelText.normalize(label)]
    }

    // Normalized format bar labels (AppKit FontManager ax_bold, ax_italic, ax_underline) to TextEdit's menu
    // path in that language. A language not listed keeps the plain state-flip verdict until it is added.
    private static let formatMenuPaths = [
        "bold"        : "Format > Font > Bold",
        "italic"      : "Format > Font > Italic",
        "underline"   : "Format > Font > Underline",
        "grassetto"   : "Formato > Font > Grassetto",
        "corsivo"     : "Formato > Font > Corsivo",
        "sottolineato": "Formato > Font > Sottolineato",
    ]
}
