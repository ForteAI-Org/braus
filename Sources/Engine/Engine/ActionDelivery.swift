//
//  ActionDelivery.swift
//  Braus
//
//  Created by Codex on 01/11/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// Delivers inputs and records the gestures and perceptions used to judge them.
extension ActionEngine {

    @TaskLocal
    private static var uncertainDelivery: UncertainDelivery?

    enum Aim { case none, expecting(String), over(String) }

    /// Refuses later gestures after stop and every gesture inside an uncertain delivery's judge.
    /// Opening in the defer preserves an atomic delivery even when stop arrives while it is running.
    func post(_ gesture: Gesture, aim: Aim = .none, in processID: pid_t) async throws {
        guard InterruptibleWait.current?.stopRequested != true, Self.uncertainDelivery == nil, !VerdictTrace.isRejudging else {
            throw GestureNotSent(reason: "human_intervention", sentence: OutcomeText.humanInterventionRefusal)
        }
        var mayHaveSent = true
        defer {
            if mayHaveSent { VerdictTrace.current?.noteGestureEnded() }
            InterruptibleWait.current?.open()
        }
        do {
            switch aim {
            case .none: try await dependencies.actuator.perform(gesture, in: processID)
            case .expecting(let label): try await dependencies.actuator.perform(gesture, expecting: label, in: processID)
            case .over(let label): try await dependencies.actuator.perform(gesture, over: label, in: processID)
            }
        } catch {
            mayHaveSent = !(error is GestureNotSent)
            throw error
        }
    }

    /// Classifies a failed delivery without interpreting the producer's words.
    static func delivery(after error: any Error, sent: Int) -> DeliveryResult {
        if let stopped = error as? TextStopped {
            return .uncertain(UncertainDelivery(kind: .stoppedBeforeText, sentBefore: stopped.sentBefore,
                                                detail: stopped.reason))
        }
        if let refusal = error as? GestureNotSent {
            if sent == 0 { return .notSent(refusal) }
            return .uncertain(UncertainDelivery(kind: .refusedAfterOthers, sentBefore: sent, detail: "\(refusal)"))
        }
        let cause = (error as? GestureEffectUncertain)?.cause
        let kind: UncertainDelivery.Kind = error is GestureMayHaveActed || cause != nil
            ? .mayHaveTakenEffect : .failedAfterEvents
        return .uncertain(UncertainDelivery(kind: kind, sentBefore: sent, detail: "\(error)", cause: cause))
    }

    /// Runs the site's reading and verdict once, with no delivery permitted.
    func afterUncertainDelivery(_ uncertain: UncertainDelivery, in processID: pid_t,
                                judge: () async -> ActOutcome) async -> ActOutcome {
        Self.inputTrail?.failed(uncertain.detail)
        return await Self.$uncertainDelivery.withValue(uncertain) {
            let judged = await judge()
            let outcome: ActOutcome
            if judged.scene == nil {
                let prior = judged.withStatedCheck.check
                outcome = ActOutcome(.actedUnverified, judged.message, check: OperationCheck(
                    condition: prior?.condition ?? .none, method: prior?.method ?? .none,
                    methodVersion: prior?.methodVersion ?? OperationCheck.engineVersion, verdict: .unknown,
                    expected: prior?.expected, limits: (prior?.limits ?? []) + [.noAfterScene],
                    performed: .requested, target: prior?.target
                ))
            } else { outcome = judged }
            return Self.markedUncertain(outcome, uncertain)
        }
    }

    static func markedUncertain(_ outcome: ActOutcome, _ uncertain: UncertainDelivery) -> ActOutcome {
        let prior = outcome.withStatedCheck.check
        let check = OperationCheck(
            condition: prior?.condition ?? .none, method: prior?.method ?? .none,
            methodVersion: prior?.methodVersion ?? OperationCheck.engineVersion,
            verdict: prior?.verdict ?? .unknown,
            expected: prior?.expected, observed: prior?.observed,
            limits: (prior?.limits ?? []) + [.deliveryUncertain],
            performed: .uncertain, substitute: prior?.substitute, target: prior?.target
        )
        return ActOutcome(outcome.kind == .foundActed ? .foundActed : .actedUnverified,
                          outcome.message + "; " + OutcomeText.deliveryFailure + uncertain.detail,
                          scene: outcome.scene, check: check, cause: uncertain.cause ?? outcome.cause)
    }

    /// A takeover keeps verified evidence and withdraws an unfinished reading of the person's new state.
    static func stoppedOutcome(_ outcome: ActOutcome) -> ActOutcome {
        guard let wait = InterruptibleWait.current, wait.isOpen, wait.stopRequested else { return outcome }
        guard outcome.notSent == nil else { return outcome }
        let prior = outcome.withStatedCheck.check
        guard outcome.kind != .foundActed, prior?.verdict != .passed else { return outcome }
        let check = OperationCheck(
            condition: prior?.condition ?? .none, method: prior?.method ?? .none,
            methodVersion: prior?.methodVersion ?? OperationCheck.engineVersion, verdict: .unknown,
            expected: prior?.expected, limits: (prior?.limits ?? []) + [.noAfterScene],
            performed: prior?.performed == .uncertain ? .uncertain : .requested,
            target: prior?.target
        )
        return ActOutcome(.actedUnverified, outcome.message, check: check, cause: outcome.cause)
    }

