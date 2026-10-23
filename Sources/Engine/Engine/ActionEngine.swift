//
//  ActionEngine.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif

/// ActionEngine performs one action the honest way: perceive this instant, resolve the target by
/// name, refuse what policy refuses, deliver the gesture through a role, perceive again, and judge
/// the effect by what changed structurally. Every dependency arrives at construction; nothing here
/// reads a clock, a path or an environment.
///
/// A pop-up is a window of its own. A target inside an open pop-up is chosen with the keyboard from a
/// plan over the scene's rows, never by a coordinate; a target outside one closes the pop-up first and
/// says so. A closed dropdown is opened by its own press action when the application exposes one, so a
/// painted caret is never the click target.
public struct ActionEngine: Sendable {

    /// What the engine has not been given decides what it can do: no activation role means no raising
    /// (a background seat), no control role means coordinates and type-ahead only.
    public struct Dependencies: Sendable {
        public var scenes: any SceneProviding
        public var actuator: any Actuating
        public var windows: any WindowListing
        public var controls: (any ControlPressing)?
        public var activation: (any ApplicationActivating)?
        public var expectations: (any EffectExpecting)?
        public var observer: (any ActionObserving)?
        /// Ends the wait after a gesture once the window settled; nil sleeps the fixed pause.
        public var settling: (any Settling)?
        /// Carries out a text format toggle through its menu item; nil clicks the toggle.
        public var menus: (any MenuCommanding)?
        /// Whether a static text whose native value changed counts as an effect
        /// (`SceneDifference.effect`): true only for scenes whose texts show the app's state, as the
        /// MacDriver's do; false for the Seat's, whose texts include clocks and timecodes.
        public var countsNativeTextChange: Bool
        /// Whether a process is still alive: what tells a window closed by a click from an application that went
        /// away with it. The default asks the system; a test states it.
        public var isRunning: @Sendable (pid_t) -> Bool

        public init(
            scenes      : any SceneProviding,
            actuator    : any Actuating,
            windows     : any WindowListing,
            controls    : (any ControlPressing)? = nil,
            activation  : (any ApplicationActivating)? = nil,
            expectations: (any EffectExpecting)? = nil,
            observer    : (any ActionObserving)? = nil,
            settling    : (any Settling)? = nil,
            menus       : (any MenuCommanding)? = nil,
            countsNativeTextChange: Bool = false,
            isRunning   : @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
        ) {
            self.scenes       = scenes
            self.actuator     = actuator
            self.windows      = windows
            self.controls     = controls
            self.activation   = activation
            self.expectations = expectations
            self.observer     = observer
            self.settling     = settling
            self.menus        = menus
            self.countsNativeTextChange = countsNativeTextChange
            self.isRunning    = isRunning
        }
    }

    private let dependencies: Dependencies
    private let permissions: ActionPermissions
    private let timing: ActionTiming
    private let pause: @Sendable (Duration) async -> Void

    /// Creates an engine. `pause` is how it waits; the default sleeps, a test does not.
    public init(
        _ dependencies: Dependencies,
        permissions   : ActionPermissions = ActionPermissions(),
        timing        : ActionTiming = .standard,
        pause         : @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dependencies = dependencies
        self.permissions  = permissions
        self.timing       = timing
        #if BRAUS_PHASES
        self.pause = { duration in
            let phase = PhaseInterval.begin("pause")
            defer { phase.end() }
            await pause(duration)
        }
        #else
        self.pause        = pause
        #endif
    }

    /// The refusal of a destructive or irreversible step (`IrreversiblePolicy`): without the person's consent,
    /// `needsConsent`; with it, the shared refusal, since no route the engine drives has a verifier of such a step's
    /// own effect. A scene or a page read again is not one: a send can close its dialog and save a draft on the web
    /// too, and the engine judges a gesture by generic differences. Never nil today.
    private func refusal(destructive what: String, scene: SceneSnapshot?, needsConsent: String) -> ActOutcome? {
        switch IrreversiblePolicy.decision(allowed: permissions.allowsDestructive, readBack: .cannotConfirm) {
            case .allowed:        nil
            case .needsConsent:   ActOutcome(.refused, needsConsent, scene: scene)
            case .cannotReadBack: ActOutcome(.refused, IrreversiblePolicy.readBackRefusal(what), scene: scene)
        }
    }

    // MARK: Observe

    /// The map a model reads, with the token it echoes back when it acts.
    public func describeScene(of processID: pid_t, appName: String) async -> ActOutcome {
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let text = perceived.scene.mapText() + "\nscene_token: \(perceived.scene.token)"
        return ActOutcome(.foundActed, text, scene: perceived.scene)
    }

    /// One panel's elements, each with its id, so a shared label can be acted on by id.
    public func describeSection(named name: String, of processID: pid_t, appName: String) async -> ActOutcome {
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let scene = perceived.scene
        guard let section = scene.resolveSection(named: name) else {
            return ActOutcome(.honestMiss, "no section '\(name)': sections right now: "
                + scene.sections.map(\.name).joined(separator: " · "), scene: scene)
        }
        let members = scene.elements.filter { $0.section == section.name }
        var out = "Section: \(section.name), \(members.count) elements"
        if let note = section.verticalScrollNote { out += " · \(note)" }
        if let note = section.horizontalScrollNote { out += " · \(note)" }
        out += " (scene_token: \(scene.token))\n"
        for element in members {
            let position = String(format: "%.2f,%.2f", element.bounds.x, element.bounds.y)
            let state = element.state.map { " [\($0.rawValue)]" } ?? ""
            let tag = element.isUnlabeled ? "icon?" : element.kind.rawValue
            let does = element.does.map { ": \($0)" } ?? ""
            out += "  [\(tag)] \(element.label)\(state)\(does)  @ \(position)  id:\(element.id)\n"
        }
        return ActOutcome(.foundActed, out, scene: scene)
    }

