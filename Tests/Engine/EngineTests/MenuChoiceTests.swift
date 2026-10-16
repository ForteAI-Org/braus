//
//  MenuChoiceTests.swift
//  Braus
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// W2, W3: choosing an item of an open menu by the element the scene showed, and judging it by the conformer's
/// receipt (`MenuItemPress`), never by the menu's closing alone. Over the act cycle's doubles.
@Suite("Menu choice receipts (W2, W3)")
struct MenuChoiceTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls
    typealias RecordingObserver = ActionEngineTests.RecordingObserver

    private let pid: pid_t = 4242
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Form", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56), title: nil, number: 9)

    private func row(_ id: String, _ label: String, y: CGFloat) -> SceneElement {
        SceneElement(id: id, kind: .control, label: label, bounds: NormalizedRect(
            x: (320.0 - 100.0) / 1000.0, y: Double((y - 100) / 800), width: 0.05, height: 14.0 / 800.0), role: "AXMenuItem")
    }

    private func scene(_ elements: [SceneElement]) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "web:fixture.test", appName: "fixture.test", windowTitle: "Form",
                                             viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                                             elements: elements), frame: frame)
    }

    private var listScene: PerceivedWindow {
        scene([row("control|blue", "Blue", y: 307), row("control|blue-2", "Blue #2", y: 335)])
    }

    private func choose(_ receipt: MenuItemPress, values: [String?] = ["Blue", "Blue"],
                        observer: RecordingObserver? = nil) async -> (ActOutcome, RecordingActuator, FakeControls) {
        let actuator = RecordingActuator()
        let controls = FakeControls(values: values)
        controls.choice = receipt
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes: ScriptedScenes([listScene, scene([])]), actuator: actuator,
            windows: ScriptedWindows([[popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]]),
            controls: controls, observer: observer
        ), pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: pid, bundleID: "web:fixture.test", appName: "fixture.test",
                                                     target: "Blue #2", verb: .click))
        return (outcome, actuator, controls)
    }

    @Test("the conformer is given the element the scene showed, not its title stripped of its ordinal")
    func theElementIsGiven() async {
        let (_, _, controls) = await choose(.sent(.confirmed(expected: "Blue", observed: "Blue")))
        #expect(controls.chosenItems.map(\.id) == ["control|blue-2"], "\(controls.chosenItems.map(\.id))")
    }

    @Test("refused: nothing is sent, no key tries another way, the record says not attempted")
    func refused() async {
        let observer = RecordingObserver()
        let (outcome, actuator, _) = await choose(.refused("the list's options changed since it was read"), observer: observer)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty, "no keyboard fallback: \(actuator.gestures)")
        if case .notAttempted? = observer.records.last?.attempt {} else { Issue.record("\(String(describing: observer.records.last?.attempt))") }
    }

    @Test("confirmed after settling: found and acted, the value read back passes")
    func confirmed() async throws {
        let (outcome, actuator, _) = await choose(.sent(.confirmed(expected: "Blue", observed: "Blue")))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.condition == .valueReadBack && check.verdict == .passed && check.observed == "Blue")
        #expect(actuator.gestures.isEmpty)
    }

    @Test("contradicted, the page put the value back: not found and acted, the check fails, nothing is replayed")
    func contradicted() async throws {
        let (outcome, actuator, _) = await choose(.sent(.contradicted(expected: "Blue", observed: "Red")))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .failed && check.expected == "Blue" && check.observed == "Red")
        #expect(actuator.gestures.isEmpty, "no replay: \(actuator.gestures)")
    }

    @Test("applied but unread before the deadline: unverified, the check unknown, nothing replayed")
    func unread() async throws {
        let (outcome, actuator, _) = await choose(.sent(.unread(expected: "Blue", reason: "the page did not answer in time")))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .unknown && check.limits.contains(.readbackUnavailable) && check.performed == .requested)
        #expect(actuator.gestures.isEmpty)
    }

    @Test("possibly sent (a timeout, a disconnection): an uncertain delivery, recorded failed, never retried")
    func possiblySent() async throws {
        let observer = RecordingObserver()
        let (outcome, actuator, _) = await choose(.possiblySent("the page did not answer the choice"), observer: observer)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .unknown && check.performed == .uncertain && check.limits.contains(.deliveryUncertain))
        #expect(actuator.gestures.isEmpty)
        if case .deliveryFailed? = observer.records.last?.attempt {} else { Issue.record("\(String(describing: observer.records.last?.attempt))") }
    }

    @Test("not handled: the engine's other ways, as before (here the keyboard, verified by the control's value)")
    func notHandled() async {
        let (outcome, actuator, _) = await choose(.notHandled, values: ["Blue", "Blue #2"])
        #expect(!actuator.gestures.isEmpty, "the keyboard tried, as before: \(outcome.message)")
    }
}
