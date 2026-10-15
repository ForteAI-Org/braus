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

        public init(
            scenes      : any SceneProviding,
            actuator    : any Actuating,
            windows     : any WindowListing,
            controls    : (any ControlPressing)? = nil,
            activation  : (any ApplicationActivating)? = nil,
            expectations: (any EffectExpecting)? = nil,
            observer    : (any ActionObserving)? = nil,
            settling    : (any Settling)? = nil,
            menus       : (any MenuCommanding)? = nil
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
        Self.checked(await performAct(request))
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
        if ActionPolicy.isDestructive(label: element.label), !permissions.allowsDestructive {
            return ActOutcome(.refused, "'\(element.label)' looks destructive/irreversible: refused. "
                + "If you want the agent to do this, the person must allow destructive actions.", scene: scene)
        }
        if request.verb == .rightClick,
           let refusal = menuOutsideTheSeat(on: element, appName: request.appName, scene: scene) {
            return refusal
        }
        if request.verb != .rightClick, permissions.refusesMenuOpeningClicks,
           let role = element.role, ActionPolicy.menuOpeningRoles.contains(role) {
            return ActOutcome(.refused, ActionPolicy.menuOpeningRefusal(role: role), scene: scene)
        }
        let point = perceived.globalPoint(of: element)
        let surfaces = await surfaces(pid)
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
        let containingPopup = surfaces.popups.first { $0.insetBy(dx: -4, dy: -4).contains(point) }
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
            let dismissed = (try? dependencies.windows.windows(ownedBy: pid)).map {
                !WindowSurfaceClassifier.classify($0).hasOpenPopup
            } ?? false
            await dependencies.actuator.confirm(dismissed ? .observed : .unknown, in: pid)
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
        let outcome = Self.checked(await Self.$inputTrail.withValue(trail) { await self.deliverInput(request) })
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
                case .rightClick : try await dependencies.actuator.perform(.click(at: point, button: .right), in: pid)
                default:
                    if !openedByPress {
                        try await dependencies.actuator.perform(.click(at: point), expecting: element.label, in: pid)
                    }
            }
        } catch {
            await dependencies.actuator.confirm(.unknown, in: pid)
            await dependencies.observer?.record(ActionRecord(
                bundleID: request.bundleID, element: element, verb: request.verb, effect: nil, windowTitleAfter: nil,
                before: perceived, attempt: .deliveryFailed("\(error)")
            ))
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
        let effect = Self.gatedEffect(
            before: perceived.scene, after: after, targetID: element.id, popupIsOpen: surfacesAfter.hasOpenPopup
        )
        let verdict = ActVerification.verdict(before: perceived.scene, after: after, effect: effect, expected: expected)
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
        await dependencies.actuator.confirm(delivery, in: pid)
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
        // A reused scene can be older than the control, so the application's own answer decides first.
        let current = await dependencies.controls?.toggleState(labelled: element.label, in: pid) ?? element.state
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
                before: perceived, attempt: .deliveryFailed("\(error)")
            ))
            return ActOutcome(.actedUnverified, "set '\(element.label)': delivery failed: \(error)",
                              check: OperationCheck(condition: .stateAfterGesture, method: .controlState,
                                                    verdict: .unknown, expected: desired.rawValue,
                                                    limits: [.deliveryUncertain], performed: .uncertain,
                                                    target: OperationCheck.Target(element)))
        }
        await settle(pid)
        let afterWindow = await perceive(pid)
        let after = afterWindow?.scene
        var answered = await dependencies.controls?.toggleState(at: point, in: pid)
        if answered == nil { answered = await dependencies.controls?.toggleState(labelled: element.label, in: pid) }
        let readBack = answered
            ?? after?.elements.first(where: { $0.id == element.id })?.state
            ?? after?.elements.first(where: {
                $0.state != nil && LabelText.normalize($0.label) == LabelText.normalize(element.label)
            })?.state
        let effect = after.flatMap { SceneDifference.effect(before: perceived.scene, after: $0, targetID: element.id) }
        await dependencies.observer?.record(ActionRecord(
            bundleID        : request.bundleID,
            element         : element,
            verb            : .setToggle,
            effect          : effect,
            windowTitleAfter: after?.windowTitle,
            before          : perceived,
            after           : afterWindow
        ))
        await dependencies.actuator.confirm(readBack == desired ? .observed : .unknown, in: pid)
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
        // A native menu names its items: the one of that title is pressed, and keys pick only otherwise.
        if !request.isDryRun, let controls = dependencies.controls,
           await controls.pressMenuItem(titled: element.label, within: popupFrame, in: pid) {
            await pause(timing.popupCommit)
            let stillOpen = await surfaces(pid).hasOpenPopup
            let afterWindow = await perceive(pid)
            let after = afterWindow?.scene
            await recordPick(request, element: element, before: perceived, after: afterWindow)
            let check = OperationCheck(
                condition: .menuClosedAfterChoice, method: .windowCensus, verdict: stillOpen ? .failed : .passed,
                expected: "menu closed", observed: stillOpen ? "menu open" : "menu closed",
                limits: [.commandEffectUnchecked], performed: .requested, target: OperationCheck.Target(element)
            )
            if stillOpen {
                return ActOutcome(.actedUnverified, "pressed '\(element.label)' in the open menu, but the "
                    + "menu is still open: observe before choosing again.", scene: after, check: check)
            }
            return ActOutcome(.foundActed, "chose '\(element.label)' in the open menu through its accessibility "
                + "item; the menu closed. Check the command's own effect before going on.", scene: after, check: check)
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
            await dependencies.actuator.confirm(picked ? .observed : .unknown, in: pid)
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
                await dependencies.actuator.confirm(.observed, in: pid)
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
        if let error = await send([.insert(text)], to: pid) {
            return ActOutcome(.actedUnverified, "inserting text: delivery failed: \(error); observe before any retry",
                              check: Self.undelivered(expecting == nil ? .none : .valueReadBack, method: .controlValue,
                                                      expected: expecting))
        }
        await settle(pid)
        let after = await perceive(pid)?.scene
        let value = await dependencies.controls?.focusedFieldValue(in: pid)
        let verified = expecting != nil && value != nil && value == expecting
        await dependencies.actuator.confirm(verified ? .observed : .unknown, in: pid)
        // Without an expected value there is nothing to compare: the insertion stays unknown, never passed.
        let check = expecting == nil
            ? OperationCheck(condition: .none, method: .none, verdict: .unknown, limits: [.noExpectedValue],
                             performed: .requested)
            : OperationCheck(condition: .valueReadBack, method: .controlValue,
                             verdict: verified ? .passed : value == nil ? .unknown : .failed, expected: expecting,
                             observed: value, limits: value == nil ? [.readbackUnavailable] : [], performed: .requested)
        if verified, let value {
            return ActOutcome(.foundActed, "inserted text: the focused field reads '\(Self.shortened(value))'",
                              scene: after, check: check)
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
            byTripleClick: permissions.selectsFieldsByTripleClick
        ) + [inserts ? .insert(typed) : .type(typed)]
        // Text kept in a field the click placed its caret in goes through accessibility too, which a key
        // in between would forget.
        let endOfField = Self.textFieldRoles.contains(element.role ?? "") ? Self.endOfField : nil
        if let error = await send(gestures, to: pid, redundantAfterAccessibilityClick: endOfField) {
            return ActOutcome(.actedUnverified, "typing into '\(element.label)': delivery failed: \(error)",
                              check: Self.undelivered(.valueReadBack, method: .controlValue, expected: typed,
                                                      target: element))
        }
        await settle(pid)
        let after = await perceive(pid)?.scene
        let readBack = await dependencies.controls?.focusedFieldValue(in: pid)
            ?? after?.elements.first(where: { $0.id == element.id })?.value
        let wanted = replacing ? typed : element.value.map { $0 + text }
        await dependencies.actuator.confirm(readBack != nil && readBack == wanted ? .observed : .unknown, in: pid)
        let composing = inserts ? " This text is inserted as one event; an active input method may reject it." : ""
        let verdict: OperationCheck.Verdict = switch (readBack, wanted) {
            case (.some(let value), .some(let wanted)): value == wanted ? .passed : .failed
            default                                   : .unknown
        }
        let check = OperationCheck(
            condition: .valueReadBack, method: .controlValue, verdict: verdict, expected: wanted, observed: readBack,
            limits: (readBack == nil ? [.readbackUnavailable] : []) + (wanted == nil ? [.previousValueUnknown] : []),
            performed: .requested, target: OperationCheck.Target(element)
        )
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
        if ActionPolicy.isDestructive(chord), !permissions.allowsDestructive {
            return ActOutcome(.refused, "\(chord) deletes in most applications: refused. If you want the agent "
                + "to do this, the person must allow destructive actions.", scene: perceived.scene)
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
                + " into \(request.appName)'s window")
        }
        await raiseIfNeeded(pid, isPopupOpen: (await surfaces(pid)).hasOpenPopup)
        if let error = await send(Array(repeating: chord.gesture, count: times), to: pid) {
            return ActOutcome(.actedUnverified, "\(pressed): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference))
        }
        // A background chord's unchanged scene does not qualify the target's menu support.
        let note = dependencies.activation == nil && chord.modifiers.contains(.command) ? Self.menuShortcutNote : ""
        let outcome = await judged(
            pressed, in: request, before: perceived.scene, targetID: nil,
            ghost: "If you expected an effect, the key likely reached a control that ignores it: click the "
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
        if let error = await send([.scroll(at: point, deltaY: lines)], to: pid) {
            return ActOutcome(.actedUnverified, "\(scrolled): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference, target: element))
        }
        return await judged(
            scrolled, in: request, before: perceived.scene, targetID: element?.id,
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
                if ActionPolicy.isDestructive(label: other.label), !permissions.allowsDestructive {
                    return ActOutcome(.refused, "dropping on '\(other.label)' looks destructive/irreversible: "
                        + "refused. If you want the agent to do this, the person must allow destructive actions.",
                        scene: scene)
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
        if let error = await send([.drag(from: start, to: finish)], to: pid) {
            return ActOutcome(.actedUnverified, "\(dragged): delivery failed: \(error)",
                              check: Self.undelivered(.structuralEffect, method: .sceneDifference, target: element))
        }
        return await judged(
            dragged, in: request, before: scene, targetID: element.id,
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
        if ActionPolicy.isDestructive(label: item), !permissions.allowsDestructive {
            return ActOutcome(.refused, "'\(item)' looks destructive/irreversible: refused. If you want the agent "
                + "to do this, the person must allow destructive actions.", scene: perceived.scene)
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
        if let error = await send([.click(at: point, button: .right)], to: pid) {
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
            await dependencies.actuator.confirm(closed ? .observed : .unknown, in: pid)
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

    /// The refusal of a right click whose menu would open outside the seat, nil when it may go ahead.
    private func menuOutsideTheSeat(on element: SceneElement, appName: String, scene: SceneSnapshot) -> ActOutcome? {
        guard permissions.contextMenusOnTextFieldsOnly, !Self.textFieldRoles.contains(element.role ?? "") else {
            return nil
        }
        return ActOutcome(.refused, "\(appName) opens the contextual menu of '\(element.label)' on the person's own "
            + "screen, outside the seat, so it was not right-clicked: use a visible button or control instead. "
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
        await settling.settle(in: processID, cap: timing.clickSettle)
    }

    /// Delivers the gestures in order and answers the error that stopped them, nil when all went out.
    /// A failure closes the delivery as unknown: what went out before it is never repeated.
    /// A `redundantAfterAccessibilityClick` gesture right after a click that went through accessibility
    /// is not delivered: that click left its caret where the gesture would have moved it.
    private func send(
        _ gestures: [Gesture],
        to processID: pid_t,
        redundantAfterAccessibilityClick redundant: Gesture? = nil
    ) async -> (any Error)? {
        do {
            // One reference before the first gesture: any effect of the whole input then counts.
            if !gestures.isEmpty { await dependencies.settling?.prepare(in: processID) }
            for (index, gesture) in gestures.enumerated() {
                if gesture == redundant, index > 0, case .click = gestures[index - 1],
                   await dependencies.actuator.lastDeliveryRoute(in: processID) == .accessibility {
                    continue
                }
                try await dependencies.actuator.perform(gesture, in: processID)
            }
            return nil
        } catch {
            await dependencies.actuator.confirm(.unknown, in: processID)
            return error
        }
    }

    /// An input with no reading of its own is judged by the two scenes alone, and its delivery closed
    /// with what they showed. `ghost` and `repaint` are what to do next when nothing was attributed.
    private func judged(
        _ performed       : String,
        in request        : InputRequest,
        before            : SceneSnapshot,
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
        guard let after = await perceive(pid)?.scene else {
            await dependencies.actuator.confirm(.unknown, in: pid)
            return ActOutcome(.actedUnverified, "\(performed): no scene could be read afterwards; observe when "
                + "the window is back", check: OperationCheck(
                    condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                    limits: [.noAfterScene, .noExpectation], performed: .requested, target: target))
        }
        let effect = Self.gatedEffect(
            before: before, after: after, targetID: targetID ?? "", popupIsOpen: (await surfaces(pid)).hasOpenPopup,
            countsValueChange: countsValueChange, ignoresTextRereads: ignoresTextRereads
        )
        let verdict = ActVerification.verdict(before: before, after: after, effect: effect)
        if movesFocus, verdict != .ghost, Self.showsFocus(before: before, after: after, effect: effect) {
            return await focusJudged(performed, pid: pid, before: before, after: after, effect: effect, target: target)
        }
        Self.inputTrail?.attribute(effect)
        let delivery: DeliveryEffect = switch verdict {
            case .landed        : .observed
            case .ghost         : .absent
            case .unattributable: .unknown
        }
        await dependencies.actuator.confirm(delivery, in: pid)
        // An input has no learned expectation: any structural change anywhere in the window passes.
        let check = OperationCheck.sceneDifference(verdict, expected: nil, target: target, limits: [.windowWide])
        switch verdict {
            case .landed(let effect, _):
                return ActOutcome(.foundActed, "\(performed): \(effect.summary)", scene: after, check: check)
            case .ghost:
                return ActOutcome(.actedUnverified, "\(performed): this window did NOT change (identical scene). "
                    + ghost, scene: after, check: check)
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
        await dependencies.actuator.confirm(moved == nil ? .unknown : .observed, in: pid)
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
    private static func shortened(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? flat.prefix(59) + "…" : flat
    }

    /// A menu is believable only while a pop-up window exists; and when one does, the menu's rows
    /// are the effect whatever the scene difference read, because the after scene IS the menu.
    static func gatedEffect(
        before            : SceneSnapshot,
        after             : SceneSnapshot,
        targetID          : String,
        popupIsOpen       : Bool,
        countsValueChange : Bool = false,
        ignoresTextRereads: Bool = false
    ) -> SceneEffect? {
        let (was, now) = ignoresTextRereads ? withoutTextRereads(before: before, after: after) : (before, after)
        var effect = SceneDifference.effect(
            before: was, after: now, targetID: targetID, countsValueChange: countsValueChange
        )
        if case .menuOpened(let labels) = effect, !popupIsOpen { effect = .elementsAppeared(labels: labels) }
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

    private func surfaces(_ processID: pid_t) async -> WindowSurfaces {
        let rows = (try? dependencies.windows.windows(ownedBy: processID)) ?? []
        return WindowSurfaceClassifier.classify(rows)
    }

    private func noSceneReason(appName: String, processID: pid_t) async -> String {
        let rows = (try? dependencies.windows.windows(ownedBy: processID)) ?? []
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
