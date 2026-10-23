//
//  ActionEngineTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// The act cycle over doubles that honor the roles: a scene source that answers a scripted sequence,
/// an actuator that records gestures, a window list that answers a scripted census, a control reader
/// with scripted values. No screen, no sleep.
@Suite("Action engine")
struct ActionEngineTests {

    // MARK: Doubles

    final class ScriptedScenes: SceneProviding, @unchecked Sendable {
        var queue: [PerceivedWindow]
        var calls = 0
        init(_ scenes: [PerceivedWindow]) { queue = scenes }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            calls += 1
            guard !queue.isEmpty else { throw Unavailable() }
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }

    /// The window as read before the gesture, and no scene after it: every read once the actuator acted fails.
    final class ScenesLostAfterGesture: SceneProviding, @unchecked Sendable {
        let before  : PerceivedWindow
        let actuator: RecordingActuator
        var readsAfter = 0
        init(_ before: PerceivedWindow, after actuator: RecordingActuator) { self.before = before; self.actuator = actuator }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            guard actuator.gestures.isEmpty else { readsAfter += 1; throw Unavailable() }
            return before
        }
    }

    final class RecordingActuator: Actuating, @unchecked Sendable {
        var gestures: [Gesture] = []
        var confirmations: [DeliveryEffect] = []
        var failure: (any Error)?
        var route = DeliveryRoute.posted
        /// The name of the control each aimed click said it was for, in order.
        var labels: [String] = []
        func lastDeliveryRoute(in processID: pid_t) async -> DeliveryRoute { route }
        /// How many gestures go out before `failure` is thrown.
        var failsFrom = 0
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            if let failure, gestures.count >= failsFrom { throw failure }
            gestures.append(gesture)
        }
        func perform(_ gesture: Gesture, expecting label: String, in processID: pid_t) async throws {
            try await perform(gesture, in: processID)
            labels.append(label)
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
            confirmations.append(effect)
        }
    }

    final class ScriptedWindows: WindowListing, @unchecked Sendable {
        var queue: [[WindowRow]]
        var readsUntilFailure: Int?
        init(_ rows: [[WindowRow]]) { queue = rows }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            if let remaining = readsUntilFailure {
                guard remaining > 0 else { throw Unavailable() }
                readsUntilFailure = remaining - 1
            }
            return queue.count > 1 ? queue.removeFirst() : (queue.first ?? [])
        }
    }

    /// The window listing that changes with the first gesture: `before` until something went out, `after` once it did.
    final class WindowsChangedByGesture: WindowListing, @unchecked Sendable {
        let before: [WindowRow]
        let after : [WindowRow]
        let actuator: RecordingActuator
        init(before: [WindowRow], after: [WindowRow], actuator: RecordingActuator) {
            self.before = before; self.after = after; self.actuator = actuator
        }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] { actuator.gestures.isEmpty ? before : after }
    }

    final class FakeControls: ControlPressing, @unchecked Sendable {
        var pressed: [String] = []
        var pressSucceeds = false
        var values: [String?]
        var toggle: ControlState?
        var focused: String?
        init(values: [String?] = [nil], toggle: ControlState? = nil) { self.values = values; self.toggle = toggle }
        func pressControl(labelled label: String, in processID: pid_t) async -> Bool { pressed.append(label); return pressSucceeds }
        func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
            values.count > 1 ? values.removeFirst() : values.first ?? nil
        }
        func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { toggle }
        var labelledToggle: ControlState?
        var labelledReads: [String] = []
        func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? {
            labelledReads.append(label); return labelledToggle
        }
        func focusedFieldValue(in processID: pid_t) async -> String? { focused }
        var submenu: MenuItemNavigation?
        func menuItemNavigation(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemNavigation? {
            submenu
        }
        /// The focus the reads answer in turn, the last one kept.
        var focus: [FocusedField] = [.unknown]
        var focusReads = 0
        func focusedField(in processID: pid_t) async -> FocusedField {
            focusReads += 1
            return focus.count > 1 ? focus.removeFirst() : focus.first ?? .unknown
        }
        var menuItemPresses = false
        var pressedMenuItems: [(title: String, frame: CGRect)] = []
        /// The receipt `chooseMenuItem` answers; nil keeps the protocol's default, a press by title.
        var choice: MenuItemPress?
        var chosenItems: [SceneElement] = []
        func chooseMenuItem(_ item: SceneElement, within menuFrame: CGRect, in processID: pid_t) async -> MenuItemPress {
            guard let choice else {
                return await pressMenuItem(titled: item.label, within: menuFrame, in: processID) ? .sent(.unattested) : .notHandled
            }
            chosenItems.append(item)
            return choice
        }
        func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
            pressedMenuItems.append((title, menuFrame)); return menuItemPresses
        }
    }

    final class FakeActivation: ApplicationActivating, @unchecked Sendable {
        var frontmost: pid_t?
        var activated: [pid_t] = []
        init(frontmost: pid_t?) { self.frontmost = frontmost }
        func frontmostProcessID() async -> pid_t? { frontmost }
        func activate(_ processID: pid_t) async { activated.append(processID) }
    }

    final class RecordingObserver: ActionObserving, @unchecked Sendable {
        var records: [ActionRecord] = []
        var inputs: [InputRecord] = []
        func record(_ record: ActionRecord) async { records.append(record) }
        func record(_ input: InputRecord) async { inputs.append(input) }
    }

    /// A menu bar that answers a scripted outcome, nil when nothing was dispatched, and observes after a press.
    final class FakeMenus: MenuCommanding, @unchecked Sendable {
        var pressed: [String] = []
        var answer: ActOutcome?
        init(answer: ActOutcome?) { self.answer = answer }
        func performMenuItem(_ path: String, in processID: pid_t,
                             observe: @Sendable () async throws -> SceneSnapshot) async -> ActOutcome? {
            pressed.append(path)
            guard let answer else { return nil }
            return answer.with(scene: try? await observe())
        }
    }

    struct FixedExpectation: EffectExpecting {
        var effect: SceneEffect?
        func expectedEffect(of verb: ActionVerb, on element: SceneElement, in window: PerceivedWindow) async -> SceneEffect? { effect }
    }

    struct Unavailable: Error {}

    // MARK: Fixtures

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242

    private func rect(_ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.02) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func scene(_ elements: [SceneElement], title: String = "Export", token: String? = nil) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements,
            token: token.map(SceneToken.init(rawValue:))
        ), frame: frame)
    }

    private let toggleOff = SceneElement(id: "control|facebook", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .off)
    private let toggleOn  = SceneElement(id: "control|facebook", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .on)
    private let export    = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.08, height: 0.03))

    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Export", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56), title: nil, number: 9)

    private func request(_ target: String, verb: ActionVerb = .click, section: String? = nil,
                         desired: ControlState? = nil, dryRun: Bool = false) -> ActionRequest {
        ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: target, verb: verb,
                      section: section, desiredState: desired, isDryRun: dryRun)
    }

    private func engine(scenes: ScriptedScenes, actuator: RecordingActuator = RecordingActuator(),
                        windows: ScriptedWindows? = nil, controls: FakeControls? = nil, activation: FakeActivation? = nil,
                        expectations: FixedExpectation? = nil, observer: RecordingObserver? = nil,
                        permissions: ActionPermissions = ActionPermissions(), menus: FakeMenus? = nil,
                        settling: (any Settling)? = nil) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: scenes, actuator: actuator, windows: windows ?? ScriptedWindows([[mainWindow]]),
                controls: controls, activation: activation, expectations: expectations, observer: observer,
                settling: settling, menus: menus
            ),
            permissions: permissions, pause: { _ in }
        )
    }

    // MARK: Resolution and policy

    @Test("a click resolves the native Create button instead of its sentence caption")
    func createButtonAndCaption() async {
        let caption = SceneElement(id: "text|create", kind: .text, label: "Create", bounds: rect(0.04, 0.30))
        let button = SceneElement(id: "control|create", kind: .control, label: "Create",
                                  bounds: rect(0.86, 0.85), role: "AXButton")
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([caption, button])]), actuator: actuator)
            .act(request("Create", dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message.contains("1010,788"))
        #expect(actuator.gestures.isEmpty)
    }

    @Test("no scene is an honest miss that says whether a window exists")
    func noScene() async {
        let noWindow = await engine(scenes: ScriptedScenes([]), windows: ScriptedWindows([[]])).act(request("Export"))
        #expect(noWindow.kind == .honestMiss)
        #expect(noWindow.message.contains("NO window open"))
        let hasWindow = await engine(scenes: ScriptedScenes([])).act(request("Export"))
        #expect(hasWindow.message.contains("could not be perceived"))
    }

    @Test("a missing target is an honest miss with the closest labels")
    func missingTarget() async {
        let outcome = await engine(scenes: ScriptedScenes([scene([export])])).act(request("the Export button"))
        #expect(outcome.kind == .honestMiss)
        #expect(outcome.message.contains("closest on screen: 'Export'"))
    }

    @Test("a shared label is ambiguous with a section hint, and a section resolves it")
    func ambiguous() async {
        var tab = export; tab.id = "control|export"; tab.section = "top bar"; tab.bounds = rect(0.3, 0.02)
        var button = export; button.section = "bottom bar"
        let actuator = RecordingActuator()
        let scenes = ScriptedScenes([scene([tab, button]), scene([tab, button]), scene([tab, button], title: "Render Queue")])
        let engine = engine(scenes: scenes, actuator: actuator)
        let outcome = await engine.act(request("Export"))
        #expect(outcome.kind == .ambiguous)
        #expect(outcome.message.contains("section:'top bar'") && outcome.message.contains("section:'bottom bar'"))
        let resolved = await engine.act(request("Export", section: "bottom bar"))
        #expect(resolved.kind == .foundActed, Comment(rawValue: resolved.message))
        #expect(actuator.gestures.count == 1)
    }

    @Test("Pro Tools audio send selectors are navigation, while message sends still refuse")
    func audioSendNavigation() async {
        let cases: [(String, String, String?, String?, Bool)] = [
            ("com.avid.ProTools", "Send selector A", "AXButton", "Kick / Sends A-E", true),
            ("com.avid.ProTools", "Send Assignment J", "AXButton", "Kick / Sends F-J", true),
            ("com.x", "Send selector A", "AXButton", "Kick / Sends A-E", false),
            ("com.avid.ProTools", "Send selector A", nil, "Kick / Sends A-E", false),
            ("com.avid.ProTools", "Send selector A", "AXButton", nil, false),
            ("com.avid.ProTools", "Send selector A", "AXButton", "Kick / Sends F-J", false),
            ("com.avid.ProTools", "Send", "AXButton", "Kick / Sends A-E", false),
            ("com.avid.ProTools", "Send selector A and delete", "AXButton", "Kick / Sends A-E", false),
        ]
        for (bundle, label, role, container, allowed) in cases {
            let control = SceneElement(
                id: "control|send", kind: .control, label: label, bounds: rect(0.5, 0.5),
                role: role, container: container
            )
            let outcome = await engine(scenes: ScriptedScenes([scene([control])])).act(ActionRequest(
                processID: pid, bundleID: bundle, appName: "Test", target: label,
                verb: .click, isDryRun: true
            ))
            #expect(outcome.kind == (allowed ? .dryRun : .refused), Comment(rawValue: label))
        }
    }

    @Test("a context-free no-send label remains refused")
    func audioSendRemovalNeedsItsSelector() async {
        let item = SceneElement(id: "no-send", kind: .text, label: "no send", bounds: rect(0.5, 0.5))
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([item])]), actuator: actuator).act(ActionRequest(
            processID: pid, bundleID: "com.avid.ProTools", appName: "Pro Tools", target: "no send", verb: .click
        ))
        #expect(outcome.kind == .refused)
        #expect(actuator.gestures.isEmpty)
    }

    @Test("only a native audio menu in Pro Tools permits a no-send click")
    func audioSendMenuRemoval() async {
        for (bundle, native, popup, allowed) in [
            ("com.avid.ProTools", true, true, true),
            ("com.avid.ProTools", false, true, false),
            ("com.avid.ProTools", true, false, false),
            ("com.example.mail", true, true, false)
        ] {
            let item = SceneElement(id: "no-send", kind: .text, label: "no send",
                                    bounds: rect(0.22, 0.26))
            let actuator = RecordingActuator()
            let controls = FakeControls()
            controls.submenu = MenuItemNavigation(hasSubmenu: false, row: 0, submenuFrame: nil,
                                                  isAudioSendMenu: native)
            controls.menuItemPresses = true
            let outcome = await engine(
                scenes: ScriptedScenes([scene([item]), scene([])]), actuator: actuator,
                windows: ScriptedWindows(popup ? [[popupWindow, mainWindow], [mainWindow]] : [[mainWindow]]),
                controls: controls
            ).act(ActionRequest(processID: pid, bundleID: bundle, appName: "Test", target: "no send", verb: .click))
            #expect(outcome.kind == (allowed ? .foundActed : .refused))
            #expect(controls.pressedMenuItems.count == (allowed ? 1 : 0))
            #expect(actuator.gestures.isEmpty)
        }
    }

    @Test("a click verifies the toggle in its own track when other tracks share its ID")
    func repeatedToggleIdentity() async {
        let bus = SceneElement(
            id: "control|mute", kind: .control, label: "Mute", bounds: rect(0.01, 0.68),
            role: "AXButton", state: .off, container: "DRUMS BUS"
        )
        var kick = SceneElement(
            id: "control|mute", kind: .control, label: "Mute", bounds: rect(0.07, 0.68),
            role: "AXButton", state: .off, container: "Kick"
        )
        let before = scene([bus, kick])
        kick.state = .on
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes: ScriptedScenes([before, scene([bus, kick])]), actuator: actuator
        ).act(ActionRequest(
            processID: pid, bundleID: "com.x", appName: "X", target: "Mute {Kick}", verb: .click
        ))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.check?.observed == "stateFlip")
        #expect(actuator.confirmations == [.observed])
    }

    @Test("R07: a destructive target is refused without the person's consent, and with it: no route here verifies it")
    func destructive() async {
        let trash = SceneElement(id: "control|delete", kind: .control, label: "Delete", bounds: rect(0.5, 0.5))
        let unconsented = RecordingActuator()
        let refused = await engine(scenes: ScriptedScenes([scene([trash])]), actuator: unconsented)
            .act(request("Delete"))
        #expect(refused.kind == .refused && refused.message.contains("person must allow destructive actions"))
        #expect(refused.message.contains("not authorized in this session"), "the model must not read it as allowed but blocked")
        // The person's consent is necessary, never sufficient: the scene read again is no verifier of a delete.
        let blind = RecordingActuator()
        let unconfirmed = await engine(scenes: ScriptedScenes([scene([trash]), scene([trash], title: "Gone")]),
                                       actuator: blind, permissions: ActionPermissions(allowsDestructive: true))
            .act(request("Delete"))
        #expect(unconfirmed.kind == .refused, Comment(rawValue: unconfirmed.message))
        #expect(unconfirmed.message.contains("cannot read its effect back"), Comment(rawValue: unconfirmed.message))
        #expect(unconsented.gestures.isEmpty && blind.gestures.isEmpty)
    }

    @Test("R10: what the memory learned of a destructive step grants nothing: refused with or without consent")
    func learnedStepUnderCurrentPolicy() async {
        let trash = SceneElement(id: "control|delete", kind: .control, label: "Delete", bounds: rect(0.5, 0.5))
        // The memory expects this step's effect: it was learned, and would be proposed again.
        let learned = FixedExpectation(effect: .windowTitleChanged(title: "Trash"))
        for permissions in [ActionPermissions(), ActionPermissions(allowsDestructive: true)] {
            let actuator = RecordingActuator()
            let outcome = await engine(scenes: ScriptedScenes([scene([trash]), scene([trash], title: "Trash")]),
                                       actuator: actuator, expectations: learned, permissions: permissions)
                .act(request("Delete"))
            #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
            #expect(actuator.gestures.isEmpty, "the current policy decides, not the learned expectation")
        }
    }

    @Test("a dry run performs nothing and names the point and the expectation")
    func dryRun() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                   expectations: FixedExpectation(effect: .windowTitleChanged(title: "Render Queue")))
            .act(request("Export", dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message.contains("at 940,832"), Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("navigates to Render Queue"))
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: The click cycle

    @Test("a structural change lands, is recorded, and the click hits the element's point")
    func landed() async throws {
        let actuator = RecordingActuator(), observer = RecordingObserver()
        let outcome = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), actuator: actuator, observer: observer)
            .act(request("Facebook"))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.message == "clicked 'Facebook': toggles")
        #expect(actuator.gestures == [.click(at: CGPoint(x: 100 + 0.225 * 1000, y: 100 + 0.21 * 800))])
        let record = try #require(observer.records.first)
        #expect(record.effect == .stateFlip(from: .off, to: .on))
        #expect(record.verb == .click)
        #expect(record.before == scene([toggleOff]) && record.after == scene([toggleOn]),
                "the record carries the perceptions the engine judged the click by")
        #expect(actuator.confirmations == [.observed], "a landed effect closes the delivery as observed")
    }

    @Test("an input reports what it perceived before and after and the effect it attributed, once, after its outcome")
    func inputRecord() async throws {
        let observer = RecordingObserver()
        let appeared = SceneElement(id: "control|queue", kind: .control, label: "Queue",
                                    bounds: NormalizedRect(x: 0.4, y: 0.4, width: 0.08, height: 0.03))
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export, appeared])]), observer: observer)
            .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X", input: .scroll(lines: -3, over: nil)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(observer.records.isEmpty, "an input is not an action record")
        let input = try #require(observer.inputs.first)
        #expect(observer.inputs.count == 1)
        #expect(input.before == scene([export]) && input.after == scene([export, appeared]))
        #expect(input.effect == .elementsAppeared(labels: ["Queue"]))
        #expect(input.attempt == .delivered)

        let refused = RecordingObserver()
        _ = await engine(scenes: ScriptedScenes([scene([export])]), observer: refused)
            .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X", input: .scroll(lines: 0, over: nil)))
        #expect(refused.inputs.first?.attempt == .notAttempted(reason: "refused"))
        #expect(refused.inputs.first?.after == nil)
    }

    @Test("an identical scene is a ghost and says nothing else changed")
    func ghost() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.absent], "an identical scene is verified absence")
        #expect(outcome.message.contains("did NOT change"))
        #expect(outcome.message.contains("do not repeat the click solely from this verdict"))
        #expect(outcome.message.contains("No window of X opened, closed or retitled"))
    }

    @Test("a press through accessibility that changed nothing says it was not clicked, and a posted one does not")
    func ghostThroughAccessibility() async {
        let pressed = RecordingActuator()
        pressed.route = .accessibility
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: pressed).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("through accessibility, no click posted"))

        let posted = await engine(scenes: ScriptedScenes([scene([export])]), actuator: RecordingActuator())
            .act(request("Export"))
        #expect(!posted.message.contains("accessibility"))
    }

    @Test("a repaint is unattributable, and a window that appeared elsewhere is named instead of blaming the click")
    func repaintWithElsewhere() async {
        let before = scene([export], token: "a"), after = scene([export], token: "b")
        let windows = ScriptedWindows([[mainWindow], [mainWindow], [WindowRow(layer: 0, frame: CGRect(x: 200, y: 200, width: 400, height: 300), title: "Save", number: 2), mainWindow]])
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([before, after]), actuator: actuator, windows: windows)
            .act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.unknown], "a repaint establishes nothing")
        #expect(outcome.message.contains("nothing structural"))
        #expect(outcome.message.contains("NEW window \"Save\" appeared"))
        #expect(!outcome.message.contains("likely did not register"))
    }

    @Test("a click after which no scene can be read is unverified: one gesture, not repeated, and no success claimed")
    func clickWithNoSceneAfterIsUnverified() async {
        let actuator = RecordingActuator()
        let scenes   = ScenesLostAfterGesture(scene([export], token: "before"), after: actuator)
        let outcome  = await ActionEngine(
            ActionEngine.Dependencies(scenes: scenes, actuator: actuator, windows: ScriptedWindows([[mainWindow]]),
                                      controls: nil, activation: nil, expectations: nil, observer: nil),
            permissions: ActionPermissions(), pause: { _ in }
        ).act(request("Export"))

        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.gestures.count == 1, "the click is sent once and never again")
        #expect(actuator.confirmations == [.unknown])
        #expect(scenes.readsAfter >= 1, "the engine tried to read the window after the click")
    }

    /// A dialog whose frame is the scene's, over the application's main window: the window a click lands in.
    private var dialogWindow: WindowRow { WindowRow(layer: 0, frame: frame, title: "Save", number: 7) }
    private var backWindow: WindowRow {
        WindowRow(layer: 0, frame: CGRect(x: 0, y: 0, width: 900, height: 700), title: "Document", number: 1)
    }

    /// Clicks Don't Save in a dialog: afterwards the dialog is no longer listed and no scene can be read.
    private func clickThatClosesItsWindow(alive: Bool) async -> (ActOutcome, RecordingActuator) {
        let actuator = RecordingActuator()
        let outcome = await ActionEngine(
            ActionEngine.Dependencies(
                scenes: ScenesLostAfterGesture(scene([export], token: "before"), after: actuator), actuator: actuator,
                windows: WindowsChangedByGesture(before: [dialogWindow, backWindow], after: [backWindow], actuator: actuator),
                isRunning: { _ in alive }
            ),
            permissions: ActionPermissions(), pause: { _ in }
        ).act(request("Export"))
        return (outcome, actuator)
    }

    @Test("a click whose window closed while its process lives passes as a window set change")
    func clickThatClosesItsWindowPasses() async {
        let (outcome, actuator) = await clickThatClosesItsWindow(alive: true)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.check?.condition == .windowSetChanged && outcome.check?.verdict == .passed)
        #expect(outcome.check?.limits.contains(.commandEffectUnchecked) == true)
        #expect(outcome.message.contains("closed") && outcome.message.contains("still running"))
        #expect(actuator.gestures.count == 1 && actuator.confirmations == [.observed])
    }

    @Test("a click after which the process is gone stays unverified: the window did not close, the application did")
    func clickThatEndsItsProcessStaysUnknown() async {
        let (outcome, actuator) = await clickThatClosesItsWindow(alive: false)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.check?.verdict == .unknown && outcome.check?.limits.contains(.noAfterScene) == true)
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("an unclassified display update does not invite replay", arguments: ["7+", "78"])
    func displayUpdateRemainsUnverified(value: String) async {
        let displayBefore = SceneElement(
            id    : "text|display",
            kind  : .text,
            label : "7",
            bounds: rect(0.6, 0.1)
        )
        let displayAfter = SceneElement(
            id    : "text|display",
            kind  : .text,
            label : value,
            bounds: rect(0.6, 0.1)
        )
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes  : ScriptedScenes([
                scene([export, displayBefore], token: "before"),
                scene([export, displayAfter], token: "after")
            ]),
            actuator: actuator
        ).act(request("Export"))

        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures.count == 1)
        #expect(outcome.scene?.elements.contains(where: { $0.label == value }) == true)
        #expect(!outcome.message.contains("dead click"))
        #expect(!outcome.message.contains("NOT your action landing"))
        #expect(!outcome.message.contains("likely did not register"))
    }

    @Test("an expectation is compared by family")
    func expectation() async {
        let matching = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]),
                                    expectations: FixedExpectation(effect: .stateFlip(from: .on, to: .off))).act(request("Facebook"))
        #expect(matching.kind == .foundActed)
        #expect(matching.message.hasSuffix("(as expected)"))
        let surprised = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]),
                                     expectations: FixedExpectation(effect: .menuOpened(labels: []))).act(request("Facebook"))
        #expect(surprised.kind == .actedUnverified)
        #expect(surprised.message.contains("expected opens menu() but observed toggles"))
    }

    @Test("a menu is believed only while a pop-up window exists, and its rows become the effect")
    func menuGating() async {
        let base = scene([export])
        let rows = [export] + ["Cut", "Copy", "Paste"].enumerated().map { i, label in
            SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label, bounds: rect(0.3, 0.3 + Double(i) * 0.03))
        }
        let noPopup = await engine(scenes: ScriptedScenes([base, scene(rows)])).act(request("Export"))
        #expect(noPopup.message.contains("reveals elements"))
        let withPopup = await engine(scenes: ScriptedScenes([base, scene(rows)]),
                                     windows: ScriptedWindows([[mainWindow], [mainWindow], [popupWindow, mainWindow]]))
            .act(request("Export"))
        #expect(withPopup.kind == .foundActed)
        #expect(withPopup.message.contains("opens menu(Copy|Cut|Export"))
    }

    @Test("a remaining popup cannot replace the observed return from a dialog")
    func windowChangePrecedesPopupInference() {
        let before = scene([export], title: "MP3").scene
        let after = scene([export, boldOff], title: "Mix: Prova").scene
        #expect(ActionEngine.gatedEffect(
            before: before, after: after, targetID: export.id, popupIsOpen: true
        ) == .windowTitleChanged(title: "Mix: Prova"))
    }

    @Test("a remaining popup cannot replace a verified toggle")
    func togglePrecedesPopupInference() {
        let on = SceneElement(id: boldOff.id, kind: .control, label: boldOff.label,
                              bounds: boldOff.bounds, role: "AXCheckBox", state: .on)
        #expect(ActionEngine.gatedEffect(
            before: scene([export, boldOff]).scene, after: scene([export, on]).scene,
            targetID: boldOff.id, popupIsOpen: true
        ) == .stateFlip(from: .off, to: .on))
    }

    @Test("an unchanged scene with a persistent popup does not claim a menu opened")
    func unchangedPopupHasNoOpeningEffect() {
        let unchanged = scene([export, boldOff]).scene
        #expect(ActionEngine.gatedEffect(
            before: unchanged, after: unchanged, targetID: export.id, popupIsOpen: true
        ) == nil)
    }

    @Test("activation happens only when the app is not in front, and never with a pop-up open")
    func activation() async {
        let behind = FakeActivation(frontmost: 1)
        _ = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), activation: behind).act(request("Export"))
        #expect(behind.activated == [pid])
        let inFront = FakeActivation(frontmost: pid)
        _ = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), activation: inFront).act(request("Export"))
        #expect(inFront.activated.isEmpty)
    }

    @Test("a click tells the actuator the name of the control it is aimed at")
    func aClickNamesItsTarget() async {
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), actuator: actuator)
            .act(request("Export"))
        #expect(actuator.labels == [export.label])
    }

    @Test("a triple click is one train of three at the element's point")
    func tripleClick() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Q")]), actuator: actuator)
            .act(request("Export", verb: .tripleClick))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.message.hasPrefix("triple-clicked 'Export'"))
        #expect(actuator.gestures == [.click(at: scene([export]).globalPoint(of: export), count: 3)])
    }

    @Test("text selection prefers the real field when Search controls share its ID", arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func tripleClickSharedFieldID(role: String) async {
        let field = SceneElement(id: "control|search", kind: .control, label: "Search #2",
                                 bounds: rect(0.40, 0.16, 0.4, 0.04), role: role)
        let toggle = SceneElement(id: field.id, kind: .control, label: "Search",
                                  bounds: rect(0.80, 0.04), role: "AXCheckBox", state: .on)
        let other = SceneElement(id: field.id, kind: .control, label: "Search #3",
                                 bounds: rect(0.80, 0.30), role: "AXCheckBox", state: .off)
        let before = scene([toggle, field, other])
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([before, before]), actuator: actuator)
            .act(request(field.id, verb: .tripleClick))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.hasPrefix("triple-clicked 'Search #2'"))
        #expect(actuator.gestures == [.click(at: before.globalPoint(of: field), count: 3)])

        let ordinary = RecordingActuator()
        let clicked = await engine(scenes: ScriptedScenes([before]), actuator: ordinary).act(request(field.id))
        #expect(clicked.kind == .ambiguous)
        #expect(ordinary.gestures.isEmpty)

        let second = SceneElement(id: field.id, kind: .control, label: field.label,
                                  bounds: rect(0.4, 0.7), role: role)
        let ambiguous = RecordingActuator()
        let refused = await engine(scenes: ScriptedScenes([scene([toggle, field, second])]), actuator: ambiguous)
            .act(request(field.id, verb: .tripleClick))
        #expect(refused.kind == .ambiguous)
        #expect(ambiguous.gestures.isEmpty)
    }

    @Test("a dropdown opened by its own press action is not also clicked")
    func openedByPress() async {
        let combo = SceneElement(id: "control|48000", kind: .control, label: "48000", bounds: rect(0.3, 0.4), role: "AXComboBox")
        let controls = FakeControls(); controls.pressSucceeds = true
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([combo]), scene([combo], title: "changed")]), actuator: actuator, controls: controls)
            .act(request("48000"))
        #expect(controls.pressed == ["48000"])
        #expect(actuator.gestures.isEmpty)
        #expect(outcome.kind == .foundActed)
    }

    @Test("delivery failure is reported, never hidden")
    func deliveryFailure() async {
        let actuator = RecordingActuator(); actuator.failure = Unavailable()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("delivery failed"))
        #expect(actuator.confirmations == [.unknown], "a failed delivery is still closed, as unknown")
    }

    // MARK: Format toggles

    private let boldOff = SceneElement(id: "control|bold", kind: .control, label: "bold", bounds: NormalizedRect(x: 0.01, y: 0.05, width: 0.03, height: 0.02), role: "AXCheckBox", state: .off)
    private let boldOn  = SceneElement(id: "control|bold", kind: .control, label: "bold", bounds: NormalizedRect(x: 0.01, y: 0.05, width: 0.03, height: 0.02), role: "AXCheckBox", state: .on)

    @Test("a format toggle whose own state flipped is unverified and names the menu command")
    func formatToggleClick() async throws {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([boldOff]), scene([boldOn])]), actuator: actuator)
            .act(request("bold"))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("menu \"Format > Font > Bold\""), Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .passed, "the flip itself was attributed to the click")
        #expect(check.limits.contains(.commandEffectUnchecked))
        #expect(actuator.confirmations == [.observed], "the click was delivered and its flip observed")
    }

    @Test("set_toggle on a format toggle reads its state back but does not claim the text's format")
    func formatToggleSet() async {
        let outcome = await engine(scenes: ScriptedScenes([scene([boldOff]), scene([boldOn])]), controls: FakeControls(toggle: .on))
            .act(request("bold", verb: .setToggle, desired: .on))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.hasPrefix("set 'bold':"))
        #expect(outcome.message.contains("menu \"Format > Font > Bold\""))
        #expect(outcome.check?.limits.contains(.commandEffectUnchecked) == true)
    }

    /// What the menu tool answers for a press that opened no window (TextEdit's Format > Font > Bold).
    private func menuPressed(_ path: String) -> ActOutcome {
        ActOutcome(.actedUnverified, "pressed \(path): no window opened, closed or was retitled; the scene shows "
            + "whether it took effect.", check: OperationCheck(
                condition: .windowSetChanged, method: .windowSignature, verdict: .unknown,
                limits: [.commandEffectUnchecked], performed: .requested))
    }

    @Test("a format toggle's click is carried out through its menu item, and the click is not sent")
    func formatToggleThroughMenu() async throws {
        let actuator = RecordingActuator()
        let observer = RecordingObserver()
        let menus    = FakeMenus(answer: menuPressed("Format > Font > Bold"))
        let outcome  = await engine(scenes: ScriptedScenes([scene([boldOff]), scene([boldOn], title: "After")]),
                                    actuator: actuator, observer: observer, menus: menus).act(request("bold"))
        #expect(menus.pressed == ["Format > Font > Bold"])
        #expect(actuator.gestures.isEmpty, "the toolbar click would toggle the format a second time")
        #expect(outcome.kind == .actedUnverified, "the verdict is the menu command's own")
        #expect(outcome.message.hasPrefix("'bold' applied through Format > Font > Bold, not by clicking the control: "
            + "pressed Format > Font > Bold"), Comment(rawValue: outcome.message))
        #expect(outcome.scene?.windowTitle == "After", "the scene after the menu command is attached")
        let check = try #require(outcome.check)
        #expect(check.condition == .windowSetChanged)
        #expect(check.performed == .substitute)
        #expect(check.substitute == "menu_command")
        #expect(check.target?.label == "bold")
        #expect(observer.records.first?.after?.scene.windowTitle == "After", "the call keeps the window after it")
    }

    @Test("a format toggle whose menu item was not dispatched is clicked and answered as before")
    func formatToggleMenuMissing() async {
        let actuator = RecordingActuator()
        let menus    = FakeMenus(answer: nil)
        let outcome  = await engine(scenes: ScriptedScenes([scene([boldOff]), scene([boldOn])]), actuator: actuator,
                                    menus: menus).act(request("bold"))
        #expect(menus.pressed == ["Format > Font > Bold"])
        #expect(actuator.gestures.count == 1, "the click goes out once")
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.hasPrefix("clicked 'bold': only the control's own state changed"))
        #expect(outcome.message.contains("menu \"Format > Font > Bold\""), Comment(rawValue: outcome.message))
    }

    @Test("an ordinary checkbox is clicked and never sent through a menu")
    func ordinaryCheckboxSkipsMenu() async {
        let actuator = RecordingActuator()
        let menus    = FakeMenus(answer: menuPressed("Format > Font > Bold"))
        let outcome  = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), actuator: actuator,
                                    menus: menus).act(request("Facebook"))
        #expect(menus.pressed.isEmpty)
        #expect(actuator.gestures.count == 1)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.message == "clicked 'Facebook': toggles")
    }

    @Test("stateless Bold permits an explicit click but refuses set_toggle, without a menu substitute")
    func statelessBoldSkipsMenu() async {
        let button = SceneElement(id: "control|bold", kind: .control, label: "Bold", bounds: rect(0.3, 0.3),
                                  role: "AXButton")
        let text   = SceneElement(id: "text|bold", kind: .text, label: "Bold", bounds: rect(0.3, 0.3),
                                  role: "AXStaticText")
        let row    = SceneElement(id: "control|bold-row", kind: .control, label: "Bold", bounds: rect(0.3, 0.3),
                                  role: "AXRow", container: "list view")
        for element in [button, text, row] {
            for verb in [ActionVerb.click, .setToggle] {
                let actuator = RecordingActuator()
                let menus    = FakeMenus(answer: menuPressed("Format > Font > Bold"))
                let outcome  = await engine(scenes: ScriptedScenes([scene([element])]), actuator: actuator,
                                            menus: menus)
                    .act(request("Bold", verb: verb, desired: verb == .setToggle ? .on : nil))
                #expect(menus.pressed.isEmpty, Comment(rawValue: "\(element.role ?? "") \(verb): \(outcome.message)"))
                #expect(actuator.gestures.count == (verb == .click ? 1 : 0),
                        Comment(rawValue: "\(element.role ?? "") \(verb)"))
                if verb == .setToggle { #expect(outcome.kind == .refused) }
            }
        }
    }

    @Test("an Italian format toggle is carried out through the Italian menu path")
    func italianFormatToggleThroughMenu() async {
        let grassetto = SceneElement(id: "control|grassetto", kind: .control, label: "grassetto", bounds: NormalizedRect(x: 0.01, y: 0.05, width: 0.03, height: 0.02), role: "AXCheckBox", state: .off)
        let actuator  = RecordingActuator()
        let menus     = FakeMenus(answer: menuPressed("Formato > Font > Grassetto"))
        let outcome   = await engine(scenes: ScriptedScenes([scene([grassetto])]), actuator: actuator, menus: menus)
            .act(request("grassetto"))
        #expect(menus.pressed == ["Formato > Font > Grassetto"])
        #expect(actuator.gestures.isEmpty)
        #expect(outcome.message.hasPrefix("'grassetto' applied through Formato > Font > Grassetto"))
    }

    @Test("set_toggle on a format toggle goes through its menu item, unless the control already shows the state")
    func formatToggleSetThroughMenu() async {
        let actuator = RecordingActuator()
        let menus    = FakeMenus(answer: menuPressed("Format > Font > Bold"))
        let set      = await engine(scenes: ScriptedScenes([scene([boldOff])]), actuator: actuator, menus: menus)
            .act(request("bold", verb: .setToggle, desired: .on))
        #expect(menus.pressed == ["Format > Font > Bold"])
        #expect(actuator.gestures.isEmpty)
        #expect(set.message.hasPrefix("'bold' applied through Format > Font > Bold"), Comment(rawValue: set.message))
        let already = await engine(scenes: ScriptedScenes([scene([boldOn])]), menus: menus)
            .act(request("bold", verb: .setToggle, desired: .on))
        #expect(already.kind == .actedNoop, "no reader of the selection's format: the current answer stands")
        #expect(menus.pressed.count == 1)
    }

    @Test("a gesture the actuator refused before any event is a refusal with nothing sent, in its own words")
    func gestureNotSent() async {
        let actuator = RecordingActuator()
        actuator.failure = GestureNotSent(reason: "endpoint_refused", sentence: "No control answered there.")
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator).act(request("Export"))
        #expect(outcome.kind == .refused)
        #expect(outcome.message == "clicked 'Export': nothing was sent. No control answered there.")
        #expect(outcome.check?.performed == OperationCheck.Performed.none, "\(String(describing: outcome.check))")
        #expect(!outcome.message.contains("delivery failed"))

        let key = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X",
                                  input: .pressKey(KeyChord(.return), times: 1)))
        #expect(key.kind == .refused)
        #expect(key.message.hasSuffix("nothing was sent. No control answered there."))
    }

    @Test("a refusal after an earlier gesture of the same input went out stays a delivery whose effect is unknown")
    func refusalAfterAnEarlierGesture() async {
        let actuator = RecordingActuator()
        actuator.failure = GestureNotSent(reason: "endpoint_refused", sentence: "No control.")
        actuator.failsFrom = 1
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X",
                                  input: .pressKey(KeyChord(.return), times: 2)))
        #expect(actuator.gestures.count == 1)
        #expect(outcome.kind == .actedUnverified, "the first Return went out: its effect is unknown")
        #expect(outcome.message.contains("delivery failed"))
    }

    @Test("a key that changed nothing in a file panel the system draws bounds the retries and says when to stop")
    func aKeyWithNoEffectInAFilePanelAsksForAClick() async {
        let goTo = InputRequest(processID: pid, bundleID: "com.x", appName: "X",
                                input: .pressKey(KeyChord(.character("g"), modifiers: [.command, .shift]), times: 1))
        let panel = await engine(scenes: ScriptedScenes([scene([export]), scene([export])]),
                                 permissions: ActionPermissions(selectsFieldsByTripleClick: true)).deliver(goTo)
        #expect(panel.message.contains("this window did NOT change"), "\(panel.message)")
        #expect(panel.message.contains("Press it at most once more") && panel.message.contains("that way is closed"))
        let window = await engine(scenes: ScriptedScenes([scene([export]), scene([export])])).deliver(goTo)
        #expect(window.message.contains("observe the window") && !window.message.contains("click the control"))
        #expect(!window.message.contains("name field"))
    }

    /// An actuator that refuses from its nth gesture on, before sending it, as `MacActuator` does once the
    /// person touched the app (`MacActuationFailure.personActed` leaves it as `GestureNotSent`).
    final class RefusingActuator: Actuating, @unchecked Sendable {
        static let personActed = GestureNotSent(reason: "person_acted", sentence: "The person changed the app; read it again.")
        let refusesFrom: Int
        var attempts = 0
        var gestures: [Gesture] = []
        init(refusesFrom: Int) { self.refusesFrom = refusesFrom }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            attempts += 1
            if attempts >= refusesFrom { throw Self.personActed }
            gestures.append(gesture)
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    @Test("a timecode that ticks during a click is no effect on the Seat; a source that reads displays asks for it")
    func aTickingTextIsNoEffectByDefault() async {
        var clock = SceneElement(id: "text|clock", kind: .text, label: "00:00:01:12", bounds: rect(0.4, 0.05))
        clock.value = "00:00:01:12"
        var later = clock
        later.label = "00:00:01:19"
        later.value = "00:00:01:19"
        let seat = await engine(scenes: ScriptedScenes([scene([export, clock]), scene([export, later])])).act(request("Export"))
        #expect(seat.kind != .foundActed, Comment(rawValue: seat.message))
        let displays = ActionEngine(ActionEngine.Dependencies(
            scenes: ScriptedScenes([scene([export, clock]), scene([export, later])]), actuator: RecordingActuator(),
            windows: ScriptedWindows([[mainWindow]]), countsNativeTextChange: true
        ), pause: { _ in })
        let driver = await displays.act(request("Export"))
        #expect(driver.kind == .foundActed, Comment(rawValue: driver.message))
    }

    @Test("W1: a secure field is never read back: no value in the outcome or the check, which says so")
    func secureFieldIsNeverReadBack() async throws {
        let sentinel = "Prefilled-Secret-4417"
        let secure = SceneElement(id: "field|access", kind: .control, label: "Accesso", bounds: rect(0.2, 0.2),
                                  role: "AXSecureTextField")
        // A reader that failed to protect it would still answer the value: the engine does not ask.
        let controls = FakeControls()
        controls.focused = sentinel
        let outcome = await engine(scenes: ScriptedScenes([scene([secure]), scene([secure])]), controls: controls)
            .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X",
                                  input: .typeText("typed-word", into: "Accesso", replacing: true)))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(!outcome.message.contains(sentinel) && !outcome.message.contains("typed-word"),
                Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .unknown)
        #expect(check.expected == nil && check.observed == nil)
        #expect(check.limits.contains(.readbackUnavailable) && check.limits.contains(.valueWithheld))
    }

    @Test("the person first: a refusal before any gesture is refused with its reason, never retried")
    func personActedBeforeGesture() async {
        let actuator = RefusingActuator(refusesFrom: 1)
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes: ScriptedScenes([scene([export])]), actuator: actuator, windows: ScriptedWindows([[mainWindow]])
        ), pause: { _ in })
        let outcome = await engine.act(request("Export"))
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("nothing was sent. The person changed the app; read it again."))
        #expect(outcome.check?.performed == OperationCheck.Performed.none)
        #expect(actuator.attempts == 1, "no retry")
    }

    @Test("the person first: a refusal after part of an input went out stays uncertain and says why")
    func personActedMidInput() async {
        let field = SceneElement(id: "field|name", kind: .control, label: "Name", bounds: rect(0.2, 0.2), role: "AXTextField")
        let actuator = RefusingActuator(refusesFrom: 2)
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes: ScriptedScenes([scene([field])]), actuator: actuator, windows: ScriptedWindows([[mainWindow]])
        ), pause: { _ in })
        let outcome = await engine.deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X",
                                                        input: .typeText("Braus", into: "Name", replacing: false)))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("delivery failed"), Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("The person changed the app; read it again."), Comment(rawValue: outcome.message))
        #expect(actuator.gestures.count == 1)
        #expect(actuator.attempts == 2, "no retry")
    }

    // MARK: set_toggle

    @Test("set_toggle refuses indefinite initial states before clicks, menu substitutes or dry-run plans",
          arguments: [nil, .unknown, .mixed] as [ControlState?])
    func setToggleNeedsKnownInitialState(state: ControlState?) async {
        for fixture in [toggleOff, boldOff] {
            var element = fixture
            element.state = state
            for desired in [ControlState.on, .off] {
                for dryRun in [false, true] {
                    let before = scene([element])
                    let actuator = RecordingActuator()
                    let observer = RecordingObserver()
                    let menus = FakeMenus(answer: menuPressed("Format > Font > Bold"))
                    let settling = SettlingTests.RecordingSettling()
                    let subject = engine(
                        scenes: ScriptedScenes([before]),
                        actuator: actuator,
                        observer: observer,
                        menus: menus,
                        settling: settling
                    )
                    for _ in 0..<2 {
                        let outcome = await subject.act(request(
                            element.label,
                            verb: .setToggle,
                            desired: desired,
                            dryRun: dryRun
                        ))
                        #expect(outcome.kind == .refused)
                        #expect(outcome.message.contains("Nothing was sent"))
                        #expect(outcome.check?.performed == OperationCheck.Performed.none)
                        #expect(outcome.check?.verdict == .unknown)
                    }
                    #expect(actuator.gestures.isEmpty)
                    #expect(actuator.confirmations.isEmpty)
                    #expect(menus.pressed.isEmpty)
                    #expect(settling.prepares.isEmpty && settling.waits.isEmpty)
                    #expect(observer.records.count == 2)
                    #expect(observer.records.allSatisfy {
                        $0.attempt == .notAttempted(reason: "initial_toggle_state_not_definite")
                            && $0.effect == nil && $0.before == before && $0.after == nil
                    })
                }
            }
        }
    }

    @Test("an indefinite native toggle state overrides a stale definite scene",
          arguments: [ControlState.unknown, .mixed])
    func setToggleRefusesIndefiniteNativeState(state: ControlState) async {
        for element in [toggleOff, toggleOn, boldOff, boldOn] {
            for desired in [ControlState.on, .off] {
                let actuator = RecordingActuator()
                let controls = FakeControls()
                controls.labelledToggle = state
                let menus = FakeMenus(answer: menuPressed("Format > Font > Bold"))
                let outcome = await engine(
                    scenes: ScriptedScenes([scene([element])]),
                    actuator: actuator,
                    controls: controls,
                    menus: menus
                ).act(request(element.label, verb: .setToggle, desired: desired))
                #expect(outcome.kind == .refused)
                #expect(controls.labelledReads == [element.label])
                #expect(actuator.gestures.isEmpty && menus.pressed.isEmpty)
            }
        }
    }

    @Test("known toggle states preserve no-op, one-click read-back and dry-run behavior")
    func setToggleKeepsKnownTransitions() async {
        for initial in [ControlState.on, .off] {
            for desired in [ControlState.on, .off] {
                for dryRun in [false, true] {
                    var before = toggleOff
                    before.state = initial
                    var after = before
                    after.state = desired
                    let actuator = RecordingActuator()
                    let outcome = await engine(
                        scenes: ScriptedScenes([scene([before]), scene([after])]),
                        actuator: actuator
                    ).act(request(before.label, verb: .setToggle, desired: desired, dryRun: dryRun))
                    let needsClick = initial != desired
                    #expect(outcome.kind == (!needsClick ? .actedNoop : dryRun ? .dryRun : .foundActed))
                    #expect(actuator.gestures.count == (needsClick && !dryRun ? 1 : 0))
                    if !dryRun || !needsClick {
                        #expect(outcome.check?.verdict == .passed)
                        #expect(outcome.check?.observed == desired.rawValue)
                    }
                }
            }
        }
    }

    @Test("an indefinite scoped toggle cannot borrow another container's state")
    func setToggleUnknownKeepsContainer() async {
        var target = boldOff
        target.state = nil
        target.container = "Target"
        var other = boldOn
        other.container = "Other"
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.labelledToggle = .on
        let menus = FakeMenus(answer: menuPressed("Format > Font > Bold"))
        let outcome = await engine(
            scenes: ScriptedScenes([scene([target, other])]),
            actuator: actuator,
            controls: controls,
            menus: menus
        ).act(request(target.label, verb: .setToggle, section: "Target", desired: .on))
        #expect(outcome.kind == .refused)
        #expect(controls.labelledReads.isEmpty)
        #expect(actuator.gestures.isEmpty && menus.pressed.isEmpty)
    }

    @Test("an unverified toggle is not repeated when the next initial state is unavailable",
          arguments: [false, true])
    func setToggleDoesNotRepeatUnverifiedGesture(deliveryFailed: Bool) async {
        var unreadable = toggleOff
        unreadable.state = nil
        let actuator = RecordingActuator()
        if deliveryFailed { actuator.failure = Unavailable() }
        let observer = RecordingObserver()
        let subject = engine(
            scenes: ScriptedScenes([scene([toggleOff]), scene([unreadable])]),
            actuator: actuator,
            observer: observer
        )
        let first = await subject.act(request(toggleOff.label, verb: .setToggle, desired: .on))
        #expect(first.kind == .actedUnverified)
        #expect(first.check?.verdict == .unknown)
        let gestures = actuator.gestures.count
        let confirmations = actuator.confirmations.count
        let second = await subject.act(request(toggleOff.label, verb: .setToggle, desired: .on))
        #expect(second.kind == .refused)
        #expect(actuator.gestures.count == gestures)
        #expect(actuator.confirmations.count == confirmations)
        #expect(observer.records.last?.attempt == .notAttempted(reason: "initial_toggle_state_not_definite"))
    }

    @Test("set_toggle is idempotent, needs a state, and verifies the read-back")
    func setToggle() async {
        let already = await engine(scenes: ScriptedScenes([scene([toggleOff])])).act(request("Facebook", verb: .setToggle, desired: .off))
        #expect(already.kind == .actedNoop)
        let noState = await engine(scenes: ScriptedScenes([scene([toggleOff])])).act(request("Facebook", verb: .setToggle))
        #expect(noState.kind == .refused)
        let flipped = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOn])]), controls: FakeControls(toggle: .on))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(flipped.kind == .foundActed)
        #expect(flipped.message == "set 'Facebook' → on")
        let stuck = await engine(scenes: ScriptedScenes([scene([toggleOff]), scene([toggleOff])]), controls: FakeControls(toggle: .off))
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(stuck.kind == .actedUnverified)
        #expect(stuck.message.contains("now reads 'off'"))
    }

    @Test("set_toggle reads the control itself before deciding, so a stale scene never flips it back")
    func setToggleReadsTheControlFirst() async {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.labelledToggle = .on
        let already = await engine(scenes: ScriptedScenes([scene([toggleOff])]), actuator: actuator, controls: controls)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(already.kind == .actedNoop)
        #expect(actuator.gestures.isEmpty, "the control already reads on: no click")
        #expect(controls.labelledReads == ["Facebook"])
        #expect(already.check?.observed == "on")

        controls.labelledToggle = .off
        let clicking = RecordingActuator()
        let flipped = await engine(scenes: ScriptedScenes([scene([toggleOn]), scene([toggleOn])]), actuator: clicking,
                                   controls: controls)
            .act(request("Facebook", verb: .setToggle, desired: .on))
        #expect(clicking.gestures.count == 1, "the scene said on but the control reads off: one click")
        #expect(flipped.kind == .actedUnverified, "the read-back still answers off from the control")
    }

    @Test("toggle readback stays in the selected container when control IDs repeat",
          arguments: [false, true])
    func toggleReadbackKeepsContainer(targetDisappears: Bool) async {
        let other = SceneElement(id: "control|mute", kind: .control, label: "Mute", bounds: rect(0.2, 0.2),
                                 state: targetDisappears ? .on : .off, container: "DRUMS BUS")
        let kick = SceneElement(id: "control|mute", kind: .control, label: "Mute", bounds: rect(0.4, 0.2),
                                state: .off, container: "Kick")
        var changed = kick
        changed.state = .on
        changed.bounds = rect(0.6, 0.2)
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes: ScriptedScenes([scene([other, kick]), scene(targetDisappears ? [other] : [other, changed])]),
            actuator: actuator
        ).act(request("Mute", verb: .setToggle, section: "Kick", desired: .on))
        #expect(actuator.gestures.count == 1)
        #expect(outcome.kind == (targetDisappears ? .actedUnverified : .foundActed))
        #expect(outcome.check?.observed == (targetDisappears ? nil : "on"))
    }

    @Test("a label-only toggle read cannot override a selected container")
    func toggleLabelReadDoesNotCrossContainers() async {
        let kick = SceneElement(id: "control|mute", kind: .control, label: "Mute", bounds: rect(0.4, 0.2),
                                state: .off, container: "Kick")
        var changed = kick
        changed.state = .on
        let controls = FakeControls()
        controls.labelledToggle = .on
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([kick]), scene([changed])]),
                                   actuator: actuator, controls: controls)
            .act(request("Mute", verb: .setToggle, section: "Kick", desired: .on))
        #expect(outcome.kind == .foundActed)
        #expect(actuator.gestures.count == 1)
        #expect(controls.labelledReads.isEmpty)
    }

    // MARK: Pop-ups

    private var listScene: PerceivedWindow {
        // A two-row list at 300,300 (220×56) over the 1000×800 window at 100,100.
        func row(_ id: String, _ label: String, y: CGFloat) -> SceneElement {
            SceneElement(id: id, kind: .text, label: label, bounds: NormalizedRect(
                x: (320.0 - 100.0) / 1000.0, y: Double((y - 100) / 800), width: 0.05, height: 14.0 / 800.0))
        }
        return scene([export, row("text|48000", "48000", y: 307), row("text|96000", "96000", y: 335)])
    }

    @Test("a target inside an open pop-up is picked by keyboard and verified by the control's value")
    func popupKeyboardPick() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(values: ["48000", "96000"])
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator,
                                   windows: ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("keyboard 1↓ + Return"))
        #expect(actuator.gestures == [.key(code: Key.downArrow), .key(code: Key.return)])
    }

    @Test("an item of an open native menu is pressed by its title, with no key, and the menu's closing verifies it")
    func popupNativeItemIsPressed() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.menuItemPresses = true
        let windows = ScriptedWindows([[popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator,
                                   windows: windows, controls: controls)
            .act(request("96000"))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(controls.pressedMenuItems.map(\.title) == ["96000"])
        #expect(controls.pressedMenuItems.first?.frame == popupWindow.frame)
        #expect(actuator.gestures.isEmpty, "no key reaches a window whose focus nobody can read")

        // Still open after the press: the effect is unknown, and nothing is pressed or typed again.
        let again = RecordingActuator()
        let stays = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: again,
                                 windows: ScriptedWindows([[popupWindow, mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(stays.kind == .actedUnverified)
        #expect(again.gestures.isEmpty)
    }

    /// Finder's Compress, chosen by type-ahead on 06/10/2026, did nothing while the engine said it was
    /// selected: a menu that closes after typed keys proves only that it closed.
    @Test("without a readable control the pick falls back to type-ahead, commits only while open, and claims no effect")
    func popupTypeAhead() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator, windows: windows).act(request("96000"))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("type-ahead"))
        #expect(outcome.message.contains("the menu closed but the effect is not confirmed; observe"))
        #expect(actuator.confirmations.last == .unknown, "a closed menu is not the item's effect")
        #expect(actuator.gestures == [.type("96000"), .key(code: Key.rightArrow), .key(code: Key.return)])
    }

    @Test("an OCR label absent from a readable native menu is never typed or pressed")
    func unmatchedNativeMenuItemDoesNotType() async {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.menuItemPresses = true
        controls.submenu = MenuItemNavigation(hasSubmenu: false, row: nil, submenuFrame: nil, hasMatchingItem: false)
        let outcome = await engine(
            scenes: ScriptedScenes([listScene]), actuator: actuator,
            windows: ScriptedWindows([[popupWindow, mainWindow]]), controls: controls
        ).act(request("96000"))
        #expect(outcome.kind == .honestMiss)
        #expect(actuator.gestures.isEmpty)
        #expect(controls.pressedMenuItems.isEmpty)
    }

    @Test("a native submenu parent is entered without pressing or committing it", arguments: [false, true])
    func submenuDoesNotCommit(opens: Bool) async {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.menuItemPresses = true
        let child = WindowRow(layer: 101, frame: CGRect(x: 520, y: 300, width: 180, height: 150), title: nil, number: 10)
        controls.submenu = MenuItemNavigation(hasSubmenu: true, row: 1, submenuFrame: child.frame)
        let initial = [popupWindow, mainWindow]
        let after = opens ? [child, popupWindow, mainWindow] : initial
        let outcome = await engine(
            scenes: ScriptedScenes([listScene]), actuator: actuator,
            windows: ScriptedWindows([initial, initial, after]), controls: controls
        ).act(request("96000"))
        #expect(controls.pressedMenuItems.isEmpty)
        #expect(actuator.gestures == [.key(code: Key.home), .key(code: Key.downArrow), .key(code: Key.rightArrow)])
        #expect(outcome.kind == (opens ? .foundActed : .actedUnverified))
        #expect(outcome.check?.condition == .submenuOpened)
        #expect(outcome.check?.verdict == (opens ? .passed : .unknown))
    }

    @Test("submenu navigation refuses an unreadable row and does not credit an unrelated popup")
    func submenuIdentity() async {
        let controls = FakeControls()
        let actuator = RecordingActuator()
        controls.submenu = MenuItemNavigation(hasSubmenu: true, row: nil, submenuFrame: nil)
        let refused = await engine(scenes: ScriptedScenes([listScene]), actuator: actuator,
                                   windows: ScriptedWindows([[popupWindow, mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(refused.kind == .honestMiss)
        #expect(actuator.gestures.isEmpty)
        #expect(controls.pressedMenuItems.isEmpty)

        let other = WindowRow(layer: 101, frame: CGRect(x: 520, y: 300, width: 180, height: 150), title: nil, number: 10)
        controls.submenu = MenuItemNavigation(hasSubmenu: true, row: 1, submenuFrame: .zero)
        let uncertain = await engine(scenes: ScriptedScenes([listScene]), actuator: actuator,
                                     windows: ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow],
                                                               [other, popupWindow, mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(uncertain.kind == .actedUnverified)
        #expect(uncertain.check?.verdict == .unknown)
        #expect(!actuator.gestures.contains(.key(code: Key.return)))
        #expect(controls.pressedMenuItems.isEmpty)
    }

    @Test("an open submenu is not navigated again and a partial key sequence is not reported unsent")
    func submenuAlreadyOpenAndInterrupted() async {
        let controls = FakeControls()
        let actuator = RecordingActuator()
        let child = WindowRow(layer: 101, frame: CGRect(x: 520, y: 300, width: 180, height: 150), title: nil, number: 10)
        controls.submenu = MenuItemNavigation(hasSubmenu: true, row: 1, submenuFrame: child.frame)
        let already = await engine(scenes: ScriptedScenes([listScene]), actuator: actuator,
                                   windows: ScriptedWindows([[child, popupWindow, mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(already.kind == .actedNoop)
        #expect(actuator.gestures.isEmpty)
        actuator.failure = GestureNotSent(reason: "changed", sentence: "The window changed")
        actuator.failsFrom = 1
        let interrupted = await engine(scenes: ScriptedScenes([listScene]), actuator: actuator,
                                       windows: ScriptedWindows([[popupWindow, mainWindow]]), controls: controls)
            .act(request("96000"))
        #expect(interrupted.kind == .actedUnverified)
        #expect(actuator.gestures == [.key(code: Key.home)])
        #expect(controls.pressedMenuItems.isEmpty)
    }

    @Test("a target outside an open pop-up closes it first and says so")
    func popupOutside() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([listScene, scene([export])]), actuator: actuator,
                                   windows: ScriptedWindows([[popupWindow, mainWindow], [mainWindow]])).act(request("Export"))
        #expect(outcome.kind == .actedNoop)
        #expect(outcome.message.contains("closed the menu"))
        #expect(actuator.gestures == [.key(code: Key.escape)])
    }

    @Test("a menu still visible after Escape is reported unverified without clicking through", arguments: [false, true])
    func popupDismissalUnconfirmed(deliveryFails: Bool) async {
        let actuator = RecordingActuator()
        if deliveryFails { actuator.failure = Unavailable() }
        let outcome = await engine(
            scenes  : ScriptedScenes([listScene]),
            actuator: actuator,
            windows : ScriptedWindows([[popupWindow, mainWindow]])
        ).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("still open"))
        #expect(!outcome.message.contains("closed the menu"))
        #expect(!outcome.message.contains("again now"))
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures == (deliveryFails ? [] : [.key(code: Key.escape)]))
    }

    @Test("a failed window census cannot prove a menu was dismissed")
    func popupDismissalCensusUnavailable() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[popupWindow, mainWindow]])
        windows.readsUntilFailure = 1
        let outcome = await engine(
            scenes  : ScriptedScenes([listScene, scene([export])]),
            actuator: actuator,
            windows : windows
        ).act(request("Export"))
        #expect(outcome.kind == .actedUnverified)
        #expect(!outcome.message.contains("closed the menu"))
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures == [.key(code: Key.escape)])
    }

    // MARK: Observe

    @Test("describe and check_goal read the live scene")
    func observe() async {
        let engine = engine(scenes: ScriptedScenes([scene([export], title: "Export Settings")]))
        let described = await engine.describeScene(of: pid, appName: "X")
        #expect(described.message.contains("scene_token:"))
        let missing = await engine.describeSection(named: "nowhere", of: pid, appName: "X")
        #expect(missing.kind == .honestMiss)
        let verified = await engine.checkGoal(evidence: "export settings", of: pid, appName: "X")
        #expect(verified.kind == .foundActed)
        let unverified = await engine.checkGoal(evidence: "Render Queue", of: pid, appName: "X")
        #expect(unverified.kind == .refused)
        #expect(unverified.message.contains("does not show"))
    }

    @Test("in a remote file panel a click on a popup or a menu button is refused and nothing presses it",
          arguments: ["AXPopUpButton", "AXMenuButton"])
    func remotePanelMenuOpenerIsRefused(role: String) async {
        let popup = SceneElement(id: "control|where", kind: .control, label: "Where:", bounds: rect(0.3, 0.4),
                                 role: role, value: "Downloads")
        let controls = FakeControls(); controls.pressSucceeds = true
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([popup])]), actuator: actuator, controls: controls,
                                   permissions: ActionPermissions(refusesMenuOpeningClicks: true))
            .act(request("Where:"))
        #expect(outcome.kind == .refused)
        #expect(outcome.message == ActionPolicy.menuOpeningRefusal(role: role))
        #expect(outcome.message.contains("Use select"))
        #expect(controls.pressed.isEmpty, "the native press would open the service's menu")
        #expect(actuator.gestures.isEmpty)
    }

    @Test("in a remote file panel any other click goes to the seat, never to a native press by label")
    func remotePanelClickSkipsTheNativePress() async {
        let save = SceneElement(id: "control|save", kind: .control, label: "Save", bounds: rect(0.8, 0.9),
                                role: "AXButton")
        let controls = FakeControls(); controls.pressSucceeds = true
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([save])]), actuator: actuator, controls: controls,
                         permissions: ActionPermissions(refusesMenuOpeningClicks: true))
            .act(request("Save"))
        #expect(controls.pressed.isEmpty)
        #expect(actuator.gestures.count == 1)
    }

    /// Finder on 06/10/2026: a share popover's title and the file's list row, both `carla_video_bw`.
    @Test("a right click resolves the list row instead of a same-named title text")
    func rightClickPrefersTheRow() async {
        let title = SceneElement(id: "text|carlavideobw", kind: .text, label: "carla_video_bw",
                                 bounds: rect(0.30, 0.06))
        let row = SceneElement(id: "control|carlavideobw", kind: .control, label: "carla_video_bw",
                               bounds: rect(0.22, 0.24), role: "AXRow", container: "list view")
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([title, row])]), actuator: actuator)
            .act(request("carla_video_bw", verb: .rightClick, dryRun: true))
        #expect(outcome.kind == .dryRun, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("370,300"), Comment(rawValue: outcome.message))
    }

    @Test("where menus open under the person's pointer, right_click is refused off a text field")
    func rightClickOutsideTheSeatIsRefused() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                   permissions: ActionPermissions(contextMenusOnTextFieldsOnly: true))
            .act(request("Export", verb: .rightClick))
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("use context_menu on the same element"), Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty)
    }
}
