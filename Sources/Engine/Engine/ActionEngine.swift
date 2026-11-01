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
            countsNativeTextChange: Bool = false
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
        }
    }

    let dependencies: Dependencies
    let permissions: ActionPermissions
    let timing: ActionTiming
    let pause: @Sendable (Duration) async -> Void

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
    func refusal(destructive what: String, scene: SceneSnapshot?, needsConsent: String) -> ActOutcome? {
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
                   + "looks destructive/irreversible: refused. If you want the agent to do this, the person must allow "
                   + "destructive actions.") {
                return refused
            }
        }
        if request.verb == .rightClick,
           let refusal = menuOutsideTheSeat(on: element, appName: request.appName, scene: scene) {
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
        let censusBefore = await surfaces(pid).verdicts
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
            await dependencies.actuator.confirm(.unknown, in: pid)
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: request.verb, effect: nil, windowTitleAfter: nil,
                before: perceived
            ))
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
    func recordPick(
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

    func scroll(
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

    func drag(
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
                       + "refused. If you want the agent to do this, the person must allow destructive actions.") {
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
    func chooseInContextMenu(
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
               + "destructive/irreversible: refused. If you want the agent to do this, the person must allow "
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

}
