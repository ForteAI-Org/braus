//
//  ActionVerdict.swift
//  Braus
//
//  Created by Codex on 01/11/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// Judges action effects and qualifies outcomes from the available evidence.
extension ActionEngine {

    /// The check of an outcome whose path stated none (`ActOutcome.withStatedCheck`).
    static func checked(_ outcome: ActOutcome) -> ActOutcome {
        outcome.withStatedCheck
    }

    /// The outcome of a menu choice by its receipt (`MenuItemPress`), nil when the controls did not handle it. An
    /// applied choice is judged by what was read back after settling, never by the menu's closing, which a list
    /// Braus draws does by itself; only a conformer that reads nothing back is judged by the census, as before.
    /// Nothing is chosen again after anything went out.
    func judged(
        _ receipt : MenuItemPress,
        _ request : ActionRequest,
        element   : SceneElement,
        perceived : PerceivedWindow
    ) async -> ActOutcome? {
        let pid = request.processID
        let target = OperationCheck.Target(element)
        switch receipt {
            case .notHandled:
                return nil
            case .refused(let reason):
                await recordPick(request, element: element, before: perceived, after: nil,
                                 attempt: .notAttempted(reason: reason))
                return ActOutcome(.refused, "'\(element.label)' was not chosen, nothing was sent: \(reason). Observe "
                    + "the list again before choosing.", scene: perceived.scene)
            case .possiblySent(let reason):
                let afterWindow = await perceive(pid)
                await recordPick(request, element: element, before: perceived, after: afterWindow,
                                 attempt: .deliveryFailed(reason))
                return ActOutcome(.actedUnverified, "choosing '\(element.label)': \(reason), so the choice may have "
                    + "been applied: observe the control before anything else, and never choose it again blindly.",
                    scene: afterWindow?.scene, check: OperationCheck(
                        condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                        limits: [.deliveryUncertain], performed: .uncertain, target: target))
            case .sent(.unattested):
                await pause(timing.popupCommit)
                let stillOpen = await surfaces(pid).hasOpenPopup
                let afterWindow = await perceive(pid)
                let after = afterWindow?.scene
                await recordPick(request, element: element, before: perceived, after: afterWindow)
                let check = OperationCheck(
                    condition: .menuClosedAfterChoice, method: .windowCensus, verdict: stillOpen ? .failed : .passed,
                    expected: "menu closed", observed: stillOpen ? "menu open" : "menu closed",
                    limits: [.commandEffectUnchecked], performed: .requested, target: target
                )
                if stillOpen {
                    return ActOutcome(.actedUnverified, "pressed '\(element.label)' in the open menu, but the "
                        + "menu is still open: observe before choosing again.", scene: after, check: check)
                }
                return ActOutcome(.foundActed, "chose '\(element.label)' in the open menu through its accessibility "
                    + "item; the menu closed. Check the command's own effect before going on.", scene: after, check: check)
            case .sent(let readBack):
                let afterWindow = await perceive(pid)
                let after = afterWindow?.scene
                await recordPick(request, element: element, before: perceived, after: afterWindow)
                switch readBack {
                    case .confirmed(let expected, let observed):
                        return ActOutcome(.foundActed, "chose '\(element.label)': after the page settled the control "
                            + "reads it", scene: after, check: OperationCheck(
                                condition: .valueReadBack, method: .controlValue, verdict: .passed, expected: expected,
                                observed: observed, performed: .requested, target: target))
                    case .contradicted(let expected, let observed):
                        return ActOutcome(.actedUnverified, "chose '\(element.label)', but after the page settled the "
                            + "control reads \(observed.map { "'\(Self.shortened($0))'" } ?? "no option"): the page did "
                            + "not keep it. Observe and re-decide; do not choose it again blindly.", scene: after,
                            check: OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .failed,
                                                  expected: expected, observed: observed,
                                                  limits: observed == nil ? [.readbackUnavailable] : [],
                                                  performed: .requested, target: target))
                    case .unread(let expected, let reason):
                        return ActOutcome(.actedUnverified, "chose '\(element.label)', but the control could not be "
                            + "read back (\(reason)): observe it before anything else; do not choose it again blindly.",
                            scene: after, check: OperationCheck(
                                condition: .valueReadBack, method: .controlValue, verdict: .unknown, expected: expected,
                                limits: [.readbackUnavailable], performed: .requested, target: target))
                    case .unattested:
                        return nil
                }
        }
    }

    /// The outcome of an action whose last wait did not settle (`SettleResult`): what was read after it may not be
    /// what the gesture leaves. A verdict from the scene or a transition is then unknown, whichever it was; a direct
    /// read-back that found the effect stays passed, and one that did not find it is unknown, since the effect may
    /// still come. The check names the limit, and the message says why. An outcome no gesture produced, or a wait
    /// with no settling role (the fixed pause), is as it was.
    static func qualified(_ outcome: ActOutcome, after ended: SettleResult?, readBackFromScene: Bool = false,
                          cap: Duration) -> ActOutcome {
        guard let ended, ended != .settled, [.foundActed, .actedUnverified].contains(outcome.kind),
              let check = outcome.check, check.performed != .none
        else { return outcome }
        let limit: OperationCheck.Limit = ended == .capped ? .settleCapped : .settleUnwatched
        // A read-back method whose value came from the scene's element is the scene.
        let isDirect = [.controlState, .controlValue, .driverReceipt].contains(check.method) && !readBackFromScene
        let verdict: OperationCheck.Verdict = switch check.verdict {
            case .passed : isDirect ? .passed : .unknown
            case .failed : .unknown
            case .unknown: .unknown
        }
        let qualified = OperationCheck(
            condition: check.condition, method: check.method, methodVersion: check.methodVersion, verdict: verdict,
            expected: check.expected, observed: check.observed, limits: check.limits + [limit], performed: check.performed,
            substitute: check.substitute, target: check.target
        )
        let milliseconds = cap.components.seconds * 1000 + cap.components.attoseconds / 1_000_000_000_000_000
        var message = outcome.message + (ended == .capped
            ? " The wait after it ended at its cap (\(milliseconds) ms) with the window still changing, or a request "
                + "still in flight: what was read may not be what it leaves."
            : " Nothing could be watched while waiting after it, or not all of it (a page's requests): the wait was its "
                + "cap (\(milliseconds) ms), and what was read may not be what it leaves yet.")
        if verdict != check.verdict {
            message += " So whether it had its effect is not known yet: observe again before acting, and do not repeat it "
                + "from this answer."
        }
        let kind: ActOutcomeKind = outcome.kind == .foundActed && verdict != .passed ? .actedUnverified : outcome.kind
        return ActOutcome(kind, message, scene: outcome.scene, check: qualified)
    }

    /// The answer to an input the actuator refused before any event of it went out (`GestureNotSent`): refused,
    /// nothing performed, in the actuator's words, so the model reads that nothing happened and what to do
    /// instead. Nil for any other failure, which stays a delivery whose effect is unknown.
    static func notSent(_ error: any Error, _ action: String, scene: SceneSnapshot? = nil) -> ActOutcome? {
        guard let refusal = error as? GestureNotSent else { return nil }
        return ActOutcome(.refused, "\(action): nothing was sent. \(refusal.sentence)", scene: scene)
    }

    /// The attempt a failed delivery records: not attempted, with the actuator's reason, when nothing went out.
    static func attempt(after error: any Error) -> ActionAttempt {
        (error as? GestureNotSent).map { .notAttempted(reason: $0.reason) } ?? .deliveryFailed("\(error)")
    }

    /// An input with no reading of its own is judged by the two scenes alone, and its delivery closed
    /// with what they showed. `ghost` and `repaint` are what to do next when nothing was attributed.
    func judged(
        _ performed       : String,
        in request        : InputRequest,
        before beforeWindow: PerceivedWindow,
        targetID          : String?,
        ghost             : String,
        repaint           : String,
        countsValueChange : Bool = false,
        ignoresTextRereads: Bool = false,
        movesFocus        : Bool = false
    ) async -> ActOutcome {
        let pid = request.processID
        await settle(pid)
        let target = Self.inputTrail?.target.map(OperationCheck.Target.init)
        let before = beforeWindow.scene
        guard let afterWindow = await perceive(pid) else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(performed): no scene could be read afterwards; observe when "
                + "the window is back", check: OperationCheck(
                    condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                    limits: [.noAfterScene, .noExpectation], performed: .requested, target: target))
        }
        let after = afterWindow.scene
        // A capture that says it is not whole compares to nothing (M2), the focus included.
        let comparable = ActVerification.comparable(before: beforeWindow.capture, after: afterWindow.capture)
        let effect = comparable ? Self.gatedEffect(
            before: before, after: after, targetID: targetID ?? "", popupIsOpen: (await surfaces(pid)).hasOpenPopup,
            countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads,
            countsNativeTextChange: dependencies.countsNativeTextChange
        ) : nil
        let verdict = ActVerification.verdict(before: beforeWindow, after: afterWindow, effect: effect)
        if movesFocus, comparable, verdict != .ghost, Self.showsFocus(before: before, after: after, effect: effect) {
            return await focusJudged(performed, pid: pid, before: before, after: after, effect: effect, target: target)
        }
        Self.inputTrail?.attribute(effect)
        let delivery: DeliveryEffect = switch verdict {
            case .landed        : .observed
            case .ghost         : .absent
            case .unattributable: .unknown
        }
        await confirm(delivery, in: pid)
        // An input has no learned expectation: any structural change anywhere in the window passes.
        let check = OperationCheck.sceneDifference(verdict, expected: nil, target: target, limits: [.windowWide])
        switch verdict {
            case .landed(let effect, _):
                return ActOutcome(.foundActed, "\(performed): \(effect.summary)", scene: after, check: check)
            case .ghost:
                return ActOutcome(.actedUnverified, "\(performed): this window did NOT change (identical scene). "
                    + ghost, scene: after, check: check)
            case .unattributable where !comparable:
                return ActOutcome(.actedUnverified, "\(performed): \(Self.notComparable).", scene: after, check: check)
            case .unattributable:
                return ActOutcome(.actedUnverified, "\(performed): the window's pixels changed but nothing "
                    + "structural did. \(repaint)", scene: after, check: check)
        }
    }

    /// Tab and Shift-Tab are judged by the focus alone: a change anywhere else in the window, a selection
    /// redrawn in the field that kept the focus included, is not the key moving it.
    private func focusJudged(
        _ performed: String,
        pid        : pid_t,
        before     : SceneSnapshot,
        after      : SceneSnapshot,
        effect     : SceneEffect?,
        target     : OperationCheck.Target?
    ) async -> ActOutcome {
        let moved = Self.focusMove(before: before, after: after)
        Self.inputTrail?.attribute(moved == nil ? nil : effect)
        await confirm(moved == nil ? .unknown : .observed, in: pid)
        let check = OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: moved == nil ? .unknown : .passed,
            expected: "focus moved", observed: moved == nil ? effect?.family : "focus moved",
            limits: moved == nil ? [.unattributed] : [], performed: .requested, target: target
        )
        guard let moved else {
            return ActOutcome(.actedUnverified, "\(performed): the focus did not visibly move"
                + (effect.map { "; what changed (\($0.summary)) is not the focus moving" } ?? "")
                + ". To reach a field, click the field instead of pressing again.", scene: after, check: check)
        }
        return ActOutcome(.foundActed, "\(performed): \(moved)", scene: after, check: check)
    }

    /// Whether the selection holders show where a focus key sent the focus: each panel of each scene has
    /// at most one, as web content reports only on its focused field, and the key typed no tab into a field.
    /// A native window reports a selection on every text field, focused or not, and keeps the window-wide
    /// rule. Counting by panel keeps a browser's address bar, a native field in the top bar, out of the page.
    /// Its limit: the panel stands in for the web area, so a native window with one field in each of two
    /// panels gets the inference (an under-claim), and a browser scene with no panels keeps the old rule.
    static func showsFocus(before: SceneSnapshot, after: SceneSnapshot, effect: SceneEffect?) -> Bool {
        if case .valueChanged = effect { return false }
        return [before, after].allSatisfy { scene in
            Dictionary(grouping: scene.elements.filter { $0.selectedRange != nil }, by: \.section)
                .values.allSatisfy { $0.count <= 1 }
        }
    }

    /// Where the focus went, from the text entry that holds a selection (see `showsFocus`). Nil when
    /// the same entry, or none, holds it on both sides.
    static func focusMove(before: SceneSnapshot, after: SceneSnapshot) -> String? {
        let was = before.elements.filter { $0.selectedRange != nil }
        let now = after.elements.filter { $0.selectedRange != nil }
        if let entered = now.first(where: { element in !was.contains { $0.id == element.id } }) {
            return "the focus moved to '\(entered.label)'"
        }
        if let left = was.first(where: { element in !now.contains { $0.id == element.id } }) {
            return "the focus left '\(left.label)'"
        }
        return nil
    }

    /// Text read from pixels that changed in place is treated as the recognizer reading the same pixels
    /// again, not an element that came or went: both readings leave the pair before an effect is named.
    /// Its limit: a real in-place relabel by a key in an OCR-only app is then unverified, an under-claim,
    /// never an over-claim. New text where there was none, and text gone with nothing in its place, count.
    static func withoutTextRereads(before: SceneSnapshot, after: SceneSnapshot) -> (SceneSnapshot, SceneSnapshot) {
        func isPixelText(_ element: SceneElement) -> Bool {
            element.kind == .text && element.labelOrigin == nil && element.role == nil
        }
        func overlaps(_ element: SceneElement, any others: [SceneElement]) -> Bool {
            others.contains { !$0.bounds.cgRect.intersection(element.bounds.cgRect).isEmpty }
        }
        // Gone and fresh are instances the other scene has fewer of, none in their place: a repeated
        // fragment still pairs here, and a line that only moved is no partner for one restored above it.
        func unmatched(_ scene: SceneSnapshot, in other: SceneSnapshot) -> [SceneElement] {
            scene.elements.filter { element in
                let twins = other.elements.filter { $0.id == element.id }
                return isPixelText(element)
                    && twins.count < scene.elements.filter { $0.id == element.id }.count
                    && !overlaps(element, any: twins)
            }
        }
        let oldLabels = Set(before.elements.map { LabelText.normalize($0.label) })
        let newLabels = Set(after.elements.map { LabelText.normalize($0.label) })
        let gone  = unmatched(before, in: after)
        let fresh = unmatched(after, in: before)
        // Only a label the other scene lacks is dropped: one it still holds names no change anyway, and
        // dropping it would make its namesakes on the other side look new.
        var was = before, now = after
        was.elements.removeAll {
            gone.contains($0) && !newLabels.contains(LabelText.normalize($0.label)) && overlaps($0, any: fresh)
        }
        now.elements.removeAll {
            fresh.contains($0) && !oldLabels.contains(LabelText.normalize($0.label)) && overlaps($0, any: gone)
        }
        return (was, now)
    }

    /// The check of a gesture whose delivery failed part way: what went out is unknown, the condition
    /// it was to be judged on stays unknown.
    static func undelivered(
        _ condition: OperationCheck.Condition,
        method     : OperationCheck.Method,
        expected   : String? = nil,
        target     : SceneElement? = nil
    ) -> OperationCheck {
        OperationCheck(condition: condition, method: method, verdict: .unknown, expected: expected,
                       limits: [.deliveryUncertain], performed: .uncertain,
                       target: target.map(OperationCheck.Target.init))
    }

    /// A value a sentence quotes, cut so the sentence stays readable.
    static func shortened(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? flat.prefix(59) + "…" : flat
    }

    /// The forms in which an answer of the engine quotes a value (`shortened`): its line breaks as spaces, and past
    /// 60 characters its first 59. A text withheld from the answers is withheld in these forms too, in case a
    /// session delivers it without telling the engine (`InputRequest.withholdsText`), which is what keeps it out.
    public static func quotedForms(of value: String) -> [String] {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? [flat, String(flat.prefix(59))] : [flat]
    }

    /// Why a comparison was refused (M2): a capture said it was not read in full. The cause is not named,
    /// since a capture stores none: a list that did not answer and a budget both leave it partial.
    static let notComparable = "the window before or after it was not read in full, so what changed cannot be "
        + "judged from the scenes; observe again before deciding anything from them"

    /// A pop-up confirms menu-shaped changes, but cannot replace a verified window or control change.
    /// A surface already present without a scene change is not evidence that this action opened it.
    static func gatedEffect(
        before            : SceneSnapshot,
        after             : SceneSnapshot,
        targetID          : String,
        popupIsOpen           : Bool,
        target                : SceneElement? = nil,
        countsValueChange     : Bool = false,
        ignoresTextRereads    : Bool = false,
        countsNativeTextChange: Bool = false
    ) -> SceneEffect? {
        let (was, now) = ignoresTextRereads ? withoutTextRereads(before: before, after: after) : (before, after)
        var effect = SceneDifference.effect(
            before: was, after: now, targetID: targetID, target: target, countsValueChange: countsValueChange,
            countsNativeTextChange: countsNativeTextChange
        )
        if case .menuOpened(let labels) = effect, !popupIsOpen { effect = .elementsAppeared(labels: labels) }
        switch effect {
            case .menuOpened, .elementsAppeared: break
            default: return effect
        }
        if popupIsOpen {
            let items = after.elements
                .filter { !$0.isUnlabeled && $0.kind != .icon && (2...40).contains($0.label.count) }
                .prefix(14).map(\.label)
            if items.count >= 2 { effect = .menuOpened(labels: Array(Set(items)).sorted().prefix(6).map { $0 }) }
        }
        return effect
    }
}
