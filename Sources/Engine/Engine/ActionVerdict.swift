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
import Switches

/// Judges action effects and qualifies outcomes from the available evidence.
extension ActionEngine {

    /// Retains uncertain delivery causes and evidence without importing a platform adapter.
    static func preservingCause(_ error: any Error, in outcome: ActOutcome) -> ActOutcome {
        guard let error = error as? GestureEffectUncertain else { return outcome }
        let prior = outcome.check
        let check = OperationCheck(
            condition: prior?.condition ?? .structuralEffect,
            method: prior?.method ?? .sceneDifference,
            methodVersion: prior?.methodVersion ?? OperationCheck.engineVersion,
            verdict: .unknown, expected: prior?.expected, observed: prior?.observed,
            limits: (prior?.limits ?? []) + [.deliveryUncertain], performed: .uncertain,
            substitute: prior?.substitute, target: prior?.target
        )
        return ActOutcome(outcome.kind, outcome.message, scene: outcome.scene, check: check,
                          notSent: outcome.notSent, noop: outcome.noop, cause: error.cause)
    }

    private enum VerdictArm: String, Sendable { case off, on }

    private enum MessageArm: String, Sendable { case v1, v2 }

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
        perceived : PerceivedWindow,
        reading   : PerceivedWindow? = nil,
        rereading : Bool = false
    ) async -> ActOutcome? {
        let pid = request.processID
        let target = OperationCheck.Target(element)
        func noteReadBack(_ expected: String, after: PerceivedWindow?) {
            guard !rereading else { return }
            VerdictTrace.current?.recordDirectRead {
                let value = await dependencies.controls?.controlValue(matchingAny: [LabelText.normalize(expected)], in: pid)
                let receipt: MenuItemPress
                if let value {
                    receipt = .sent(LabelText.normalize(value) == LabelText.normalize(expected)
                        ? .confirmed(expected: expected, observed: value) : .contradicted(expected: expected, observed: value))
                } else { receipt = .sent(.unread(expected: expected, reason: "read-back unavailable")) }
                return await judged(receipt, request, element: element, perceived: perceived, reading: after, rereading: true)
                    ?? ActOutcome(.actedUnverified, OutcomeText.choiceReadBackUnavailable)
            }
        }
        switch receipt {
            case .notHandled:
                return nil
            case .refused(let reason):
                await recordPick(request, element: element, before: perceived, after: nil,
                                 attempt: .notAttempted(reason: reason))
                return ActOutcome(.refused, "\(OutcomeText.quoted(element.label)) was not chosen, nothing was sent: \(reason). Observe "
                    + "the list again before choosing.", scene: perceived.scene)
            case .possiblySent(let reason):
                let afterWindow = if rereading { reading } else { await perceive(pid) }
                VerdictTrace.current?.record(before: perceived, target: target, method: .controlValue) { after in
                    let popups = await surfaces(pid).popups
                    let selected = Self.chosenControl(element, before: perceived, after: after, popups: popups) != nil
                    await recordPick(request, element: element, before: perceived, after: after,
                                     attempt: .deliveryFailed(reason))
                    Self.settleTrail?.noteReadBackFromScene()
                    return ActOutcome(selected ? .foundActed : .actedUnverified,
                        selected ? OutcomeText.selectedChoicePresent : OutcomeText.choiceStillUnconfirmed,
                        scene: after.scene, check: OperationCheck(condition: .valueReadBack, method: .controlValue,
                            verdict: selected ? .passed : .unknown, limits: selected ? [] : [.readbackUnavailable],
                            performed: .requested, target: target))
                }
                await recordPick(request, element: element, before: perceived, after: afterWindow,
                                 attempt: .deliveryFailed(reason))
                return ActOutcome(.actedUnverified, "choosing \(OutcomeText.quoted(element.label)): \(reason), so the choice may have "
                    + "been applied: observe the control before anything else, and never choose it again blindly.",
                    scene: afterWindow?.scene, check: OperationCheck(
                        condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                        limits: [.deliveryUncertain], performed: .uncertain, target: target))
            case .sent(.unattested):
                if !rereading { await pause(timing.popupCommit) }
                let openSurfaces = await surfaces(pid)
                let stillOpen = openSurfaces.hasOpenPopup
                let afterWindow = if rereading { reading } else { await perceive(pid) }
                let after = afterWindow?.scene
                await recordPick(request, element: element, before: perceived, after: afterWindow)
                if stillOpen, SwitchBoard.current.arm("outcome", default: MessageArm.v1) == .v2,
                   let afterWindow,
                   Self.chosenControl(element, before: perceived, after: afterWindow,
                                      popups: openSurfaces.popups) != nil {
                    return ActOutcome(.foundActed, OutcomeText.selectedChoicePresent, scene: after,
                        check: OperationCheck(condition: .menuItemChosen, method: .controlValue, verdict: .passed,
                            expected: element.label, observed: element.label, limits: [.commandEffectUnchecked],
                            performed: .requested, target: target))
                }
                let check = OperationCheck(
                    condition: .menuClosedAfterChoice, method: .windowCensus, verdict: stillOpen ? .failed : .passed,
                    expected: "menu closed", observed: stillOpen ? "menu open" : "menu closed",
                    limits: [.commandEffectUnchecked], performed: .requested, target: target
                )
                if stillOpen {
                    return ActOutcome(.actedUnverified, "pressed \(OutcomeText.quoted(element.label)) in the open menu, but the "
                        + "menu is still open: observe before choosing again.", scene: after, check: check)
                }
                return ActOutcome(.foundActed, "chose \(OutcomeText.quoted(element.label)) in the open menu through its accessibility "
                    + "item; the menu closed. Check the command's own effect before going on.", scene: after, check: check)
            case .sent(let readBack):
                let afterWindow = if rereading { reading } else { await perceive(pid) }
                let after = afterWindow?.scene
                await recordPick(request, element: element, before: perceived, after: afterWindow)
                switch readBack {
                    case .confirmed(let expected, let observed):
                        return ActOutcome(.foundActed, "chose \(OutcomeText.quoted(element.label)): after the page settled the control "
                            + "reads it", scene: after, check: OperationCheck(
                                condition: .valueReadBack, method: .controlValue, verdict: .passed, expected: expected,
                                observed: observed, performed: .requested, target: target))
                    case .contradicted(let expected, let observed):
                        noteReadBack(expected, after: afterWindow)
                        return ActOutcome(.actedUnverified, "chose \(OutcomeText.quoted(element.label)), but after the page settled the "
                            + "control reads \(observed.map { "\(OutcomeText.quoted(Self.shortened($0)))" } ?? "no option"): the page did "
                            + "not keep it. Observe and re-decide; do not choose it again blindly.", scene: after,
                            check: OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .failed,
                                                  expected: expected, observed: observed,
                                                  limits: observed == nil ? [.readbackUnavailable] : [],
                                                  performed: .requested, target: target))
                    case .unread(let expected, let reason):
                        noteReadBack(expected, after: afterWindow)
                        return ActOutcome(.actedUnverified, "chose \(OutcomeText.quoted(element.label)), but the control could not be "
                            + "read back (\(reason)): observe it before anything else; do not choose it again blindly.",
                            scene: after, check: OperationCheck(
                                condition: .valueReadBack, method: .controlValue, verdict: .unknown, expected: expected,
                                limits: [.readbackUnavailable], performed: .requested, target: target))
                    case .unattested:
                        return nil
                }
        }
    }

    /// Reads a choice only on its owning control, outside the still-open popup.
    static func chosenControl(
        _ choice: SceneElement,
        before: PerceivedWindow,
        after: PerceivedWindow,
        popups: [CGRect]
    ) -> SceneElement? {
        let label = LabelText.normalize(choice.label)
        guard !label.isEmpty, let owner = choice.container else { return nil }
        let controls = before.scene.elements.filter {
            $0.id != choice.id && ["AXPopUpButton", "AXComboBox", "AXMenuButton"].contains($0.role ?? "")
                && (owner == $0.id || LabelText.normalize(owner) == LabelText.normalize($0.label))
        }
        guard controls.count == 1, let control = controls.first else { return nil }
        let matches = after.scene.elements.filter { candidate in
            guard candidate.id == control.id, candidate.id != choice.id, candidate.role == control.role else { return false }
            let center = candidate.bounds.center
            let point = CGPoint(x: after.frame.minX + center.x * after.frame.width,
                                y: after.frame.minY + center.y * after.frame.height)
            return !popups.contains { $0.contains(point) }
                && (LabelText.normalize(candidate.label) == label
                    || candidate.value.map(LabelText.normalize) == label)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Qualifies evidence with the last wait's limit. The new arm preserves every seen passing effect;
    /// the historical arm preserves only direct read-back and retains its original message.
    static func qualified(_ outcome: ActOutcome, after ended: SettleResult?, readBackFromScene: Bool = false,
                          cap: Duration) -> ActOutcome {
        guard let ended, ended != .settled, [.foundActed, .actedUnverified].contains(outcome.kind),
              let check = outcome.check, check.performed != .none
        else { return outcome }
        let limit: OperationCheck.Limit = ended == .capped ? .settleCapped : .settleUnwatched
        // A read-back method whose value came from the scene's element is the scene.
        let isDirect = [.controlState, .controlValue, .driverReceipt].contains(check.method) && !readBackFromScene
        let usesNewVerdict = SwitchBoard.current.arm("verdict_v2", default: VerdictArm.off) == .on
        let verdict: OperationCheck.Verdict = switch check.verdict {
            case .passed : isDirect || usesNewVerdict ? .passed : .unknown
            case .failed : .unknown
            case .unknown: .unknown
        }
        let qualified = OperationCheck(
            condition: check.condition, method: check.method, methodVersion: check.methodVersion, verdict: verdict,
            expected: check.expected, observed: check.observed, limits: check.limits + [limit], performed: check.performed,
            substitute: check.substitute, target: check.target
        )
        if usesNewVerdict {
            return ActOutcome(verdict == .passed ? outcome.kind : .actedUnverified, outcome.message,
                              scene: outcome.scene, check: qualified, notSent: outcome.notSent, noop: outcome.noop,
                              cause: outcome.cause, lookedAgain: outcome.lookedAgain, waited: outcome.waited)
        }
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
        let code = refusal.reason.split(separator: "#", maxSplits: 1).first
        let category = code?.split(separator: ".", maxSplits: 1).first.map(String.init)
        let cause: NotSentCause = switch category {
        case "seat_not_ready": .seatNotReady
        case "human_intervention": .humanIntervention
        case "input_authority_expired": .inputAuthorityExpired
        case "endpoint_refused", "remote_content_refused", "point_outside_window", "seat_preflight", "input_target_changed":
            .targetUnreachable
        default: .other
        }
        return ActOutcome(.refused, "\(action): nothing was sent. \(refusal.sentence)", scene: scene,
                          notSent: cause, cause: refusal.reason)
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
        let target = Self.inputTrail?.target.map(OperationCheck.Target.init)
        if !movesFocus {
            VerdictTrace.current?.record(before: beforeWindow, target: target, method: .sceneDifference) { after in
                await judgeReading(after, performed: performed, request: request, before: beforeWindow,
                    target: target, targetID: targetID, ghost: ghost, repaint: repaint,
                    countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads, movesFocus: movesFocus)
            }
        }
        await settle(request.processID)
        return await judgeReading(perceive(request.processID), performed: performed, request: request,
            before: beforeWindow, target: target, targetID: targetID, ghost: ghost, repaint: repaint,
            countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads, movesFocus: movesFocus)
    }

    private func judgeReading(_ afterWindow: PerceivedWindow?, performed: String, request: InputRequest,
                              before beforeWindow: PerceivedWindow, target: OperationCheck.Target?, targetID: String?,
                              ghost: String, repaint: String, countsValueChange: Bool,
                              ignoresTextRereads: Bool, movesFocus: Bool) async -> ActOutcome {
        let pid = request.processID
        let before = beforeWindow.scene
        guard let afterWindow else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(performed): no scene could be read afterwards; observe when "
                + "the window is back", check: OperationCheck(
                    condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                    limits: [.noAfterScene, .noExpectation], performed: .requested, target: target))
        }
        let after = afterWindow.scene
        // A capture that says it is not whole compares to nothing (M2), the focus included.
        let popupIsOpen = ActVerification.comparable(before: beforeWindow.capture, after: afterWindow.capture)
            ? (await surfaces(pid)).hasOpenPopup : false
        let evidence = Self.evidence(
            before: beforeWindow, after: afterWindow, targetID: targetID ?? "", popupIsOpen: popupIsOpen,
            countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads,
            countsNativeTextChange: dependencies.countsNativeTextChange
        )
        let comparable = evidence.comparable
        let effect = evidence.learnableEffect
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
                return ActOutcome(.foundActed, "\(performed): \(OutcomeText.summary(effect))", scene: after, check: check)
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
                + (effect.map { "; what changed (\(OutcomeText.summary($0))) is not the focus moving" } ?? "")
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
            return "the focus moved to \(OutcomeText.quoted(entered.label))"
        }
        if let left = was.first(where: { element in !now.contains { $0.id == element.id } }) {
            return "the focus left \(OutcomeText.quoted(left.label))"
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

    /// The current quoted fragments and the older flattened forms, so a session withholding a value can also
    /// remove its escaped or shortened display when it did not set `InputRequest.withholdsText`.
    public static func quotedForms(of value: String) -> [String] {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        var forms = flat.count > 60 ? [flat, String(flat.prefix(59))] : [flat]
        for quoted in [OutcomeText.quoted(value), OutcomeText.quoted(Self.shortened(value))] {
            let rendered = String(quoted.dropFirst().dropLast())
            for form in [rendered, rendered.hasSuffix("…") ? String(rendered.dropLast()) : rendered] {
                if !form.isEmpty && !forms.contains(form) { forms.append(form) }
            }
        }
        return forms
    }

    /// Why a comparison was refused (M2): a capture said it was not read in full. The cause is not named,
    /// since a capture stores none: a list that did not answer and a budget both leave it partial.
    static let notComparable = "the window before or after it was not read in full, so what changed cannot be "
        + "judged from the scenes; observe again before deciding anything from them"

    /// Computes the historical gated effect once and attaches every observable difference.
    static func evidence(
        before: PerceivedWindow, after: PerceivedWindow, targetID: String, popupIsOpen: Bool,
        target: SceneElement? = nil, countsValueChange: Bool = false, ignoresTextRereads: Bool = false,
        countsNativeTextChange: Bool = false
    ) -> GestureEvidence {
        let comparable = ActVerification.comparable(before: before.capture, after: after.capture)
        let effect = comparable ? gatedEffect(before: before.scene, after: after.scene, targetID: targetID,
            popupIsOpen: popupIsOpen, target: target, countsValueChange: countsValueChange,
            ignoresTextRereads: ignoresTextRereads, countsNativeTextChange: countsNativeTextChange) : nil
        let matches = before.scene.elements.filter { $0.id == targetID }
        let selected = target ?? (matches.count == 1 ? matches.first : nil)
        return SceneEvidence.observe(before: before, after: after, target: selected, learnableEffect: effect)
    }

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

/// VerdictTrace owns one action's rereading and pending evidence. All state is protected by its lock.
final class VerdictTrace: @unchecked Sendable {
    @TaskLocal static var current: VerdictTrace?
    @TaskLocal static var isRejudging = false

    static var rejudgeStopped: Bool {
        isRejudging && (Task.isCancelled || InterruptibleWait.current?.stopRequested == true)
    }

    private let lock = NSLock()
    private var ended: ContinuousClock.Instant?
    private var facts: (before: PerceivedWindow, target: OperationCheck.Target?, method: OperationCheck.Method)?
    private var sceneJudge: (@Sendable (PerceivedWindow) async -> ActOutcome)?
    private var directRead: (@Sendable () async -> ActOutcome)?
    private var records: [ActionRecord] = []
    private var uncertain = false
    private var sealed = false

    var beforeWindow: PerceivedWindow? { lock.withLock { facts?.before ?? records.first?.before } }
    private var initialWindowTitles: [String]?
    var windowsBefore: [String]? { lock.withLock { initialWindowTitles } }
    func noteWindows(_ titles: [String]) { lock.withLock { initialWindowTitles = titles } }
    func noteWindowsUnavailable() { lock.withLock { initialWindowTitles = nil } }

    var deliveryIsUncertain: Bool { lock.withLock { uncertain } }
    func noteUncertainDelivery() { lock.withLock { uncertain = true } }

    var gestureEnded: ContinuousClock.Instant? { lock.withLock { ended } }
    var rejudge: (@Sendable (PerceivedWindow) async -> ActOutcome)? { lock.withLock { sceneJudge } }
    var reread: (@Sendable () async -> ActOutcome)? { lock.withLock { directRead } }

    func noteGestureEnded(at instant: ContinuousClock.Instant = .now) { lock.withLock { ended = instant } }

    func record(before: PerceivedWindow, target: OperationCheck.Target?, method: OperationCheck.Method,
                rejudge: @escaping @Sendable (PerceivedWindow) async -> ActOutcome) {
        lock.withLock {
            facts = (before, target, method)
            sceneJudge = rejudge
            directRead = nil
        }
    }

    func recordDirectRead(_ reread: @escaping @Sendable () async -> ActOutcome) {
        lock.withLock { directRead = reread; sceneJudge = nil }
    }

    /// Keeps each gesture's record; only a rejudge replaces the last matching record, keeping its delivery diagnostic.
    func hold(_ record: ActionRecord) {
        lock.withLock {
            guard !sealed else { return }
            if Self.isRejudging, let index = records.lastIndex(where: {
                $0.bundleID == record.bundleID && $0.element.id == record.element.id && $0.verb == record.verb
            }) {
                let prior = records[index]
                if case .deliveryFailed = prior.attempt {
                    records[index] = ActionRecord(bundleID: record.bundleID, element: record.element, verb: record.verb,
                        effect: record.effect, windowTitleAfter: record.windowTitleAfter, before: record.before,
                        after: record.after, attempt: prior.attempt, evidence: record.evidence)
                } else { records[index] = record }
            } else { records.append(record) }
        }
    }

    /// A cut reading leaves no final after-sample for the interrupted action.
    func withdrawAfter() {
        lock.withLock {
            sealed = true
            records = records.map { record in
                ActionRecord(bundleID: record.bundleID, element: record.element, verb: record.verb,
                    effect: record.effect, windowTitleAfter: nil, before: record.before, after: nil, attempt: record.attempt)
            }
        }
    }

    func seal() { lock.withLock { sealed = true } }

    /// Carries the final predicate result to observers without retaining its operands.
    func applyExpectation(_ check: OperationCheck?) {
        lock.withLock {
            guard !sealed else { return }
            records = records.map { record in
                ActionRecord(bundleID: record.bundleID, element: record.element, verb: record.verb,
                    effect: record.effect, windowTitleAfter: record.windowTitleAfter,
                    before: record.before, after: record.after, attempt: record.attempt,
                    evidence: record.evidence, check: check)
            }
        }
    }

    func heldRecords() -> [ActionRecord] { lock.withLock { records } }
}

extension ActionEngine {
    /// Retains the census only for a window predicate, before the action can send input.
    func captureExpectationWindows(in processID: pid_t) async {
        guard case .window = ScreenExpectation.current else { return }
        do {
            let titles = try await dependencies.windows.windows(ownedBy: processID).map { $0.title ?? "" }
            VerdictTrace.current?.noteWindows(titles)
        } catch {
            // An unread census remains nil, so the expectation cannot assert a window's absence.
            VerdictTrace.current?.noteWindowsUnavailable()
        }
    }

    /// Compares volatile final facts and retains only the comparison's result, never its operands.
    static func expectationOutcome(
        _ expectation: ScreenExpectation,
        outcome: ActOutcome,
        before: SceneSnapshot?,
        after: SceneSnapshot?,
        windows: [String]?,
        comparable: Bool,
        beforeWindows: [String]? = nil
    ) -> ActOutcome {
        let result: (verdict: OperationCheck.Verdict, observed: String)
        let prior: (verdict: OperationCheck.Verdict, observed: String)
        let kind: String
        let method: OperationCheck.Method
        switch expectation {
        case .window:
            kind = "window"
            method = .windowCensus
            if windows != nil, beforeWindows != nil {
                result = expectation.judge(windows: windows, scene: after)
                prior = expectation.judge(windows: beforeWindows, scene: before)
            } else {
                result = (.unknown, OutcomeText.expectationCensusUnreadable)
                prior = (.unknown, OutcomeText.expectationCensusUnreadable)
            }
        case .element(_, let expected):
            kind = "element"
            switch expected {
            case .value: method = .controlValue
            case .state: method = .controlState
            case .present, .absent: method = .sceneDifference
            }
            result = comparable ? expectation.judge(windows: nil, scene: after)
                : (.unknown, OutcomeText.expectationScenesIncomparable)
            prior = expectation.judge(windows: nil, scene: before)
        }
        let already = result.verdict == .passed && prior.verdict == .passed
        let verdict: OperationCheck.Verdict = result.verdict == .passed
            ? (prior.verdict == .unknown ? .unknown : already ? .failed : .passed) : result.verdict
        let limits = (outcome.check?.limits ?? []).filter {
            ![.noExpectation, .unattributed, .noAfterScene, .readbackUnavailable].contains($0)
                && !(verdict == .unknown && [.settleCapped, .settleUnwatched].contains($0))
        } + (verdict == .unknown ? [.readbackUnavailable] : [])
        let observed = already ? OutcomeText.expectationAlreadySatisfied : result.observed
        let check = OperationCheck(condition: .structuralEffect, method: method, verdict: verdict,
            expected: kind, observed: observed,
            limits: limits, performed: outcome.check?.performed ?? .requested, target: outcome.check?.target)
        return ActOutcome(verdict == .passed ? .foundActed : .actedUnverified, observed,
            scene: outcome.scene, check: check, notSent: outcome.notSent,
            noop: already ? .statePresent : outcome.noop, cause: outcome.cause,
            lookedAgain: outcome.lookedAgain, waited: outcome.waited)
    }

    /// Applies a bound predicate regardless of the switch that exposes single-gesture arguments.
    func concluded(_ outcome: ActOutcome, settles: SettleTrail, in processID: pid_t) async -> ActOutcome {
        let final = await concludedReading(outcome, settles: settles, in: processID)
        guard let expectation = ScreenExpectation.current,
              [.foundActed, .actedUnverified].contains(final.kind),
              final.check?.performed != .substitute else { return final }
        let trace = VerdictTrace.current
        // The evidence carries capture comparability; expectation operands remain in RAM.
        let record = trace?.heldRecords().last
        let before = trace?.beforeWindow ?? Self.inputTrail?.windows.first
        let after = record?.after ?? Self.inputTrail?.windows.last
        let comparable = record?.evidence?.comparable
            ?? (before.map { !ActVerification.refusesComparison($0.capture) } == true
                && after.map { !ActVerification.refusesComparison($0.capture) } != false)
        let windows: [String]?
        if case .window = expectation {
            do { windows = try await dependencies.windows.windows(ownedBy: processID).map { $0.title ?? "" } }
            catch { windows = nil }
        } else { windows = nil }
        let checked = Self.expectationOutcome(expectation, outcome: final, before: before?.scene,
            after: final.scene, windows: windows, comparable: comparable, beforeWindows: trace?.windowsBefore)
        trace?.applyExpectation(checked.check)
        await confirm(checked.check?.verdict == .passed ? .observed : checked.check?.verdict == .failed ? .absent : .unknown,
                      in: processID)
        return checked
    }

    /// Finishes the first verdict and, when eligible, reads once more without dispatching any input.
    private func concludedReading(_ outcome: ActOutcome, settles: SettleTrail, in processID: pid_t) async -> ActOutcome {
        let initialEnding = settles.last
        let qualified = Self.checked(Self.qualified(outcome, after: initialEnding,
            readBackFromScene: settles.readBackFromScene, cap: timing.clickSettle))
        let first: ActOutcome
        if SecondLook.isEnabled, let ended = VerdictTrace.current?.gestureEnded {
            first = qualified.with(lookedAgain: qualified.lookedAgain, waited: ended.duration(to: .now))
        } else { first = qualified }
        guard SecondLook.isEnabled, let trace = VerdictTrace.current, let ended = trace.gestureEnded,
              let mode = SecondLook.mode(for: first.check, alreadyLooked: first.lookedAgain),
              trace.rejudge != nil || trace.reread != nil else { return first }
        func cut() -> ActOutcome {
            trace.withdrawAfter()
            return SecondLook.cut(first)
        }
        if first.check?.performed == .uncertain { trace.noteUncertainDelivery() }
        if Task.isCancelled || InterruptibleWait.current?.stopRequested == true { return cut() }
        var ending = initialEnding
        var reading: PerceivedWindow?
        if mode == .wait {
            let cap = SecondLook.remaining(budget: timing.secondLookCap, since: ended, now: .now)
            if let settling = dependencies.settling {
                let read: @Sendable () async -> SettleResult? = {
                    await settling.settle(in: processID, cap: cap)
                }
                if let wait = InterruptibleWait.current { ending = await wait.reading(read) }
                else { ending = await read() }
            } else if trace.rejudge != nil {
                var remaining = cap
                var previous = await perceive(processID)
                ending = .capped
                while remaining > .zero, InterruptibleWait.current?.stopRequested != true {
                    let interval = min(remaining, .milliseconds(250))
                    if let wait = InterruptibleWait.current {
                        let pause = self.pause
                        guard await wait.reading({ await pause(interval); return true }) != nil else { return cut() }
                    } else { await pause(interval) }
                    remaining = min(remaining - interval,
                        SecondLook.remaining(budget: timing.secondLookCap, since: ended, now: .now))
                    let next = await perceive(processID)
                    if let previous, let next,
                       previous.scene.elements == next.scene.elements,
                       previous.scene.windowTitle == next.scene.windowTitle {
                        reading = next
                        ending = .settled
                        break
                    }
                    previous = next
                }
                if reading == nil { reading = previous }
            }
        }
        if Task.isCancelled || InterruptibleWait.current?.stopRequested == true { return cut() }
        if let ending { settles.note(ending) }
        let judged: ActOutcome?
        if let reread = trace.reread {
            let read: @Sendable () async -> ActOutcome? = {
                await VerdictTrace.$isRejudging.withValue(true) {
                    guard !VerdictTrace.rejudgeStopped else { return nil }
                    return await reread()
                }
            }
            if let wait = InterruptibleWait.current { judged = await wait.reading(read) }
            else { judged = await read() }
        } else if let rejudge = trace.rejudge {
            if reading == nil { reading = await perceive(processID) }
            if let reading {
                let read: @Sendable () async -> ActOutcome? = {
                    await VerdictTrace.$isRejudging.withValue(true) {
                        guard !VerdictTrace.rejudgeStopped else { return nil }
                        return await rejudge(reading)
                    }
                }
                if let wait = InterruptibleWait.current { judged = await wait.reading(read) }
                else { judged = await read() }
            } else { judged = nil }
        } else { judged = nil }
        if Task.isCancelled || InterruptibleWait.current?.stopRequested == true { return cut() }
        guard let judged else {
            trace.withdrawAfter()
            return first.with(scene: nil).with(check: first.check?.adding([.noAfterScene]))
                .with(lookedAgain: true, waited: ended.duration(to: .now))
        }
        var final = Self.checked(Self.qualified(judged, after: ending,
            readBackFromScene: settles.readBackFromScene, cap: timing.secondLookCap))
        if first.check?.performed == .uncertain, let check = final.check {
            final = ActOutcome(final.kind, final.message, scene: final.scene, check: OperationCheck(
                condition: check.condition, method: check.method, methodVersion: check.methodVersion,
                verdict: check.verdict, expected: check.expected, observed: check.observed,
                limits: check.limits + [.deliveryUncertain], performed: .uncertain,
                substitute: check.substitute, target: check.target), cause: first.cause)
        }
        return final.with(lookedAgain: true, waited: ended.duration(to: .now))
    }
}