    /// A judge records the failed delivery rather than teaching a successful delivery to memory.
    func record(_ record: ActionRecord) async {
        let evidence = record.evidence ?? record.before.flatMap { before in
            record.after.map { after in
                SceneEvidence.observe(before: before, after: after, target: record.element, learnableEffect: record.effect)
            }
        }
        let attempt = Self.uncertainDelivery.map { ActionAttempt.deliveryFailed($0.detail) } ?? record.attempt
        let final = ActionRecord(bundleID: record.bundleID, element: record.element, verb: record.verb,
            effect: record.effect, windowTitleAfter: record.windowTitleAfter, before: record.before,
            after: record.after, attempt: attempt,
            evidence: evidence?.withWait(lookedAgain: false, waited: nil, ending: Self.settleTrail?.last), check: record.check)
        if let trace = VerdictTrace.current { trace.hold(final) }
        else { await dependencies.observer?.record(final) }
    }

    /// Publishes a held action with the final second reading's wait, preserving its dispatch diagnostic.
    func publish(_ record: ActionRecord, outcome: ActOutcome, ending: SettleResult?) async {
        await dependencies.observer?.record(ActionRecord(bundleID: record.bundleID, element: record.element,
            verb: record.verb, effect: record.effect, windowTitleAfter: record.windowTitleAfter,
            before: record.before, after: record.after, attempt: record.attempt,
            evidence: record.evidence?.withWait(lookedAgain: outcome.lookedAgain, waited: outcome.waited, ending: ending),
            check: record.check == nil ? nil : outcome.check))
    }

    // MARK: Deliver

    /// Delivers one input beyond a click and answers with an outcome a model can act on next: every
    /// target resolved like `act`'s, the gestures through the actuator, the effect judged by perceiving
    /// again. Only a seen effect is `found_acted`.
    public func deliver(_ request: InputRequest) async -> ActOutcome {
        defer { InterruptibleWait.current?.close() }
        let trail = InputTrail()
        let settles = SettleTrail()
        let trace = VerdictTrace()
        let outcome = await VerdictTrace.$current.withValue(trace) {
            await Self.$inputTrail.withValue(trail) {
                await Self.$settleTrail.withValue(settles) {
                    await captureExpectationWindows(in: request.processID)
                    let delivered = await self.deliverInput(request)
                    let final = Self.stoppedOutcome(await concluded(delivered, settles: settles, in: request.processID))
                    if final.scene == nil, final.check?.limits.contains(.noAfterScene) == true {
                        trace.withdrawAfter()
                    }
                    trace.seal()
                    for record in trace.heldRecords() { await publish(record, outcome: final, ending: settles.last) }
                    return final
                }
            }
        }
        guard let observer = dependencies.observer else { return outcome }
        let windows = trail.windows
        var isMenuChoice = false
        if case .contextMenu = request.input { isMenuChoice = true }
        let attempt: ActionAttempt
        if let failure = trail.deliveryFailure {
            attempt = .deliveryFailed(failure)
        } else {
            attempt = switch (outcome.kind, outcome.check?.performed) {
            case (.dryRun, _), (.refused, _), (.honestMiss, .none?), (.ambiguous, _):
                .notAttempted(reason: outcome.kind.rawValue)
            case (_, .uncertain?):
                .deliveryFailed(outcome.message)
            default:
                .delivered
            }
        }
        let after = outcome.check?.limits.contains(.noAfterScene) == true
            ? nil : windows.count >= 2 ? windows.last : nil
        let evidence = windows.first.flatMap { before in
            after.map { after in
                SceneEvidence.observe(before: before, after: after, target: trail.target, learnableEffect: trail.effect)
                    .withWait(lookedAgain: outcome.lookedAgain,
                              waited: outcome.waited, ending: settles.last)
            }
        }
        await observer.record(InputRecord(
            bundleID: request.bundleID,
            input   : request.input,
            target  : trail.target,
            before  : windows.first,
            menu    : isMenuChoice && windows.count >= 3 ? windows[1] : nil,
            after   : after,
            effect  : trail.effect,
            attempt : attempt,
            evidence: evidence,
            check: ScreenExpectation.current == nil ? nil : outcome.check
        ))
        return outcome
    }