    /// Whether the window shows `evidence` right now: a title or a label, matched case-insensitively.
    /// A goal is verified by what is on screen, never by the model's own report of having done it.
    public func checkGoal(evidence: String, of processID: pid_t, appName: String) async -> ActOutcome {
        let needle = evidence.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return ActOutcome(.refused, "missing evidence") }
        guard let perceived = await perceive(processID) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: appName, processID: processID))
        }
        let scene = perceived.scene
        let haystack = (scene.windowTitle + " " + scene.elements.map(\.label).joined(separator: " ")).lowercased()
        guard haystack.contains(needle.lowercased()) else {
            return ActOutcome(.refused, "NOT verifiably done: \(appName)'s screen does not show “\(needle)”. "
                + "Keep working, or check with a string that IS visible (window title or an exact label from the "
                    + "scene).",
                scene: scene)
        }
        return ActOutcome(.foundActed, "verified on screen (“\(needle)”)", scene: scene)
    }

    // MARK: Act

    /// Performs one request and answers with an outcome a model can act on next, with the check its
    /// path made (`OperationCheck`): an outcome no gesture produced says so.
    public func act(_ request: ActionRequest) async -> ActOutcome {
        let settles = SettleTrail()
        let outcome = await Self.$settleTrail.withValue(settles) { await performAct(request) }
        return Self.checked(Self.qualified(outcome, after: settles.last, readBackFromScene: settles.readBackFromScene,
                                           cap: timing.clickSettle))
    }

    /// The check of an outcome whose path stated none (`ActOutcome.withStatedCheck`).
    static func checked(_ outcome: ActOutcome) -> ActOutcome {
        outcome.withStatedCheck
    }

    private func performAct(_ request: ActionRequest) async -> ActOutcome {
        let pid = request.processID
        guard let perceived = await perceive(pid) else {
            return ActOutcome(.honestMiss, await noSceneReason(appName: request.appName, processID: pid))
        }
        let scene = perceived.scene
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(
                request.target, section: request.section, in: scene, appName: request.appName,
                preferStateful: request.verb == .setToggle,
                preferNativeControls: [.click, .doubleClick, .tripleClick, .rightClick].contains(request.verb),
                preferTextEntry: request.verb == .tripleClick
            )
        } catch {
            return error.outcome
        }
        let point = perceived.globalPoint(of: element)
        let surfaces = await surfaces(pid)
        let containingPopup = surfaces.popups.first { $0.insetBy(dx: -4, dy: -4).contains(point) }
        // The operation is classified with its context first; consent and read-back apply afterwards.
        if ActionPolicy.isDestructive(
            label: element.label, bundleID: request.bundleID, role: element.role, container: element.container
        ) {
            // A native routing menu supplies context even when its opener is hidden by the popup.
            // The same words in text, another application or another menu keep the normal refusal.
            var audioRemoval = false
            if request.bundleID == "com.avid.ProTools", request.verb == .click,
               LabelText.menuTitleKey(element.label) == "no send", let popup = containingPopup,
               let navigation = await dependencies.controls?.menuItemNavigation(
                   titled: element.label, within: popup, in: pid
               ) {
                audioRemoval = navigation.hasMatchingItem && navigation.isAudioSendMenu && !navigation.hasSubmenu
            }
            if !audioRemoval,
               let refused = refusal(destructive: "'\(element.label)'", scene: scene, needsConsent: "'\(element.label)' "
                   + "looks destructive/irreversible: refused, not authorized in this session. If you want the agent to do this, the person must allow "
                   + "destructive actions.") {
                return refused
            }
        }
        if request.verb == .rightClick,
           let refusal = menuOutsideTheSeat(
               on: element, appName: request.appName, scene: scene, suggestsContextMenu: true
           ) {
            return refusal
        }
        if request.verb != .rightClick, permissions.refusesMenuOpeningClicks,
           let role = element.role, ActionPolicy.menuOpeningRoles.contains(role) {
            return ActOutcome(.refused, ActionPolicy.menuOpeningRefusal(role: role), scene: scene)
        }
        let closure = permissions.windowClosure
        if closure.mayEndTheApplication,
           ActionPolicy.isWindowClosingLabel(element.label) || closure.controlFrames.contains(where: {
               $0.insetBy(dx: -2, dy: -2).contains(point)
           }),
           let refusal = windowClosureRefusal(
               "Clicking '\(element.label)'", appName: request.appName, scene: scene,
               hasOpenPopup: surfaces.hasOpenPopup
           ) {
            return refusal
        }
        let expected = await dependencies.expectations?.expectedEffect(
            of: request.verb, on: element, in: perceived
        )

        if request.verb == .setToggle {
            return await setToggle(request, element: element, at: point, perceived: perceived, expected: expected)
        }
        if request.verb == .click, !surfaces.hasOpenPopup,
           let applied = await formatThroughMenu(request, element: element, perceived: perceived) {
            return applied
        }
        if request.verb == .click, let popup = containingPopup {
            return await pickInPopup(request, element: element, popupFrame: popup, perceived: perceived)
        }
        if request.verb == .click, surfaces.hasOpenPopup {
            // Clicking through an open menu hits the menu; dismiss it first and say so.
            if request.isDryRun {
                return ActOutcome(.dryRun, "a pop-up is open and '\(element.label)' is not one of its items: would "
                    + "Escape it first")
            }
            var escaped = true
            do { try await dependencies.actuator.perform(.key(code: Key.escape), in: pid) } catch { escaped = false }
            await pause(timing.popupDismiss)
            let afterWindow = await perceive(pid)
            let after = afterWindow?.scene
            let dismissed = (try? await dependencies.windows.windows(ownedBy: pid)).map {
                !WindowSurfaceClassifier.classify($0).hasOpenPopup
            } ?? false
            await confirm(dismissed ? .observed : .unknown, in: pid)
            // The requested click never went out: what is checked is the recovery's own effect, and only that.
            let recovery = OperationCheck(
                condition: .recoveryInsteadOfRequest, method: .windowCensus, verdict: dismissed ? .passed : .unknown,
                expected: "pop-up closed", observed: dismissed ? "pop-up closed" : nil,
                limits: escaped ? [] : [.deliveryUncertain], performed: escaped ? .substitute : .uncertain,
                substitute: escaped ? "escape" : nil, target: OperationCheck.Target(element)
            )
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: request.verb, effect: nil,
                windowTitleAfter: after?.windowTitle, before: perceived, after: afterWindow,
                attempt: .notAttempted(reason: "recovery_instead_of_request")
            ))
            guard dismissed else {
                return ActOutcome(.actedUnverified,
                    "could not confirm the pop-up menu's closure after Escape; it may be still open. "
                        + "'\(element.label)' was not clicked. Observe before deciding what to do next.",
                    scene: after, check: recovery)
            }
            return ActOutcome(.actedNoop, "a pop-up menu was open and '\(element.label)' is NOT one of its items: "
                + "closed the menu instead of clicking through it. The scene below is current; act '\(element.label)' "
                    + "again now.",
                scene: after, check: recovery)
        }
        return await clickVerified(
            request, element: element, at: point, perceived: perceived, surfacesBefore: surfaces, expected: expected
        )
    }

    // MARK: Deliver

    /// Delivers one input beyond a click and answers with an outcome a model can act on next: every
    /// target resolved like `act`'s, the gestures through the actuator, the effect judged by perceiving
    /// again. Only a seen effect is `found_acted`.
    public func deliver(_ request: InputRequest) async -> ActOutcome {
        let trail = InputTrail()
        let settles = SettleTrail()
        let delivered = await Self.$inputTrail.withValue(trail) {
            await Self.$settleTrail.withValue(settles) { await self.deliverInput(request) }
        }
        let outcome = Self.checked(Self.qualified(delivered, after: settles.last, readBackFromScene: settles.readBackFromScene,
                                                  cap: timing.clickSettle))
        guard let observer = dependencies.observer else { return outcome }
        let windows = trail.windows
        var isMenuChoice = false
        if case .contextMenu = request.input { isMenuChoice = true }
        let attempt: ActionAttempt = switch (outcome.kind, outcome.check?.performed) {
            case (.dryRun, _), (.refused, _), (.honestMiss, .none?), (.ambiguous, _):
                .notAttempted(reason: outcome.kind.rawValue)
            case (_, .uncertain?):
                .deliveryFailed(outcome.message)
            default:
                .delivered
        }
        await observer.record(InputRecord(
            bundleID: request.bundleID,
            input   : request.input,
            target  : trail.target,
            before  : windows.first,
            menu    : isMenuChoice && windows.count >= 3 ? windows[1] : nil,
            after   : windows.count >= 2 ? windows.last : nil,
            effect  : trail.effect,
            attempt : attempt
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

    // MARK: The three ways to act

    private func clickVerified(
        _ request     : ActionRequest,
        element       : SceneElement,
        at point      : CGPoint,
        perceived     : PerceivedWindow,
        surfacesBefore: WindowSurfaces,
        expected      : SceneEffect?
    ) async -> ActOutcome {
        let pid = request.processID
        if request.isDryRun {
            let expectation = expected.map { ": expected effect: \($0.summary)" } ?? ""
            return ActOutcome(.dryRun, "would \(request.verb.rawValue) '\(element.label)' at "
                + "\(Int(point.x)),\(Int(point.y))\(expectation)")
        }
        await raiseIfNeeded(pid, isPopupOpen: surfacesBefore.hasOpenPopup)
        // The census after activation on purpose: raising an application floats its own palettes.
        let windowsBefore = await windowRows(pid)
        let censusBefore = WindowSurfaceClassifier.classify(windowsBefore ?? []).verdicts
        var openedByPress = false
        await dependencies.settling?.prepare(in: pid)
        // In a remote file panel the seat's own route acts on the control instead.
        if request.verb == .click, !permissions.refusesMenuOpeningClicks, let controls = dependencies.controls {
            openedByPress = await controls.pressControl(labelled: element.label, in: pid)
        }
        do {
            switch request.verb {
                case .doubleClick:
                    try await dependencies.actuator.perform(
                        .click(at: point, count: 2), expecting: element.label, in: pid
                    )
                case .tripleClick:
                    try await dependencies.actuator.perform(
                        .click(at: point, count: 3), expecting: element.label, in: pid
                    )
                case .rightClick:
                    try await dependencies.actuator.perform(
                        .click(at: point, button: .right), over: element.label, in: pid
                    )
                default:
                    if !openedByPress {
                        try await dependencies.actuator.perform(.click(at: point), expecting: element.label, in: pid)
                    }
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: request.verb, effect: nil, windowTitleAfter: nil,
                before: perceived, attempt: Self.attempt(after: error)
            ))
            if let refused = Self.notSent(error, "\(request.verb.performed) '\(element.label)'", scene: perceived.scene) {
                return refused
            }
            return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)': delivery failed: "
                + "\(error)", scene: nil, check: OperationCheck(
                    condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                    limits: [.deliveryUncertain], performed: .uncertain, target: OperationCheck.Target(element)))
        }
        // A press through accessibility is never also clicked, so a reply that found no effect says so.
        let through = await dependencies.actuator.lastDeliveryRoute(in: pid) == .accessibility
            ? " through accessibility, no click posted" : ""
        await settle(pid)
        guard let afterWindow = await perceive(pid) else {
            let closed = await clickedWindowClosed(perceived, before: windowsBefore, in: pid)
            await dependencies.actuator.confirm(closed ? .observed : .unknown, in: pid)
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: request.verb, effect: nil, windowTitleAfter: nil,
                before: perceived
            ))
            // A button that closes its window (Don't Save, Cancel, OK) leaves nothing to read: the window list shows it.
            if closed {
                return ActOutcome(
                    .foundActed,
                    "\(request.verb.performed) '\(element.label)'\(through): the window it was clicked in closed and "
                    + "the application is still running; what the click did there is not read, observe the "
                    + "application before deciding on further input",
                    check: Self.windowSetCheck(target: OperationCheck.Target(element)))
            }
            return ActOutcome(
                .actedUnverified,
                "\(request.verb.performed) '\(element.label)'\(through): no scene could be read "
                + "afterwards; observe the window once it is available",
                check: OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                                      limits: [.noAfterScene], performed: .requested,
                                      target: OperationCheck.Target(element)))
        }
        let after = afterWindow.scene
        let surfacesAfter = await surfaces(pid)
        // A capture that says it is not whole compares to nothing (M2): no effect, and no verdict but unknown.
        // A comparable pair is judged within the selected control's scope, never a homonym's.
        let comparable = ActVerification.comparable(before: perceived.capture, after: afterWindow.capture)
        let effect = comparable ? Self.gatedEffect(
            before: perceived.scene, after: after, targetID: element.id, popupIsOpen: surfacesAfter.hasOpenPopup,
            target: element, countsNativeTextChange: dependencies.countsNativeTextChange
        ) : nil
        let verdict = ActVerification.verdict(before: perceived, after: afterWindow, effect: effect, expected: expected)
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : request.verb,
            effect          : effect,
            windowTitleAfter: after.windowTitle,
            before          : perceived,
            after           : afterWindow
        ))
        let elsewhere = ElsewhereGuide.forUnverifiedAct(
            app: request.appName, before: censusBefore, after: surfacesAfter.verdicts
        )
        // A landed effect is observed whether or not it was the expected one; a ghost is verified absence.
        let delivery: DeliveryEffect = switch verdict {
            case .landed        : .observed
            case .ghost         : .absent
            case .unattributable: .unknown
        }
        await confirm(delivery, in: pid)
        // A press through accessibility found its control by label, anywhere in the application.
        let check = OperationCheck.sceneDifference(verdict, expected: expected, target: OperationCheck.Target(element),
                                                   limits: [.windowWide] + (openedByPress ? [.labelMatchOnly] : []))
        switch verdict {
            case .landed(let effect, true):
                if case .stateFlip = effect, let format = ActVerification.formatToggleOutcome(
                    request.verb.performed,
                    label: element.label,
                    after: after,
                    check: check
                ) {
                    return format
                }
                let asExpected = expected == nil ? "" : " (as expected)"
                return ActOutcome(.foundActed, "\(request.verb.performed) '\(element.label)': "
                    + "\(effect.summary)\(asExpected)", scene: after, check: check)
            case .landed(let effect, false):
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)'\(through): expected "
                    + "\(expected?.summary ?? "?") but observed \(effect.summary); re-perceive and re-decide. "
                        + "\(elsewhere.sentence)", scene: after, check: check)
            case .ghost, .unattributable:
                let why = verdict == .ghost
                    ? "this window did NOT change (identical scene)"
                    : !comparable ? Self.notComparable
                    : "the window's pixels changed but nothing structural did: the intended effect "
                        + "is not classified"
                let advice = elsewhere.changed ? "" : " Verify the intended result in a fresh observation "
                    + "before deciding on further input; do not repeat the click solely from this verdict."
                return ActOutcome(.actedUnverified, "\(request.verb.performed) '\(element.label)'\(through): \(why).\(advice) "
                    + "\(elsewhere.sentence)", scene: after, check: check)
        }
    }

    /// A text format toggle's command carried out through its menu item instead of a click, which in
    /// the background flips only the control: the click is never also sent, and the verdict is the
    /// menu command's own, its check marked as a substitute. Nil sends the click as before: no menu
    /// role, another control, or a menu item missing, disabled or refused, so nothing was dispatched.
    /// A toggle is a control that shows a state: a button, a text or a row named Bold is only clicked.
    private func formatThroughMenu(
        _ request: ActionRequest,
        element  : SceneElement,
        perceived: PerceivedWindow
    ) async -> ActOutcome? {
        guard let menus = dependencies.menus, element.state != nil,
              let path = ActVerification.formatMenuPath(for: element.label)
        else { return nil }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would apply '\(element.label)' through \(path) instead of clicking it, "
                + "or click it if that menu item is missing, disabled or refused")
        }
        // The engine's own perception, so the call records the window after the command.
        let trail  = InputTrail()
        let scenes = dependencies.scenes
        let pid    = request.processID
        guard let outcome = await menus.performMenuItem(path, in: pid, observe: {
            let window = try await scenes.currentScene(of: pid)
            trail.append(window)
            return window.scene
        }) else { return nil }
        let afterWindow = trail.windows.last
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : request.verb,
            effect          : nil,
            windowTitleAfter: afterWindow?.scene.windowTitle,
            before          : perceived,
            after           : afterWindow
        ))
        let check = outcome.check.map { menu in
            OperationCheck(
                condition    : menu.condition,
                method       : menu.method,
                methodVersion: menu.methodVersion,
                verdict      : menu.verdict,
                expected     : menu.expected,
                observed     : menu.observed,
                limits       : menu.limits,
                performed    : menu.performed == .requested ? .substitute : menu.performed,
                substitute   : menu.performed == .requested ? "menu_command" : nil,
                target       : OperationCheck.Target(element)
            )
        }
        // Only a press that went out is said to have applied it; a failed one says it was tried.
        let how = check?.performed == .substitute ? "applied" : "tried"
        return ActOutcome(
            outcome.kind,
            "'\(element.label)' \(how) through \(path), not by clicking the control: \(outcome.message)",
            scene: outcome.scene,
            check: check
        )
    }

    private func setToggle(
        _ request: ActionRequest,
        element  : SceneElement,
        at point : CGPoint,
        perceived: PerceivedWindow,
        expected : SceneEffect?
    ) async -> ActOutcome {
        let pid = request.processID
        guard let desired = request.desiredState, desired == .on || desired == .off else {
            return ActOutcome(.refused, "set_toggle needs a desired state of on or off")
        }
        // A label-only native read cannot establish which repeated control it answered for.
        let mayReadLabel = element.container == nil && element.section == nil
            && perceived.scene.elements.filter { LabelText.normalize($0.label) == LabelText.normalize(element.label) }.count == 1
        let nativeCurrent = mayReadLabel
            ? await dependencies.controls?.toggleState(labelled: element.label, in: pid) : nil
        let current = nativeCurrent ?? element.state
        // A click or its menu substitute only toggles: an indefinite state cannot choose a direction.
        guard current == .on || current == .off else {
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: .setToggle, effect: nil,
                windowTitleAfter: nil, before: perceived,
                attempt: .notAttempted(reason: "initial_toggle_state_not_definite")
            ))
            return ActOutcome(.refused, "cannot set '\(element.label)' \(desired.rawValue): its initial state is "
                + "\(current?.rawValue ?? "unavailable"). Nothing was sent. set_toggle needs an initial on or off state.",
                scene: perceived.scene)
        }
        if current == desired {
            // Already in the requested state: the reading is the check, and no gesture is attributed.
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: .setToggle, effect: nil, windowTitleAfter: nil,
                before: perceived, attempt: .notAttempted(reason: "requested_state_already_present")
            ))
            return ActOutcome(.actedNoop, "'\(element.label)' is already \(desired.rawValue): nothing to "
                + "do", scene: perceived.scene, check: OperationCheck(
                    condition: .requestedStateAlreadyPresent, method: .controlState, verdict: .passed,
                    expected: desired.rawValue, observed: current?.rawValue, performed: .none,
                    target: OperationCheck.Target(element)))
        }
        if let applied = await formatThroughMenu(request, element: element, perceived: perceived) {
            return applied
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click '\(element.label)' to set it \(desired.rawValue)")
        }
        await dependencies.settling?.prepare(in: pid)
        do { try await dependencies.actuator.perform(.click(at: point), expecting: element.label, in: pid) }
        catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: .setToggle, effect: nil, windowTitleAfter: nil,
                before: perceived, attempt: Self.attempt(after: error)
            ))
            if let refused = Self.notSent(error, "set '\(element.label)'", scene: perceived.scene) { return refused }
            return ActOutcome(.actedUnverified, "set '\(element.label)': delivery failed: \(error)",
                              check: OperationCheck(condition: .stateAfterGesture, method: .controlState,
                                                    verdict: .unknown, expected: desired.rawValue,
                                                    limits: [.deliveryUncertain], performed: .uncertain,
                                                    target: OperationCheck.Target(element)))
        }
        await settle(pid)
        let afterWindow = await perceive(pid)
        let after = afterWindow?.scene
        // Only the one control in the selected scope answers for it: a homonym in another container, section or
        // collection never verifies it, and a moved control is not read at its old point.
        let matching = after?.elements.filter {
            $0.kind == element.kind && $0.container == element.container && $0.section == element.section
                && $0.role == element.role && $0.collectionPath == element.collectionPath
                && LabelText.normalize($0.label) == LabelText.normalize(element.label)
        } ?? []
        let selected = matching.count == 1 ? matching[0] : nil
        var answered: ControlState?
        if let selected, selected.bounds == element.bounds {
            answered = await dependencies.controls?.toggleState(at: point, in: pid)
        }
        if answered == nil, mayReadLabel, selected != nil {
            answered = await dependencies.controls?.toggleState(labelled: element.label, in: pid)
        }
        // The control's own state is a direct read-back; the scene's element is the scene.
        if answered == nil { Self.settleTrail?.noteReadBackFromScene() }
        // A partial capture shows what it read, never that nothing else is there: its one match stands for the
        // selected control only at that control's place, so a homonym in the unread part never answers for it.
        let afterIsWhole = afterWindow.map { !ActVerification.refusesComparison($0.capture) } ?? false
        let readBack = answered ?? selected.flatMap { afterIsWhole || $0.bounds == element.bounds ? $0.state : nil }
        // The read-back judges the toggle; the scenes name an effect only when both were read in full (M2).
        let effect = afterWindow.flatMap { window in
            ActVerification.comparable(before: perceived.capture, after: window.capture)
                ? SceneDifference.effect(before: perceived.scene, after: window.scene, targetID: element.id,
                                         target: element,
                                         countsNativeTextChange: dependencies.countsNativeTextChange)
                : nil
        }
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : .setToggle,
            effect          : effect,
            windowTitleAfter: after?.windowTitle,
            before          : perceived,
            after           : afterWindow
        ))
        await confirm(readBack == desired ? .observed : .unknown, direct: answered != nil, in: pid)
        let check = OperationCheck(
            condition: .stateAfterGesture, method: .controlState,
            verdict: readBack == desired ? .passed : readBack == nil ? .unknown : .failed,
            expected: desired.rawValue, observed: readBack?.rawValue,
            limits: (readBack == nil ? [.readbackUnavailable] : []) + (afterWindow == nil ? [.noAfterScene] : []),
            performed: .requested, target: OperationCheck.Target(element)
        )
        switch readBack {
            case desired:
                if let format = ActVerification.formatToggleOutcome(
                    "set",
                    label: element.label,
                    after: after,
                    check: check
                ) {
                    return format
                }
                return ActOutcome(.foundActed, "set '\(element.label)' → \(desired.rawValue)",
                                  scene: after, check: check)
            case .some(let other):
                return ActOutcome(.actedUnverified, "clicked '\(element.label)' but it now reads '\(other.rawValue)' "
                    + "(wanted \(desired.rawValue)): "
                    + "re-perceive and re-decide, don't retry blindly", scene: after, check: check)
            case nil:
                return ActOutcome(.actedUnverified, "clicked '\(element.label)': state unreadable after the click; "
                    + "judge from the scene", scene: after, check: check)
        }
    }

    /// The outcome of a menu choice by its receipt (`MenuItemPress`), nil when the controls did not handle it. An
    /// applied choice is judged by what was read back after settling, never by the menu's closing, which a list
    /// Braus draws does by itself; only a conformer that reads nothing back is judged by the census, as before.
    /// Nothing is chosen again after anything went out.
    private func judged(
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

    private func pickInPopup(
        _ request  : ActionRequest,
        element    : SceneElement,
        popupFrame : CGRect,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        // A readable native menu is navigated first: an item it cannot match uniquely sends nothing, and one with a
        // submenu opens it in observed steps.
        if let navigation = await dependencies.controls?.menuItemNavigation(
            titled: element.label, within: popupFrame, in: pid
        ) {
            guard navigation.hasMatchingItem else {
                return ActOutcome(.honestMiss, "'\(element.label)' does not uniquely match an enabled item in the "
                    + "native menu; no input was sent. Observe the menu again.", scene: perceived.scene)
            }
            if navigation.hasSubmenu {
                return await openSubmenu(request, element: element, popupFrame: popupFrame,
                                         navigation: navigation, perceived: perceived)
            }
        }
        // A menu the controls know is chosen through them, by the element the scene showed; keys pick only when
        // they do not handle it, never after anything was sent or refused.
        if !request.isDryRun, let controls = dependencies.controls,
           let outcome = await judged(await controls.chooseMenuItem(element, within: popupFrame, in: pid),
                                      request, element: element, perceived: perceived) {
            return outcome
        }
        let rows = PopupRowPick.rows(in: perceived.scene, windowFrame: perceived.frame, popupFrame: popupFrame)
        let labels = Set(rows.flatMap { $0.map { LabelText.normalize($0.label) } }.filter { !$0.isEmpty })
        let current = await dependencies.controls?.controlValue(matchingAny: labels, in: pid)
        if let current, let plan = PopupRowPick.plan(rows: rows, currentValue: current, target: element) {
            if request.isDryRun {
                return ActOutcome(.dryRun, "would pick '\(element.label)' in the open pop-up by keyboard "
                    + "(\(plan.route)): "
                    + "row \(plan.targetIndex + 1) of \(plan.rowLabels.count), the highlight starting on '\(current)'")
            }
            do {
                for _ in 0..<abs(plan.delta) {
                    let arrow = plan.delta > 0 ? Key.downArrow : Key.upArrow
                    try await dependencies.actuator.perform(.key(code: arrow), in: pid)
                    await pause(timing.popupArrow)
                }
                try await dependencies.actuator.perform(.key(code: Key.return), in: pid)
            } catch {
                await dependencies.actuator.confirm(.unknown, in: pid)
                await recordPick(request, element: element, before: perceived, after: nil,
                                 attempt: .deliveryFailed("\(error)"))
                return ActOutcome(.actedUnverified, "picking '\(element.label)': delivery failed: \(error)",
                                  check: OperationCheck(condition: .valueReadBack, method: .controlValue,
                                                        verdict: .unknown, expected: element.label,
                                                        limits: [.deliveryUncertain], performed: .uncertain,
                                                        target: OperationCheck.Target(element)))
            }
            await pause(timing.popupCommit)
            let stillOpen = await surfaces(pid).hasOpenPopup
            let value = await dependencies.controls?.controlValue(matchingAny: labels, in: pid)
            let afterWindow = await perceive(pid)
            let after = afterWindow?.scene
            let picked = value.map { LabelText.normalize($0) == LabelText.normalize(element.label) } ?? false
            await confirm(picked ? .observed : .unknown, direct: true, in: pid)
            await recordPick(request, element: element, before: perceived, after: afterWindow)
            let check = OperationCheck(
                condition: .valueReadBack, method: .controlValue,
                verdict: picked ? .passed : value == nil ? .unknown : .failed,
                expected: element.label, observed: value, limits: value == nil ? [.readbackUnavailable] : [],
                performed: .requested, target: OperationCheck.Target(element)
            )
            if let value, LabelText.normalize(value) == LabelText.normalize(element.label) {
                return ActOutcome(.foundActed, "selected '\(element.label)' in the pop-up (keyboard \(plan.route); the "
                    + "control now reads '\(value)')", scene: after, check: check)
            }
            if stillOpen {
                return ActOutcome(.actedUnverified, "moved the pop-up highlight (\(plan.route)) but the list is still "
                    + "open and the control "
                    + "reads '\(value ?? "?")': describe_scene and act the exact row.", scene: after, check: check)
            }
            return ActOutcome(.actedUnverified, "the pop-up closed but the control reads "
                + "'\(value ?? "?")', not '\(element.label)': "
                + "re-open it and re-decide.", scene: after, check: check)
        }
        // No control to read the highlight from: the menu's own type-ahead, first word only.
        let typed = PopupRowPick.typeAheadPrefix(for: element.label)
        guard !typed.isEmpty else {
            return ActOutcome(.honestMiss, "'\(element.label)' has no typeable name for pop-up selection: "
                + "describe_scene and target a named row.")
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would type '\(typed)' into the open pop-up, probe for a submenu with →, then "
                + "Return")
        }
        let popupsBefore = (await surfaces(pid)).popups.count
        do {
            try await dependencies.actuator.perform(.type(typed), in: pid)
            await pause(timing.popupType)
            // A submenu parent selects nothing on Return; the right arrow enters one and is harmless otherwise.
            try await dependencies.actuator.perform(.key(code: Key.rightArrow), in: pid)
            await pause(timing.popupArrow)
            if (await surfaces(pid)).popups.count > popupsBefore {
                let afterWindow = await perceive(pid)
                await confirm(.observed, in: pid)
                await recordPick(request, element: element, before: perceived, after: afterWindow)
                return ActOutcome(.foundActed, "'\(element.label)' opened a SUBMENU: its items are in the scene "
                    + "below; act the one you want next.", scene: afterWindow?.scene, check: OperationCheck(
                        condition: .submenuOpened, method: .windowCensus, verdict: .passed, expected: "submenu opened",
                        observed: "submenu opened", performed: .requested, target: OperationCheck.Target(element)))
            }
            // Commit only while the list is still open: a Return after it closed would hit the dialog behind it.
            if (await surfaces(pid)).hasOpenPopup {
                try await dependencies.actuator.perform(.key(code: Key.return), in: pid)
                await pause(timing.popupCommit)
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            await recordPick(request, element: element, before: perceived, after: nil,
                             attempt: .deliveryFailed("\(error)"))
            return ActOutcome(.actedUnverified, "typing '\(typed)': delivery failed: \(error)", check: OperationCheck(
                condition: .menuClosedAfterChoice, method: .windowCensus, verdict: .unknown,
                limits: [.deliveryUncertain, .commandEffectUnchecked], performed: .uncertain,
                target: OperationCheck.Target(element)))
        }
        let afterWindow = await perceive(pid)
        let after = afterWindow?.scene
        let stillOpen = (await surfaces(pid)).hasOpenPopup
        // A menu closing after typed keys proves the closing, not the item: Finder's Compress did nothing.
        await dependencies.actuator.confirm(.unknown, in: pid)
        await recordPick(request, element: element, before: perceived, after: afterWindow)
        let check = OperationCheck(
            condition: .menuClosedAfterChoice, method: .windowCensus, verdict: stillOpen ? .failed : .unknown,
            expected: "the row chosen", observed: stillOpen ? "menu open" : "menu closed",
            limits: [.commandEffectUnchecked], performed: .requested, target: OperationCheck.Target(element)
        )
        if stillOpen {
            return ActOutcome(.actedUnverified, "typed '\(typed)' but a pop-up is still open: that prefix may not "
                + "match a row; "
                + "describe_scene to read the exact item labels, then act the precise one.", scene: after, check: check)
        }
        return ActOutcome(.actedUnverified, "typed '\(typed)' to choose '\(element.label)' in the pop-up (keyboard "
            + "type-ahead): the menu closed but the effect is not confirmed; observe before acting again.",
            scene: after, check: check)
    }

    /// A parent row opens another menu; pressing its AX action can close the whole menu in Pro Tools.
    /// Navigate from the top without Return, then verify that this parent's own child is a new popup.
    private func openSubmenu(
        _ request: ActionRequest,
        element: SceneElement,
        popupFrame: CGRect,
        navigation: MenuItemNavigation,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        let before = await surfaces(pid).popups
        if let child = navigation.submenuFrame, child != popupFrame, before.contains(child) {
            return ActOutcome(.actedNoop, "the submenu '\(element.label)' is already open", scene: perceived.scene)
        }
        guard let row = navigation.row, (0..<64).contains(row) else {
            return ActOutcome(.honestMiss, "the submenu's row order is unreadable; no input was sent", scene: perceived.scene)
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would open the submenu '\(element.label)' without choosing an item")
        }
        var sent = false
        do {
            try await dependencies.actuator.perform(.key(code: Key.home), in: pid)
            sent = true
            for _ in 0..<row {
                try await dependencies.actuator.perform(.key(code: Key.downArrow), in: pid)
                await pause(timing.popupArrow)
            }
            try await dependencies.actuator.perform(.key(code: Key.rightArrow), in: pid)
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            await recordPick(request, element: element, before: perceived, after: nil,
                             attempt: sent ? .deliveryFailed("\(error)") : Self.attempt(after: error))
            if !sent, let refused = Self.notSent(error, "opening submenu '\(element.label)'", scene: perceived.scene) {
                return refused
            }
            return ActOutcome(.actedUnverified, "opening submenu '\(element.label)': delivery failed: \(error)")
        }
        await pause(timing.popupCommit)
        let afterPopups = await surfaces(pid).popups
        let child = await dependencies.controls?.menuItemNavigation(
            titled: element.label, within: popupFrame, in: pid
        )?.submenuFrame
        let opened = child.map { afterPopups.contains(popupFrame) && afterPopups.contains($0) && !before.contains($0) }
            ?? false
        let after = await perceive(pid)
        await dependencies.actuator.confirm(opened ? .observed : .unknown, in: pid)
        await recordPick(request, element: element, before: perceived, after: after)
        return ActOutcome(opened ? .foundActed : .actedUnverified,
                          opened ? "'\(element.label)' opened a SUBMENU: act the item you want next."
                              : "requested submenu '\(element.label)' but no new menu was confirmed; observe before acting again.",
                          scene: after?.scene, check: OperationCheck(
                              condition: .submenuOpened, method: .windowCensus,
                              verdict: opened ? .passed : .unknown, expected: "submenu opened",
                              observed: opened ? "submenu opened" : "no new submenu confirmed",
                              performed: .requested, target: OperationCheck.Target(element)))
    }

    /// Reports a choice in an open pop-up to the observer: the perceptions around it and how far the
    /// gesture got. A choice teaches the Brain nothing (no effect is attributed to the row).
    private func recordPick(
        _ request: ActionRequest,
        element  : SceneElement,
        before   : PerceivedWindow,
        after    : PerceivedWindow?,
        attempt  : ActionAttempt = .delivered
    ) async {
        await dependencies.observer?.record(ActionRecord(
            bundleID: request.bundleID, element: element, verb: request.verb, effect: nil,
            windowTitleAfter: after?.scene.windowTitle, before: before, after: after, attempt: attempt
        ))
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
        if request.isDryRun {
            return ActOutcome(.dryRun, "would insert \(text.count) characters at the current focus and selection")
        }
        let pid = request.processID
        // The focus as its provider attests it, read right before the text: a bound insertion goes only into the field
        // it was classified for, and only a focus attested ordinary is read back or keeps the expected value in the
        // check. A secure field, an unknown focus or no controls role: never read back, the texts kept out.
        let focus = await dependencies.controls?.focusedField(in: pid) ?? .unknown
        if let binding = request.binding, let why = Self.focusMismatch(focus, bound: binding) {
            return ActOutcome(.refused, "inserting text: \(why), not the field this call recorded: nothing was sent. "
                + "Observe, then insert again.")
        }
        var attested = false
        if case .ordinary = focus { attested = true }
        if let error = await send([.insert(text)], to: pid) {
            if let refused = Self.notSent(error, "inserting text") { return refused }
            return ActOutcome(.actedUnverified, "inserting text: delivery failed: \(error); observe before any retry",
                              check: Self.undelivered(expecting == nil ? .none : .valueReadBack, method: .controlValue,
                                                      expected: attested ? expecting : nil))
        }
        await settle(pid)
        if !attested {
            let after = await perceive(pid)?.scene
            await dependencies.actuator.confirm(.unknown, in: pid)
            var isSecure = false
            if case .secure = focus { isSecure = true }
            let check = expecting == nil
                ? OperationCheck(condition: .none, method: .none, verdict: .unknown, limits: [.noExpectedValue],
                                 performed: .requested)
                : OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                                 limits: [.readbackUnavailable, .valueWithheld], performed: .requested)
            return ActOutcome(.actedUnverified, (isSecure ? "inserted text into a secure field: it is never read back"
                : "inserted text at a focus that could not be attested as an ordinary field: it is not read back")
                + ", so the text cannot be confirmed here; observe its effect before further input and never insert "
                + "again blindly", scene: after, check: check)
        }
        let after = await perceive(pid)?.scene
        let value = await dependencies.controls?.focusedFieldValue(in: pid)
        let verified = expecting != nil && value != nil && value == expecting
        await confirm(verified ? .observed : .unknown, direct: true, in: pid)
        // A text the call withholds is judged here but kept out of the check and the answer.
        let withholds = request.withholdsText
        // Without an expected value there is nothing to compare: the insertion stays unknown, never passed.
        let check = expecting == nil
            ? OperationCheck(condition: .none, method: .none, verdict: .unknown, limits: [.noExpectedValue],
                             performed: .requested)
            : OperationCheck(condition: .valueReadBack, method: .controlValue,
                             verdict: verified ? .passed : value == nil ? .unknown : .failed,
                             expected: withholds ? nil : expecting, observed: withholds ? nil : value,
                             limits: (value == nil ? [.readbackUnavailable] : []) + (withholds ? [.valueWithheld] : []),
                             performed: .requested)
        if verified, let value {
            return ActOutcome(.foundActed, withholds ? "inserted text: the focused field reads the expected value"
                              : "inserted text: the focused field reads '\(Self.shortened(value))'", scene: after, check: check)
        }
        return ActOutcome(.actedUnverified,
            "inserted text at the current focus and selection, but the exact resulting value is unconfirmed; "
            + "observe its effect before further input and never insert again blindly", scene: after, check: check)
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
                return ActOutcome(.refused, "'\(element.label)' is not the field this call recorded (\(why)): nothing "
                    + "was typed. Observe, then type again.", scene: perceived.scene)
            }
        }
        let point = perceived.globalPoint(of: element)
        let kept = replacing && permissions.selectsFieldsByTripleClick
            ? Self.keptExtension(of: element.value, replacedBy: text)
            : nil
        let typed   = kept.map { text + "." + $0 } ?? text
        let keeping = kept.map { " (kept the extension .\($0))" } ?? ""
        // Short per-character events lose supplementary Unicode in Qt and renderers. Bulk payloads
        // preserve it and line breaks, without replaying a partially delivered edit.
        let inserts = typed.count > Self.typedTextLimit || typed.unicodeScalars.contains {
            $0.value > 0xFFFF || $0 == "\n" || $0 == "\r"
        }
        if request.isDryRun {
            return ActOutcome(.dryRun, "would click '\(element.label)' at \(Int(point.x)),\(Int(point.y)), "
                + (replacing ? "select what it holds" : "move to its end") + " and "
                + (inserts ? "insert" : "type") + " \(typed.count) characters"
                + (kept.map { ", keeping the extension .\($0)" } ?? ""))
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
        if let error = await send(gestures, to: pid, over: element.label, redundantAfterAccessibilityClick: endOfField,
                                  afterTheClick: focusGate) {
            if let stopped = error as? TextStopped {
                // The click, and any preparation key, went out and may have moved the focus or the selection: a
                // partial delivery, closed as unknown, never replayed.
                let keys = stopped.sentBefore > 1 ? " and pressed \(stopped.sentBefore - 1) of its preparation keys" : ""
                return ActOutcome(.actedUnverified, "clicked '\(element.label)'\(keys), but \(stopped.reason): nothing "
                    + "was typed. Observe before typing again.",
                    check: Self.undelivered(.valueReadBack, method: .controlValue, target: element))
            }
            if let refused = Self.notSent(error, "typing into '\(element.label)'", scene: perceived.scene) { return refused }
            return ActOutcome(.actedUnverified, "typing into '\(element.label)': delivery failed: \(error)",
                              check: Self.undelivered(.valueReadBack, method: .controlValue,
                                                      expected: isSecure || request.withholdsText ? nil : typed,
                                                      target: element))
        }
        await settle(pid)
        let after = await perceive(pid)?.scene
        let composing = inserts ? " This text is inserted as one event; an active input method may reject it." : ""
        if isSecure {
            await dependencies.actuator.confirm(.unknown, in: pid)
            let check = OperationCheck(
                condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                limits: [.readbackUnavailable, .valueWithheld], performed: .requested,
                target: OperationCheck.Target(element)
            )
            return ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping): a secure field is never "
                + "read back, so the text cannot be confirmed here; judge by what follows (the page that "
                + "answers) instead of typing it again.\(composing)", scene: after, check: check)
        }
        let focused = await dependencies.controls?.focusedFieldValue(in: pid)
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
                ? ActOutcome(.foundActed, "typed into '\(element.label)'\(keeping): the field reads the typed text",
                             scene: after, check: check)
                : ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping), but the field's value could not "
                             + "be confirmed as the typed text: observe and re-decide, do not type it again blindly."
                             + composing, scene: after, check: check)
        }
        switch (readBack, wanted) {
            case (.some(let value), .some(let wanted)) where value == wanted:
                return ActOutcome(.foundActed, "typed into '\(element.label)'\(keeping): the field reads "
                    + "'\(Self.shortened(value))'", scene: after, check: check)
            case (.some(let value), .some(let wanted)):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping) but the field reads "
                    + "'\(Self.shortened(value))', not '\(Self.shortened(wanted))': observe and re-decide, do not "
                    + "type it again blindly.\(composing)", scene: after, check: check)
            case (.some(let value), nil):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)' and the field reads "
                    + "'\(Self.shortened(value))', but what it held before could not be read, so the appended text "
                    + "cannot be confirmed: observe and re-decide.", scene: after, check: check)
            case (nil, _):
                return ActOutcome(.actedUnverified, "typed into '\(element.label)'\(keeping): no field's value could be "
                    + "read afterwards, so the text cannot be confirmed; observe before typing again.\(composing)",
                    scene: after, check: check)
        }
    }

    /// The field of the scene after typing that is the one typed into, when its id moved with its value: the
    /// one element of the same role and kind whose centre lies within the field's place before typing, widened by
    /// half a percent of the window. A field named by what it holds ("foto_3 copy.psd" in a save panel whose
    /// accessibility answers no focus, as in PhotoCraft's, 14 October 2026) takes a new id once it holds the typed
    /// name, and while it is edited it may report a smaller frame inside its own (0.153 wide before, 0.090 after,
    /// live); nil for none or several.
    static func sameField(as element: SceneElement, in after: SceneSnapshot) -> SceneElement? {
        let margin = 0.005, place = element.bounds
        let matches = after.elements.filter {
            let x = $0.bounds.x + $0.bounds.width / 2, y = $0.bounds.y + $0.bounds.height / 2
            return $0.role == element.role && $0.kind == element.kind
                && place.x - margin <= x && x <= place.x + place.width + margin
                && place.y - margin <= y && y <= place.y + place.height + margin
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func pressKey(
        _ chord  : KeyChord,
        times    : Int,
        _ request: InputRequest,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        if ActionPolicy.closesTheTarget(chord) {
            return ActOutcome(.refused, "\(chord) quits or closes what this session drives: refused. Use the "
                + "window's own control, or close the session.", scene: perceived.scene)
        }
        if ActionPolicy.isDestructive(chord),
           let refused = refusal(destructive: "\(chord)", scene: perceived.scene, needsConsent: "\(chord) deletes in "
               + "most applications: refused, not authorized in this session. If you want the agent to do this, the person must allow destructive "
               + "actions.") {
            return refused
        }
        if ActionPolicy.dismissesLikeEscape(chord), permissions.windowClosure.mayEndTheApplication, !permissions.allowsDestructive {
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
                + " into \(request.appName)'s window")
        }
        let windowsBefore = await windowRows(pid)
        await raiseIfNeeded(pid, isPopupOpen: WindowSurfaceClassifier.classify(windowsBefore ?? []).hasOpenPopup)
        if let error = await send(Array(repeating: chord.gesture, count: times), to: pid) {
            if let refused = Self.notSent(error, pressed, scene: perceived.scene) { return refused }
            return ActOutcome(.actedUnverified, "\(pressed): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference))
        }
        // A background chord's unchanged scene does not qualify the target's menu support.
        let note = dependencies.activation == nil && chord.modifiers.contains(.command) ? Self.menuShortcutNote : ""
        let outcome = await judged(
            pressed, in: request, before: perceived, targetID: nil,
            // `selectsFieldsByTripleClick` is set exactly while the seat holds a file panel drawn out of process.
            ghost: permissions.selectsFieldsByTripleClick ? Self.filePanelKeyGhost + note
                : "If you expected an effect, the key may have reached a control that ignores it, or the application "
                + "does not take this shortcut in the background: observe the window, and use the menu tool or the "
                + "control's own action instead.\(note)",
            repaint: "A key's effect is often only a moved focus or caret, which the scene cannot attribute: "
                + "observe before pressing again.\(note)",
            // A typed key has no target; the field's new value is its effect.
            countsValueChange: true,
            ignoresTextRereads: true,
            movesFocus: chord.key == .tab && chord.modifiers.subtracting(.shift).isEmpty,
            windowsBefore: windowsBefore,
            ignoresSelfChanges: true
        )
        // A character typed key by key costs two scene reads each: the text goes in one type_text.
        guard Self.isTypedCharacter(chord), await dependencies.controls?.focusedFieldValue(in: pid) != nil else {
            return outcome
        }
        return outcome.with(message: outcome.message + " " + Self.typeTextNote)
    }

    /// Said after a plain character key pressed while a field has the focus.
    static let typeTextNote = "press_key is one keystroke, not for text: enter text with one type_text call "
        + "on the field, which clicks it and types it all at once."

    /// A letter, a digit, a punctuation mark, `/`, `~` or space, alone or with Shift: what a person types, not a
    /// shortcut. A position (a function key, the keypad, Page Down) is a command key even alone.
    private static func isTypedCharacter(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.subtracting(.shift).isEmpty else { return false }
        return switch chord.key {
            case .character, .space                        : true
            case .return, .tab, .escape, .delete,
                 .left, .right, .up, .down, .position      : false
        }
    }

    /// The refusal for an input that would close the only window of the application, or nil when
    /// the window is not that, a pop-up is open (the key then closes it) or the person allowed it.
    /// The alternatives are real buttons of the scene, never a Cancel the window does not have.
    private func windowClosureRefusal(
        _ what      : String,
        appName     : String,
        scene       : SceneSnapshot,
        hasOpenPopup: Bool
    ) -> ActOutcome? {
        guard permissions.windowClosure.mayEndTheApplication, !permissions.allowsDestructive,
              !hasOpenPopup
        else { return nil }
        let alternatives = scene.elements.filter {
            $0.kind == .control && $0.role == "AXButton" && !$0.isUnlabeled && $0.isEnabled != false
                && !ActionPolicy.isWindowClosingLabel($0.label) && !ActionPolicy.isDestructive(label: $0.label)
        }.prefix(3).map(\.label)
        return ActOutcome(
            .refused,
            ActionPolicy.windowClosureRefusal(
                what, window: scene.windowTitle, application: appName, alternatives: alternatives
            ),
            scene: scene
        )
    }

    private func scroll(
        lines      : Int,
        over target: String?,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard lines != 0, abs(lines) <= InputRequest.maximumScrollLines else {
            return ActOutcome(.refused, "a scroll turns 1 to \(InputRequest.maximumScrollLines) lines, up or down")
        }
        var element: SceneElement?
        if let target {
            do throws(Unresolved) {
                element = try resolved(target, section: request.section, in: perceived.scene, appName: request.appName)
            } catch {
                return error.outcome
            }
        }
        Self.inputTrail?.resolve(element)
        let point = element.map(perceived.globalPoint(of:))
            ?? CGPoint(x: perceived.frame.midX, y: perceived.frame.midY)
        let amount = "\(abs(lines)) line\(abs(lines) == 1 ? "" : "s") \(lines > 0 ? "up" : "down") over "
            + (element.map { "'\($0.label)'" } ?? "the window's centre")
        if request.isDryRun {
            return ActOutcome(.dryRun, "would scroll \(amount) at \(Int(point.x)),\(Int(point.y))")
        }
        let scrolled = "scrolled \(amount)"
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send([.scroll(at: point, deltaY: lines)], to: pid, over: element?.label) {
            if let refused = Self.notSent(error, scrolled, scene: perceived.scene) { return refused }
            return ActOutcome(.actedUnverified, "\(scrolled): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference, target: element))
        }
        return await judged(
            scrolled, in: request, before: perceived, targetID: element?.id,
            ghost: "Nothing moved: the view may already be at its end, or nothing under that point scrolls; "
                + "target the scrolling panel itself.",
            repaint: "Observe to see whether other rows came into view."
        )
    }

    private func drag(
        from source: String,
        to end     : InputRequest.DragEnd,
        _ request  : InputRequest,
        perceived  : PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        let scene = perceived.scene
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(source, section: request.section, in: scene, appName: request.appName)
        } catch {
            return error.outcome
        }
        Self.inputTrail?.resolve(element)
        let start = perceived.globalPoint(of: element)
        let finish: CGPoint
        let destination: String
        switch end {
            case .target(let name):
                let other: SceneElement
                do throws(Unresolved) {
                    other = try resolved(name, section: request.section, in: scene, appName: request.appName)
                } catch {
                    return error.outcome
                }
                guard other.id != element.id else {
                    return ActOutcome(.refused, "a drag needs two different targets", scene: scene)
                }
                if ActionPolicy.isDestructive(label: other.label),
                   let refused = refusal(destructive: "Dropping on '\(other.label)'", scene: scene,
                                         needsConsent: "dropping on '\(other.label)' looks destructive/irreversible: "
                       + "refused, not authorized in this session. If you want the agent to do this, the person must allow destructive actions.") {
                    return refused
                }
                finish = perceived.globalPoint(of: other)
                destination = "'\(other.label)'"
            case .offset(let dx, let dy):
                guard dx != 0 || dy != 0 else { return ActOutcome(.refused, "a drag needs a nonzero offset") }
                finish = CGPoint(x: start.x + dx, y: start.y + dy)
                destination = "\(Int(dx)),\(Int(dy)) points away"
        }
        let dragged = "dragged '\(element.label)' to \(destination)"
        if request.isDryRun {
            return ActOutcome(.dryRun, "would drag '\(element.label)' from \(Int(start.x)),\(Int(start.y)) to "
                + "\(destination) at \(Int(finish.x)),\(Int(finish.y))")
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send([.drag(from: start, to: finish)], to: pid, over: element.label) {
            if let refused = Self.notSent(error, dragged, scene: scene) { return refused }
            return ActOutcome(.actedUnverified, "\(dragged): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference, target: element))
        }
        return await judged(
            dragged, in: request, before: perceived, targetID: element.id,
            ghost: "If you expected an effect, the press likely did not pick anything up: try a handle, a row "
                + "or the exact label.",
            repaint: "A drag that only moves things adds, removes and retitles nothing, so it cannot be told "
                + "from a repaint: observe to check where '\(element.label)' is now."
        )
    }

    /// A contextual menu is a pop-up of its own, so the row is chosen by the pop-up path: the keyboard,
    /// never a click through the menu.
    private func chooseInContextMenu(
        _ item   : String,
        on target: String,
        _ request: InputRequest,
        perceived: PerceivedWindow
    ) async -> ActOutcome {
        let pid = request.processID
        guard !LabelText.normalize(item).isEmpty else {
            return ActOutcome(.refused, "context_menu needs the item's title")
        }
        let element: SceneElement
        do throws(Unresolved) {
            element = try resolved(target, section: request.section, in: perceived.scene, appName: request.appName)
        } catch {
            return error.outcome
        }
        Self.inputTrail?.resolve(element)
        // The item is classified with the control that opens its menu; consent and read-back apply afterwards.
        if ActionPolicy.isDestructiveMenuItem(
            item, openedBy: element.label, bundleID: request.bundleID,
            role: element.role, container: element.container
        ),
           let refused = refusal(destructive: "'\(item)'", scene: perceived.scene, needsConsent: "'\(item)' looks "
               + "destructive/irreversible: refused, not authorized in this session. If you want the agent to do this, the person must allow "
               + "destructive actions.") {
            return refused
        }
        if let refusal = menuOutsideTheSeat(on: element, appName: request.appName, scene: perceived.scene) {
            return refusal
        }
        let point = perceived.globalPoint(of: element)
        if request.isDryRun {
            return ActOutcome(.dryRun, "would right-click '\(element.label)' at \(Int(point.x)),\(Int(point.y)) "
                + "and choose '\(item)' in the contextual menu by keyboard")
        }
        let before = await surfaces(pid)
        await raiseIfNeeded(pid, isPopupOpen: before.hasOpenPopup)
        if let error = await send([.click(at: point, button: .right)], to: pid, over: element.label) {
            if let refused = Self.notSent(error, "right-clicking '\(element.label)'", scene: perceived.scene) { return refused }
            return ActOutcome(.actedUnverified, "right-clicking '\(element.label)': delivery failed: \(error)",
                              check: Self.undelivered(.menuItemChosen, method: .windowCensus, expected: item,
                                                      target: element))
        }
        // The fixed pause on purpose: the menu is a window of its own, which the target's frames never show.
        await pause(timing.clickSettle)
        let popups = (await surfaces(pid)).popups
        guard let menu = popups.first(where: { !before.popups.contains($0) }) ?? popups.first,
              let opened = await perceive(pid) else {
            let after = await perceive(pid)?.scene
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "right-clicked '\(element.label)' but no contextual menu could be "
                + "read, so nothing was chosen: observe; this element may have no menu of its own", scene: after,
                check: OperationCheck(condition: .menuItemChosen, method: .windowCensus, verdict: .unknown,
                                      expected: item, limits: [.commandEffectUnchecked], performed: .substitute,
                                      substitute: "right_click", target: OperationCheck.Target(element)))
        }
        let rows = PopupRowPick.rows(in: opened.scene, windowFrame: opened.frame, popupFrame: menu)
        let wanted = LabelText.normalize(item)
        guard let row = rows.joined().first(where: { LabelText.normalize($0.label) == wanted }) else {
            // An item that is not there is never guessed at: the menu is closed instead.
            try? await dependencies.actuator.perform(.key(code: Key.escape), in: pid)
            await pause(timing.popupDismiss)
            let closed = !(await surfaces(pid)).hasOpenPopup
            let after = await perceive(pid)?.scene
            await confirm(closed ? .observed : .unknown, in: pid)
            let offered = rows.compactMap { $0.first?.label }.prefix(14).map { "'\($0)'" }
            return ActOutcome(.honestMiss, "no item '\(item)' in the contextual menu of '\(element.label)'"
                + (offered.isEmpty ? "" : ": it offered \(offered.joined(separator: ", "))")
                + (closed ? "; the menu was closed" : "; the menu may still be open, observe"), scene: after,
                check: OperationCheck(condition: .menuItemChosen, method: .sceneText, verdict: .failed, expected: item,
                                      observed: nil, performed: .substitute, substitute: "right_click_then_escape",
                                      target: OperationCheck.Target(element)))
        }
        let choice = ActionRequest(
            processID: pid, bundleID: request.bundleID, appName: request.appName, target: row.label, verb: .click
        )
        return await pickInPopup(choice, element: row, popupFrame: menu, perceived: opened)
    }

    // MARK: Helpers

    /// The roles whose contextual menu opens where the click landed, in every toolkit measured.
    private static let textFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The role of a field whose value no reader may return: a password field. The MacDriver's scenes and the
    /// web's name it so; it carries no value, and typing into it is never read back.
    static let secureFieldRole = "AXSecureTextField"

    /// The refusal of a right click whose menu would open outside the seat, nil when it may go ahead.
    /// `suggestsContextMenu` is set for a bare right click, whose refusal names `context_menu` on the same element.
    private func menuOutsideTheSeat(
        on element          : SceneElement,
        appName             : String,
        scene               : SceneSnapshot,
        suggestsContextMenu : Bool = false
    ) -> ActOutcome? {
        guard permissions.contextMenusOnTextFieldsOnly, !Self.textFieldRoles.contains(element.role ?? "") else {
            return nil
        }
        return ActOutcome(.refused, "\(appName) opens the contextual menu of '\(element.label)' on the person's own "
            + "screen, outside the seat, so it was not right-clicked: "
            + (suggestsContextMenu ? "to choose an item from its contextual menu, use context_menu on the same element; "
                                   : "")
            + "otherwise use a visible button or control instead. "
            + "A text field's contextual menu still works here.", scene: scene)
    }

    /// The element a target names in this scene, or the outcome that says why there is none: several
    /// share the name, or none has it.
    private func resolved(
        _ target            : String,
        section             : String?,
        in scene            : SceneSnapshot,
        appName             : String,
        preferStateful      : Bool = false,
        preferNativeControls: Bool = false,
        preferTextEntry      : Bool = false
    ) throws(Unresolved) -> SceneElement {
        let resolution = scene.resolve(
            target: target, preferStateful: preferStateful, section: section,
            preferNativeControls: preferNativeControls, preferTextEntry: preferTextEntry
        )
        switch resolution {
            case .found(let found):
                return found
            case .ambiguous(let count):
                throw Unresolved(outcome: ActOutcome(
                    .ambiguous,
                    "\(count) elements labeled '\(target)': choose an exact element ID or section: "
                    + scene.disambiguation(target: target), scene: scene))
            case .none:
                let near = scene.grep(goal: target).prefix(3)
                    .map { "'\($0.element.label)'" + ($0.element.section.map { " (\($0))" } ?? "") }
                throw Unresolved(outcome: ActOutcome(.honestMiss, "no element '\(target)' in \(appName)"
                    + (near.isEmpty ? "" : ": closest on screen: \(near.joined(separator: ", "))"), scene: scene))
        }
    }

    /// Why a target named no element, as the outcome that says so.
    private struct Unresolved: Error {
        let outcome: ActOutcome
    }

    /// Raises the application when a foreground gesture needs it, by the activation policy.
    private func raiseIfNeeded(_ processID: pid_t, isPopupOpen: Bool) async {
        guard let activation = dependencies.activation else { return }
        let frontmost = await activation.frontmostProcessID()
        if ActivationPolicy.needsActivation(target: processID, frontmost: frontmost, isPopupOpen: isPopupOpen) {
            await activation.activate(processID)
            await pause(timing.activateSettle)
        }
    }

    /// Waits for a gesture's effect before it is judged: the settling role's wait, capped at the click
    /// settle, when the composition gave one, and otherwise the click settle itself.
    private func settle(_ processID: pid_t) async {
        guard let settling = dependencies.settling else { return await pause(timing.clickSettle) }
        Self.settleTrail?.note(await settling.settle(in: processID, cap: timing.clickSettle))
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

    /// Closes the gestures delivered with what the engine saw, in step with the verdict: after a wait that did not
    /// settle, only a direct read-back that found the effect is observed, and anything else is unknown (`qualified`),
    /// so an actuator that keeps receipts never keeps one the verdict does not.
    private func confirm(_ effect: DeliveryEffect, direct: Bool = false, in processID: pid_t) async {
        var effect = effect
        if let ended = Self.settleTrail?.last, ended != .settled, !(direct && effect == .observed) { effect = .unknown }
        await dependencies.actuator.confirm(effect, in: processID)
    }

    /// Delivers the gestures in order and answers the error that stopped them, nil when all went out.
    /// A failure closes the delivery as unknown: what went out before it is never repeated.
    /// A `redundantAfterAccessibilityClick` gesture right after a click that went through accessibility
    /// is not delivered: that click left its caret where the gesture would have moved it.
    /// `afterTheClick` is asked before every gesture that follows the first, a click: before each key that
    /// prepares the field and again right before the text. A reason stops the input there, as `TextStopped`,
    /// with what went out before it standing. The first gesture is aimed at the element so named, when there is
    /// one: a left click `expecting` it, so an actuator that acts through the element may refuse another one and
    /// bind the input to its surface, and any other pointer gesture `over` it, so one that sees what lies under its
    /// point may refuse it before any event.
    private func send(
        _ gestures: [Gesture],
        to processID: pid_t,
        over label: String? = nil,
        redundantAfterAccessibilityClick redundant: Gesture? = nil,
        afterTheClick gate: (@Sendable () async -> String?)? = nil
    ) async -> (any Error)? {
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
                    try await dependencies.actuator.perform(gesture, expecting: label, in: processID)
                } else if index == 0, let label {
                    try await dependencies.actuator.perform(gesture, over: label, in: processID)
                } else {
                    try await dependencies.actuator.perform(gesture, in: processID)
                }
                sent += 1
            }
            return nil
        } catch {
            await dependencies.actuator.confirm(.unknown, in: processID)
            if error is TextStopped { return error }
            // A gesture refused unsent after others went out leaves the effect of those others unknown.
            if sent > 0, error is GestureNotSent { return SentBefore(refusal: error) }
            return error
        }
    }

    /// An input stopped after its click and before its text, for `reason`, after `sentBefore` gestures went out
    /// (the click and the preparation keys before it): a partial delivery, never retried.
    struct TextStopped: Error, CustomStringConvertible {
        let reason    : String
        let sentBefore: Int
        var description: String { reason }
    }

    /// A refusal that came after earlier gestures of the same input went out: the input as a whole was sent in
    /// part, so it is a delivery whose effect is unknown, never "nothing was sent".
    private struct SentBefore: Error, CustomStringConvertible {
        let refusal: any Error
        var description: String { "\(refusal)" }
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
    private func judged(
        _ performed       : String,
        in request        : InputRequest,
        before beforeWindow: PerceivedWindow,
        targetID          : String?,
        ghost             : String,
        repaint           : String,
        countsValueChange : Bool = false,
        ignoresTextRereads: Bool = false,
        movesFocus        : Bool = false,
        windowsBefore     : [WindowRow]? = nil,
        ignoresSelfChanges: Bool = false
    ) async -> ActOutcome {
        let pid = request.processID
        await settle(pid)
        let target = Self.inputTrail?.target.map(OperationCheck.Target.init)
        let before = beforeWindow.scene
        let afterWindows = await windowRows(pid)
        // A window that opened is the input's effect, found in the window list whatever the scene shows (Option-I
        // opened a Workspace window and the scene of the first one did not change).
        if windowsBefore != nil, Self.windowAppeared(before: windowsBefore, after: afterWindows) {
            let afterWindow = await perceive(pid)
            await confirm(.observed, in: pid)
            return ActOutcome(.foundActed, "\(performed): a window of the application opened; the key's effect in it "
                + "is not read here, observe the application before deciding on further input",
                scene: afterWindow?.scene, check: Self.windowSetCheck(target: target))
        }
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
            before: before, after: after, targetID: targetID ?? "",
            popupIsOpen: WindowSurfaceClassifier.classify(afterWindows ?? []).hasOpenPopup,
            countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads,
            ignoresSelfChanges: ignoresSelfChanges, countsNativeTextChange: dependencies.countsNativeTextChange
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

    /// The scenes of a key without the parts of a window that change by themselves. The scene does not mark them,
    /// so this is a conservative reading of what it holds: a readout (a counter, a timecode, a position, a level in
    /// dB: digits and no words) whose value moved, an indicator (a level meter, a progress bar), and an element
    /// that stands where another stood, of the same kind, role and size, under another label (an LED or a state word
    /// redrawn in place). A pro-audio window repainted these on Space with nothing pressed (a counter back to zero,
    /// transport LEDs) and the key was credited with revealing elements. Its limit is an under-claim: a field that
    /// really takes a number from a key, or a control relabeled in place by it, reads as unchanged, which stays
    /// unknown and never becomes a false effect. What appears or vanishes elsewhere still counts.
    static func withoutSelfChanges(before: SceneSnapshot, after: SceneSnapshot) -> (SceneSnapshot, SceneSnapshot) {
        let indicatorRoles: Set<String> = ["AXLevelIndicator", "AXProgressIndicator", "AXRelevanceIndicator"]
        func isLive(_ element: SceneElement) -> Bool {
            if indicatorRoles.contains(element.role ?? "") { return true }
            guard element.kind != .icon else { return false }
            return isReadout(element.value ?? element.label)
        }
        func isReadout(_ text: String) -> Bool {
            let normalized = LabelText.normalize(text)
            guard text.contains(where: \.isNumber) else { return false }
            if text.contains(where: \.isLetter) {
                return normalized.hasSuffix("db") && normalized.dropLast(2).allSatisfy { $0.isNumber }
            }
            return true
        }
        func sameSpot(_ first: SceneElement, _ second: SceneElement) -> Bool {
            let (one, two) = (first.bounds.cgRect, second.bounds.cgRect)
            let overlap = one.intersection(two)
            guard !overlap.isNull, one.width * one.height > 0, two.width * two.height > 0 else { return false }
            let shared = overlap.width * overlap.height
            return shared / (one.width * one.height) >= 0.7 && shared / (two.width * two.height) >= 0.7
        }
        func relabeledPairs(_ scene: SceneSnapshot, in other: SceneSnapshot) -> [SceneElement] {
            let labels = Set(other.elements.map { LabelText.normalize($0.label) })
            return scene.elements.filter { element in
                guard element.role != nil, !element.isUnlabeled,
                      !labels.contains(LabelText.normalize(element.label)) else { return false }
                return other.elements.contains {
                    $0.kind == element.kind && $0.role == element.role && sameSpot($0, element)
                        && LabelText.normalize($0.label) != LabelText.normalize(element.label)
                }
            }
        }
        let gone  = relabeledPairs(before, in: after)
        let fresh = relabeledPairs(after, in: before)
        var was = before, now = after
        was.elements.removeAll { isLive($0) || gone.contains($0) }
        now.elements.removeAll { isLive($0) || fresh.contains($0) }
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
    private static func shortened(_ value: String) -> String {
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
        ignoresSelfChanges    : Bool = false,
        countsNativeTextChange: Bool = false
    ) -> SceneEffect? {
        var (was, now) = ignoresTextRereads ? withoutTextRereads(before: before, after: after) : (before, after)
        if ignoresSelfChanges { (was, now) = withoutSelfChanges(before: was, after: now) }
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

    private func perceive(_ processID: pid_t) async -> PerceivedWindow? {
        let window = try? await dependencies.scenes.currentScene(of: processID)
        if let window { Self.inputTrail?.append(window) }
        return window
    }

    /// InputTrail is what one input's handling perceived, in order, and the effect it attributed: the
    /// facts `deliver` reports to the observer once the outcome is decided. It changes no decision.
    final class InputTrail: @unchecked Sendable {
        private let lock = NSLock()
        private var perceived: [PerceivedWindow] = []
        private var attributed: SceneEffect?
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

    /// How the waits of the action performed in this task ended, the last one kept: what was read after it judges.
    final class SettleTrail: @unchecked Sendable {
        private let lock = NSLock()
        private var ended: SettleResult?
        private var fromScene = false

        var last: SettleResult? { lock.withLock { ended } }

        /// Whether the read-back that judged the action came from the scene's element, not from the control.
        var readBackFromScene: Bool { lock.withLock { fromScene } }

        func note(_ result: SettleResult) { lock.withLock { ended = result } }

        func noteReadBackFromScene() { lock.withLock { fromScene = true } }
    }

    /// The trail of the waits of the action being performed in this task, when one is.
    @TaskLocal static var settleTrail: SettleTrail?

    private func surfaces(_ processID: pid_t) async -> WindowSurfaces {
        let rows = (try? await dependencies.windows.windows(ownedBy: processID)) ?? []
        return WindowSurfaceClassifier.classify(rows)
    }

    /// The application's windows as the window server lists them, nil when the list could not be read: an unread
    /// list says nothing about the windows, where an empty one says there are none.
    private func windowRows(_ processID: pid_t) async -> [WindowRow]? {
        try? await dependencies.windows.windows(ownedBy: processID)
    }

    /// What names an ordinary window across two listings: the server's number, else its title, as a listing
    /// that numbers nothing still tells one window from another. Pop-ups, palettes and slivers are no window here.
    private static func windowKeys(_ rows: [WindowRow]) -> Set<String> {
        Set(rows.filter { $0.layer == 0 && $0.frame.width >= 60 }.map { $0.number != 0 ? "n\($0.number)" : "t\($0.title ?? "")" })
    }

    /// Whether the window a click landed in is gone while its process is alive: a closed window, never an
    /// application that quit. The window is the one listed at the scene's frame, else any that was listed before.
    /// False when either listing could not be read or the process is gone, so the verdict stays unknown.
    private func clickedWindowClosed(_ perceived: PerceivedWindow, before: [WindowRow]?, in pid: pid_t) async -> Bool {
        guard let before, let after = await windowRows(pid), dependencies.isRunning(pid) else { return false }
        let remaining = Self.windowKeys(after)
        let key = { (row: WindowRow) in Self.windowKeys([row]) }
        if let clicked = before.first(where: { $0.layer == 0 && $0.frame == perceived.frame }) {
            return !key(clicked).isEmpty && key(clicked).isDisjoint(with: remaining)
        }
        return !Self.windowKeys(before).subtracting(remaining).isEmpty
    }

    /// Whether a window is listed now that was not before: an ordinary one, whatever the scene shows.
    private static func windowAppeared(before: [WindowRow]?, after: [WindowRow]?) -> Bool {
        guard let before, let after else { return false }
        return !windowKeys(after).subtracting(windowKeys(before)).isEmpty
    }

    /// The check of a click or a key that changed the application's windows: the windows compared before and
    /// after, which shows one opening or closing and never what the gesture did in it.
    private static func windowSetCheck(target: OperationCheck.Target?) -> OperationCheck {
        OperationCheck(condition: .windowSetChanged, method: .windowSignature, verdict: .passed,
                       expected: "windows changed", observed: "windows changed", limits: [.commandEffectUnchecked],
                       performed: .requested, target: target)
    }

    private func noSceneReason(appName: String, processID: pid_t) async -> String {
        let rows = (try? await dependencies.windows.windows(ownedBy: processID)) ?? []
        let ordinary = rows.filter { $0.layer == 0 && $0.frame.width >= 60 }
        if ordinary.isEmpty {
            return "no scene: \(appName) has NO window open right now "
                + "(it is running, but there is nothing to show or "
                + "capture). "
                + "Open a document or window in it first, then describe_scene."
        }
        return "no scene: \(appName) has a window but it could not be perceived right now; "
            + "retry, and if this repeats "
            + "check Screen Recording for the process that runs the engine."
    }
}