    /// What a fresh perception attests about where the request's text would go, before anything of the call
    /// is written: never the scene the model last read. A typed text's field is resolved as `typeText` resolves
    /// it; it is secure by its role, and ordinary only when it takes text and its provider attests its physical
    /// identity, which the dispatch is then bound to. An inserted text goes to the focus, as its provider attests
    /// it. Anything else is unclassified, with its cause. Nothing is sent.
    public func classify(_ request: InputRequest) async -> TextTargetClass {
        switch request.input {
            case .typeText(_, let field, _):
                guard let perceived = try? await dependencies.scenes.currentScene(of: request.processID) else {
                    return .unclassified(.noScene)
                }
                let element: SceneElement
                do throws(Unresolved) {
                    element = try resolved(
                        field, section: request.section, in: perceived.scene, appName: request.appName,
                        preferNativeControls: true, preferTextEntry: true
                    )
                } catch {
                    return .unclassified(.unresolved)
                }
                if element.role == Self.secureFieldRole { return .secure }
                guard AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "") else {
                    return .unclassified(.notTextEntry)
                }
                guard let identity = perceived.identities[element.id] else { return .unclassified(.identityUnattested) }
                return .ordinary(TextTargetBinding(identity: identity, role: element.role, label: element.label))
            case .insertText:
                switch await dependencies.controls?.focusedField(in: request.processID) ?? .unknown {
                    case .ordinary(let identity): return .ordinary(TextTargetBinding(identity: identity, role: nil, label: ""))
                    case .secure                : return .secure
                    case .unknown               : return .unclassified(.focusUnknown)
                }
            case .pressKey, .scroll, .drag, .contextMenu:
                return .unclassified(.unsupported)
        }
    }

    /// Why the focus is not the field a bound text was classified for, nil when it is: read after the click,
    /// before each preparation key and again right before the text, so the type is checked with the identity.
    /// A race remains between the last read and the text, which no read can close.
    static func focusMismatch(_ focus: FocusedField, bound binding: TextTargetBinding) -> String? {
        switch focus {
            case .ordinary(let identity) where identity == binding.identity: nil
            case .ordinary: "the focus is on another field"
            case .secure  : "the focused field is a secure field now"
            case .unknown : "the focus could not be attested"
        }
    }

    /// The input as `deliver` performs it, every perception it takes and the effect it attributes left
    /// in the task's `InputTrail` for the record.
    private func deliverInput(_ request: InputRequest) async -> ActOutcome {
        let pid = request.processID
        guard let perceived = await perceive(pid) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: request.appName, processID: pid))
        }
        switch request.input {
            case .typeText(let text, let field, let replacing):
                return await typeText(text, into: field, replacing: replacing, request, perceived: perceived)
            case .insertText(let text, let expectedValue):
                return await insertText(text, expecting: expectedValue, request)
            case .pressKey(let chord, let times):
                return await pressKey(chord, times: times, request, perceived: perceived)
            case .scroll(let lines, let target):
                return await scroll(lines: lines, over: target, request, perceived: perceived)
            case .drag(let source, let end):
                return await drag(from: source, to: end, request, perceived: perceived)
            case .contextMenu(let target, let item):
                return await chooseInContextMenu(item, on: target, request, perceived: perceived)
        }
    }

    // MARK: The inputs

    /// The longest text typed as a hand types it, one key pair per character; longer text is inserted
    /// on one event. Measured by the Driver on macOS 27.0 into background windows: at 128 clusters the
    /// two routes are within a fraction of a second of each other, so typing costs nothing there and
    /// keeps the keystrokes a completion list or a validator watches, while past it the typed cost grows
    /// with what the editor holds (0,66 ms a cluster on a browser and 11,3 ms on a native control at
    /// 8192) and an insertion stays flat.
    static let typedTextLimit = 128

    /// What selects everything a focused field holds, with no menu in the path. Command and A is a menu
    /// key equivalent in AppKit and Chromium, measured delivered and acted on by neither on a background
    /// window, while the standard key bindings are answered by the field itself: Command and Up to the
    /// start, then Command, Shift and Down selecting to the end, which a Qt line edit answers too.
    /// Command and A comes last because DaVinci's Search field answers it itself, as measured, and where
    /// a menu would resolve it instead it does nothing and leaves the selection as it was.
    ///
    /// Only a field whose value was read as holding text is sent them: a web application binds the
    /// same arrows. Slack opens the person's last message for editing on an Up arrow in its empty
    /// composer, and the text typed next went into that message, twice in a row, on 25 Sep 2026. A
    /// field read as empty has nothing to select; one whose value cannot be read, which is what a
    /// Chromium composer is, is selected with a triple click, which sends no key an application can
    /// bind, and selects the paragraph clicked in a field of several. A field of a file panel the
    /// system draws is selected the same way (`selectsFieldsByTripleClick`), whatever it holds.
    static let selectAll: [Gesture] = [
        .key(code: Key.upArrow, modifiers: .command),
        .key(code: Key.downArrow, modifiers: [.command, .shift]),
        .character("a", modifiers: .command),
    ]

    /// How a field is focused and prepared before the text: at its end to append, and to replace,
    /// by what its value says it holds (`selectAll`), or by clicks alone where `byTripleClick` says so.
    static func preparing(
        field value  : String?,
        at point     : CGPoint,
        replacing    : Bool,
        byTripleClick: Bool
    ) -> [Gesture] {
        guard replacing else { return [.click(at: point), endOfField] }
        switch value {
            case nil:                       return [.click(at: point, count: 3)]
            case ""?:                       return [.click(at: point)]
            case .some where byTripleClick: return [.click(at: point, count: 3)]
            case .some:                     return [.click(at: point)] + selectAll
        }
    }

    /// The extension kept when `text` replaces the file name `value` in a file panel: measured on
    /// 30/09/2026, Photoshop's Save As panel selects only the base name and saves exactly what the field
    /// holds, so a triple click would drop it. Nil when `text` has an extension of its own or is a path.
    static func keptExtension(of value: String?, replacedBy text: String) -> Substring? {
        func fileExtension(_ name: Substring) -> Substring? {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
            let suffix = name[name.index(after: dot)...]
            guard (1...6).contains(suffix.count),
                  suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            return suffix
        }
        guard let value, !text.contains("/"), !text.hasPrefix("~"), fileExtension(Substring(text)) == nil,
              let name = value.split(separator: "/", omittingEmptySubsequences: false).last
        else { return nil }
        return fileExtension(name)
    }

    /// Command and Down, the key binding that moves to the end of a document, and of a field.
    static let endOfField: Gesture = .key(code: Key.downArrow, modifiers: .command)

    /// Said after a Command chord whose effect was not seen on a background window.
    static let menuShortcutNote = " Background support for a menu shortcut depends on the target. "
        + "Verify the intended effect; prefer the menu tool or the target's contextual menu for an unsupported "
        + "shortcut. Do not repeat an unconfirmed command."

    /// What a key that changed nothing is answered with in a file panel the system draws out of process. Measured
    /// in Preview's Save As and Export sheets on 14/10/2026: Command-Shift-G opened Go to Folder 3 times in 20, each
    /// about 3 s after a click that selected the name field or a sidebar row, and many such clicks were followed by
    /// nothing; after typing the name or pressing a button it never did. The cause is the seat's delivery into an
    /// attached sheet, not yet qualified, so the answer bounds the retries instead of promising a remedy.
    static let filePanelKeyGhost = "In a file panel drawn by the system a key from the background often has no "
        + "effect. Press it at most once more, a few seconds after a click on the name field or a sidebar row; if it "
        + "still does nothing, that way is closed: say so instead of trying more keys."

    /// Preserves a caller-established focus and selection. Pixel text alone cannot verify the
    /// resulting value, and an uncertain insertion must never be replayed automatically.
    private func insertText(
        _ text        : String,
        expecting     : String?,
        _ request     : InputRequest
    ) async -> ActOutcome {
        guard !text.isEmpty else { return ActOutcome(.refused, "insert_text needs a nonempty text") }
        if ActionPolicy.containsControlCharacter(text) {
            return ActOutcome(.refused, ActionPolicy.controlCharacterRefusal)
        }
        let checksCommit = text.contains("\n") || text.contains("\r")
        let rehearsal = request.isDryRun
            ? ActOutcome(.dryRun, "would insert \(text.count) characters at the current focus and selection") : nil
        if let rehearsal, !checksCommit { return rehearsal }
        let pid = request.processID
        let perceived: PerceivedWindow?
        if checksCommit {
            do {
                perceived = try await dependencies.scenes.currentScene(of: pid)
            } catch {
                return ActOutcome(.honestMiss, "The focused field's scene could not be read; nothing was sent.")
            }
        } else {
            perceived = nil
        }
        // The focus as its provider attests it, read right before the text: a bound insertion goes only into the field
        // it was classified for. Only an ordinary focus is read back; comparison values stay in this function.
        let focus = await dependencies.controls?.focusedField(in: pid) ?? .unknown
        if let binding = request.binding, let why = Self.focusMismatch(focus, bound: binding) {
            return ActOutcome(.refused, "inserting text: \(why), not the field this call recorded: nothing was sent. "
                + "Observe, then insert again.")
        }
        if let perceived, let target = Self.committingTarget(focus, in: perceived),
           let refused = committingRefusal(request.input, into: target, scene: perceived.scene) {
            return refused
        }
        if let rehearsal { return rehearsal }
        let attested: Bool
        if case .ordinary = focus { attested = true } else { attested = false }
        func judge() async -> ActOutcome {
            await settle(pid)
            if !attested {
                let after = await perceive(pid)?.scene
                await confirm(.unknown, in: pid)
                var isSecure = false
                if case .secure = focus { isSecure = true }
                let check = expecting == nil
                    ? OperationCheck(condition: .none, method: .none, verdict: .unknown,
                                     limits: [.noExpectedValue, .valueWithheld], performed: .requested)
                    : OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                                     limits: [.readbackUnavailable, .valueWithheld], performed: .requested)
                return ActOutcome(.actedUnverified, (isSecure ? "inserted text into a secure field: it is never read back"
                    : "inserted text at a focus that could not be attested as an ordinary field: it is not read back")
                    + ", so the text cannot be confirmed here; observe its effect before further input and never insert "
                    + "again blindly", scene: after, check: check)
            }
            let after = await perceive(pid)?.scene
            VerdictTrace.current?.recordDirectRead { await evaluate(after) }
            return await evaluate(after)
        }
        @Sendable func evaluate(_ after: SceneSnapshot?) async -> ActOutcome {
            let value = await dependencies.controls?.focusedFieldValue(in: pid)
            let verified = expecting != nil && value != nil && value == expecting
            await confirm(verified ? .observed : .unknown, direct: true, in: pid)
            // Compare in memory only: neither value belongs in the check or the answer.
            let check = expecting == nil
                ? OperationCheck(condition: .none, method: .none, verdict: .unknown,
                                 limits: [.noExpectedValue, .valueWithheld], performed: .requested)
                : OperationCheck(condition: .valueReadBack, method: .controlValue,
                                 verdict: verified ? .passed : value == nil ? .unknown : .failed,
                                 limits: (value == nil ? [.readbackUnavailable] : []) + [.valueWithheld],
                                 performed: .requested)
            if verified {
                return ActOutcome(.foundActed, "inserted text: the focused field matches the requested value",
                                  scene: after, check: check)
            }
            return ActOutcome(.actedUnverified,
                "inserted text at the current focus and selection, but the exact resulting value is unconfirmed; "
                + "observe its effect before further input and never insert again blindly", scene: after, check: check)
        }
        switch await send([.insert(text)], to: pid) {
        case .delivered: break
        case .notSent(let refusal):
            return Self.notSent(refusal, "inserting text") ?? ActOutcome(.refused, refusal.sentence)
        case .uncertain(let u):
            return await afterUncertainDelivery(u, in: pid, judge: judge)
        }
        return await judge()
    }

    private func typeText(
        _ text     : String,
        into field : String,
        replacing  : Bool,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard !text.isEmpty else { return ActOutcome(.refused, "type_text needs a nonempty text") }
        if ActionPolicy.containsControlCharacter(text) {
            return ActOutcome(.refused, ActionPolicy.controlCharacterRefusal)
        }
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(
                field, section: request.section, in: perceived.scene, appName: request.appName,
                preferNativeControls: true, preferTextEntry: true
            )
        } catch {
            return error.outcome
        }
        Self.inputTrail?.resolve(element)
        // A bound text goes only into the field it was classified for: the same node, the same role, still not
        // secure. Anything else is refused before any gesture.
        if let binding = request.binding {
            let identity = perceived.identities[element.id]
            if element.role == Self.secureFieldRole || element.role != binding.role || identity != binding.identity {
                let why = element.role == Self.secureFieldRole ? "it is a secure field now"
                    : identity == nil ? "its identity can no longer be attested"
                    : identity != binding.identity ? "another node is in its place" : "its role changed"
                return ActOutcome(.refused, "\(OutcomeText.quoted(element.label)) is not the field this call recorded (\(why)): nothing "
                    + "was typed. Observe, then type again.", scene: perceived.scene)
            }
        }
        if let refused = committingRefusal(request.input, into: .field(element), scene: perceived.scene) {
            return refused
        }
        let point = perceived.globalPoint(of: element)
        let kept = replacing && permissions.selectsFieldsByTripleClick
            ? Self.keptExtension(of: element.value, replacedBy: text)
            : nil
        let typed   = kept.map { text + "." + $0 } ?? text
        let keeping = kept.map { " (kept the extension \(OutcomeText.quoted("." + $0)))" } ?? ""
        // Short per-character events lose supplementary Unicode in Qt and renderers. Bulk payloads
        // preserve it and line breaks, without replaying a partially delivered edit.
        let inserts = typed.count > Self.typedTextLimit || typed.unicodeScalars.contains {
            $0.value > 0xFFFF || $0 == "\n" || $0 == "\r"
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click \(OutcomeText.quoted(element.label)) at \(Int(point.x)),\(Int(point.y)), "
                + (replacing ? "select what it holds" : "move to its end") + " and "
                + (inserts ? "insert" : "type") + " \(typed.count) characters"
                + (kept.map { ", keeping the extension \(OutcomeText.quoted("." + $0))" } ?? ""))
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        let gestures = Self.preparing(
            field        : element.value,
            at           : point,
            replacing    : replacing,
            byTripleClick: permissions.selectsFieldsByTripleClick || request.bundleID == "com.avid.ProTools"
        ) + [inserts ? .insert(typed) : .type(typed)]
        // Text kept in a field the click placed its caret in goes through accessibility too, which a key
        // in between would forget.
        let endOfField = Self.textFieldRoles.contains(element.role ?? "") ? Self.endOfField : nil
        // A secure field's value is never read, nor what was typed into it kept as the check's expectation.
        let isSecure = element.role == Self.secureFieldRole
        let controls = dependencies.controls
        let focusGate: (@Sendable () async -> String?)? = request.binding.map { binding in
            { @Sendable in await Self.focusMismatch(controls?.focusedField(in: pid) ?? .unknown, bound: binding) }
        }
        // The field's click is aimed at the element (`send`), and the gate asks before every later gesture.
        @Sendable func evaluate(_ afterWindow: PerceivedWindow?) async -> ActOutcome {
            let after = afterWindow?.scene
            let composing = inserts ? " This text is inserted as one event; an active input method may reject it." : ""
            if isSecure {
                await confirm(.unknown, in: pid)
                let check = OperationCheck(
                    condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                    limits: [.readbackUnavailable, .valueWithheld], performed: .requested,
                    target: OperationCheck.Target(element)
                )
                return ActOutcome(.actedUnverified, "typed into \(OutcomeText.quoted(element.label))\(keeping): a secure field is never "
                    + "read back, so the text cannot be confirmed here; judge by what follows (the page that "
                    + "answers) instead of typing it again.\(composing)", scene: after, check: check)
            }
            let focused = await dependencies.controls?.focusedFieldValue(in: pid)
            if focused != nil { VerdictTrace.current?.recordDirectRead { await evaluate(afterWindow) } }
            // The focused field's own value is a direct read-back; the scene's element is the scene.
            if focused == nil { Self.settleTrail?.noteReadBackFromScene() }
            let readBack = focused
                ?? after?.elements.first(where: { $0.id == element.id })?.value
                ?? after.flatMap { Self.sameField(as: element, in: $0) }?.value
            let wanted = replacing ? typed : element.value.map { $0 + text }
            await confirm(readBack != nil && readBack == wanted ? .observed : .unknown, direct: focused != nil, in: pid)
            let verdict: OperationCheck.Verdict = switch (readBack, wanted) {
                case (.some(let value), .some(let wanted)): value == wanted ? .passed : .failed
                default                                   : .unknown
            }
            // A text the call withholds is judged here but kept out of the check, and no value of the field is quoted.
            let withholds = request.withholdsText
            let check = OperationCheck(
                condition: .valueReadBack, method: .controlValue, verdict: verdict,
                expected: withholds ? nil : wanted, observed: withholds ? nil : readBack,
                limits: (readBack == nil ? [.readbackUnavailable] : []) + (wanted == nil ? [.previousValueUnknown] : [])
                    + (withholds ? [.valueWithheld] : []),
                performed: .requested, target: OperationCheck.Target(element)
            )
            if withholds, readBack != nil {
                return verdict == .passed
                    ? ActOutcome(.foundActed, "typed into \(OutcomeText.quoted(element.label))\(keeping): the field reads the typed text",
                                 scene: after, check: check)
                    : ActOutcome(.actedUnverified, "typed into \(OutcomeText.quoted(element.label))\(keeping), but the field's value could not "
                                 + "be confirmed as the typed text: observe and re-decide, do not type it again blindly."
                                 + composing, scene: after, check: check)
            }
            switch (readBack, wanted) {
                case (.some(let value), .some(let wanted)) where value == wanted:
                    return ActOutcome(.foundActed, "typed into \(OutcomeText.quoted(element.label))\(keeping): the field reads "
                        + "\(OutcomeText.quoted(Self.shortened(value)))", scene: after, check: check)
                case (.some(let value), .some(let wanted)):
                    return ActOutcome(.actedUnverified, "typed into \(OutcomeText.quoted(element.label))\(keeping) but the field reads "
                        + "\(OutcomeText.quoted(Self.shortened(value))), not \(OutcomeText.quoted(Self.shortened(wanted))): observe and re-decide, do not "
                        + "type it again blindly.\(composing)", scene: after, check: check)
                case (.some(let value), nil):
                    return ActOutcome(.actedUnverified, "typed into \(OutcomeText.quoted(element.label)) and the field reads "
                        + "\(OutcomeText.quoted(Self.shortened(value))), but what it held before could not be read, so the appended text "
                        + "cannot be confirmed: observe and re-decide.", scene: after, check: check)
                case (nil, _):
                    return ActOutcome(.actedUnverified, "typed into \(OutcomeText.quoted(element.label))\(keeping): no field's value could be "
                        + "read afterwards, so the text cannot be confirmed; observe before typing again.\(composing)",
                        scene: after, check: check)
            }
        }
        if !isSecure {
            VerdictTrace.current?.record(before: perceived, target: OperationCheck.Target(element), method: .controlValue,
                                         rejudge: evaluate)
        }
        func judge() async -> ActOutcome {
            await settle(pid)
            return await evaluate(perceive(pid))
        }
        switch await send(gestures, to: pid, over: element.label, redundantAfterAccessibilityClick: endOfField,
                                  afterTheClick: focusGate) {
        case .delivered: break
        case .notSent(let refusal):
            return Self.notSent(refusal, "typing into \(OutcomeText.quoted(element.label))", scene: perceived.scene) ?? ActOutcome(.refused, refusal.sentence)
        case .uncertain(let u):
            return await afterUncertainDelivery(u, in: pid, judge: judge)
        }
        return await judge()
    }

    private func pressKey(
        _ chord  : KeyChord,
        times    : Int,
        _ request: InputRequest,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        if chord.key == .return,
           chord.modifiers.isEmpty || chord.modifiers == .command {
            let focus = await dependencies.controls?.focusedField(in: pid) ?? .unknown
            if let target = Self.committingTarget(focus, in: perceived),
               let refused = committingRefusal(request.input, into: target, scene: perceived.scene) {
                return refused
            }
        }
        if ActionPolicy.closesTheTarget(chord) {
            return ActOutcome(.refused, "\(chord) quits or closes what this session drives: refused. Use the "
                + "window's own control, or close the session.", scene: perceived.scene)
        }
        if ActionPolicy.isDestructive(chord),
           let refused = refusal(destructive: "\(chord)", scene: perceived.scene, needsConsent: "\(chord) deletes in "
               + "most applications: refused. If you want the agent to do this, the person must allow destructive "
               + "actions.") {
            return refused
        }
        if chord.key == .escape, permissions.windowClosure.mayEndTheApplication, !permissions.allowsDestructive {
            let hasOpenPopup = (await surfaces(pid)).hasOpenPopup
            if let refusal = windowClosureRefusal(
                "\(chord)", appName: request.appName, scene: perceived.scene, hasOpenPopup: hasOpenPopup
            ) {
                return refusal
            }
        }
        guard (1...InputRequest.maximumKeyPresses).contains(times) else {
            return ActOutcome(.refused, "a key is pressed 1 to \(InputRequest.maximumKeyPresses) times")
        }
        let pressed = "pressed \(chord)" + (times > 1 ? " \(times) times" : "")
        if request.isDryRun {
            return ActOutcome(.dryRun, "would press \(chord)" + (times > 1 ? " \(times) times" : "")
                + " into the window of \(OutcomeText.quoted(request.appName))")
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        func judge() async -> ActOutcome {
            // A background chord's unchanged scene does not qualify the target's menu support.
            let note = dependencies.activation == nil && chord.modifiers.contains(.command) ? Self.menuShortcutNote : ""
            let outcome = await judged(
                pressed, in: request, before: perceived, targetID: nil,
                // `selectsFieldsByTripleClick` is set exactly while the seat holds a file panel drawn out of process.
                ghost: permissions.selectsFieldsByTripleClick ? Self.filePanelKeyGhost + note
                    : "If you expected an effect, the key likely reached a control that ignores it: click the "
                    + "control that should receive it first.\(note)",
                repaint: "A key's effect is often only a moved focus or caret, which the scene cannot attribute: "
                    + "observe before pressing again.\(note)",
                // A typed key has no target; the field's new value is its effect.
                countsValueChange: true,
                ignoresTextRereads: true,
                movesFocus: chord.key == .tab && chord.modifiers.subtracting(.shift).isEmpty
            )
            // A character typed key by key costs two scene reads each: the text goes in one type_text.
            guard Self.isTypedCharacter(chord), await dependencies.controls?.focusedFieldValue(in: pid) != nil else {
                return outcome
            }
            return outcome.with(message: outcome.message + " " + Self.typeTextNote)
        }
        switch await send(Array(repeating: chord.gesture, count: times), to: pid) {
        case .delivered: break
        case .notSent(let refusal):
            return Self.notSent(refusal, pressed, scene: perceived.scene) ?? ActOutcome(.refused, refusal.sentence)
        case .uncertain(let u):
            return await afterUncertainDelivery(u, in: pid, judge: judge)
        }
        return await judge()
    }

    /// Resolves an attested focus through this capture's identities, never through its labels.
    private static func committingTarget(_ focus: FocusedField, in perceived: PerceivedWindow) -> CommittingInput.Target? {
        switch focus {
        case .secure:
            return nil
        case .ordinary(let identity):
            let matches = perceived.scene.elements.filter { perceived.identities[$0.id] == identity }
            return matches.count == 1 ? matches.first.map(CommittingInput.Target.field) : .unidentified
        case .unknown:
            return .unidentified
        }
    }

    private func committingRefusal(
        _ input: InputRequest.Input,
        into target: CommittingInput.Target,
        scene: SceneSnapshot
    ) -> ActOutcome? {
        guard CommittingInput.commits(input, into: target,
                  onCorrespondenceSurface: dependencies.correspondence?(scene.bundleID) ?? false)
        else { return nil }
        switch IrreversiblePolicy.decision(allowed: permissions.allowsDestructive, readBack: .cannotConfirm) {
        case .allowed: return nil
        case .needsConsent:
            return ActOutcome(.refused, OutcomeText.committingInputConsentRefusal,
                              scene: scene, notSent: .needsConsent)
        case .cannotReadBack:
            return ActOutcome(.refused, OutcomeText.committingInputReadBackRefusal,
                              scene: scene, notSent: .destructiveUnverifiable)
        }
    }

    /// Said after a plain character key pressed while a field has the focus.
    static let typeTextNote = "press_key is one keystroke, not for text: enter text with one type_text call "
        + "on the field, which clicks it and types it all at once."

    /// A letter, a digit, `/`, `~` or space, alone or with Shift: what a person types, not a shortcut.
    private static func isTypedCharacter(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.subtracting(.shift).isEmpty else { return false }
        return switch chord.key {
            case .character, .space                        : true
            case .return, .tab, .escape, .delete,
                 .left, .right, .up, .down                 : false
        }
    }

    /// Raises the application when a foreground gesture needs it, by the activation policy.
    func raiseIfNeeded(_ processID: pid_t, isPopupOpen: Bool) async {
        guard let activation = dependencies.activation else { return }
        let frontmost = await activation.frontmostProcessID()
        if ActivationPolicy.needsActivation(target: processID, frontmost: frontmost, isPopupOpen: isPopupOpen) {
            await activation.activate(processID)
            await pause(timing.activateSettle)
        }
    }

    /// Closes the gestures delivered with what the engine saw, in step with the verdict: after a wait that did not
    /// settle, the historical arm preserves direct read-back alone and the new arm preserves any seen effect.
    /// An actuator that keeps receipts follows the same qualification as the outcome.
    func confirm(_ effect: DeliveryEffect, direct: Bool = false, in processID: pid_t) async {
        guard !VerdictTrace.rejudgeStopped, Self.uncertainDelivery == nil,
              !(VerdictTrace.isRejudging && VerdictTrace.current?.deliveryIsUncertain == true) else { return }
        var effect = effect
        let preservesSeen = direct || OperationCheck.engineVersion == "engine-oracle-2"
        if let ended = Self.settleTrail?.last, ended != .settled, !(effect == .observed && preservesSeen) {
            effect = .unknown
        }
        await dependencies.actuator.confirm(effect, in: processID)
    }

    /// Delivers gestures in order and classifies the result, without retrying partial delivery.
    /// A failure closes the delivery as unknown: what went out before it is never repeated.
    /// A `redundantAfterAccessibilityClick` gesture right after a click that went through accessibility
    /// is not delivered: that click left its caret where the gesture would have moved it.
    /// `afterTheClick` is asked before every gesture that follows the first, a click: before each key that
    /// prepares the field and again right before the text. A reason stops the input there, as `TextStopped`,
    /// with what went out before it standing. The first gesture is aimed at the element so named, when there is
    /// one: a left click `expecting` it, so an actuator that acts through the element may refuse another one and
    /// bind the input to its surface, and any other pointer gesture `over` it, so one that sees what lies under its
    /// point may refuse it before any event.
    func send(
        _ gestures: [Gesture],
        to processID: pid_t,
        over label: String? = nil,
        redundantAfterAccessibilityClick redundant: Gesture? = nil,
        afterTheClick gate: (@Sendable () async -> String?)? = nil
    ) async -> DeliveryResult {
        var sent = 0
        do {
            // One reference before the first gesture: any effect of the whole input then counts.
            if !gestures.isEmpty { await dependencies.settling?.prepare(in: processID) }
            for (index, gesture) in gestures.enumerated() {
                if gesture == redundant, index > 0, case .click = gestures[index - 1],
                   await dependencies.actuator.lastDeliveryRoute(in: processID) == .accessibility {
                    continue
                }
                if let gate, index > 0, let reason = await gate() {
                    throw TextStopped(reason: reason, sentBefore: sent)
                }
                if index == 0, case .click(_, .left, _) = gesture, let label {
                    try await post(gesture, aim: .expecting(label), in: processID)
                } else if index == 0, let label {
                    try await post(gesture, aim: .over(label), in: processID)
                } else {
                    try await post(gesture, in: processID)
                }
                sent += 1
            }
            return .delivered
        } catch {
            await confirm(.unknown, in: processID)
            return Self.delivery(after: error, sent: sent)
        }
    }

    /// An input stopped after its click and before its text, for `reason`, after `sentBefore` gestures went out
    /// (the click and the preparation keys before it): a partial delivery, never retried.
    struct TextStopped: Error, CustomStringConvertible {
        let reason    : String
        let sentBefore: Int
        var description: String { reason }
    }

    /// InputTrail is what one input's handling perceived, in order, and the effect it attributed: the
    /// facts `deliver` reports to the observer once the outcome is decided. It changes no decision.
    final class InputTrail: @unchecked Sendable {
        private let lock = NSLock()
        private var perceived: [PerceivedWindow] = []
        private var attributed: SceneEffect?
        private var failure: String?

        var deliveryFailure: String? { lock.withLock { failure } }
        func failed(_ detail: String) { lock.withLock { failure = detail } }
        private var resolvedTarget: SceneElement?

        var windows: [PerceivedWindow] { lock.withLock { perceived } }
        var effect: SceneEffect? { lock.withLock { attributed } }
        var target: SceneElement? { lock.withLock { resolvedTarget } }

        func append(_ window: PerceivedWindow) { lock.withLock { perceived.append(window) } }
        func attribute(_ effect: SceneEffect?) { lock.withLock { attributed = effect } }
        /// The element the input acted on: the field, the scrolled element, the dragged source, the opener.
        func resolve(_ element: SceneElement?) {
            lock.withLock { if resolvedTarget == nil { resolvedTarget = element } }
        }
    }

    /// The trail of the input being delivered in this task, when one is.
    @TaskLocal static var inputTrail: InputTrail?
}

/// The record of a failed delivery keeps the producer's words and whether any gesture went out.
extension DeliveryResult {
    var attempt: ActionAttempt {
        switch self {
        case .delivered: .delivered
        case .notSent(let refusal): .notAttempted(reason: refusal.reason)
        case .uncertain(let uncertain): .deliveryFailed(uncertain.detail)
        }
    }
}
