//
//  WindowClosureTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// What the engine refuses once the broker says closing the target window may end its application:
/// Escape in any form, the window's own closing control and nothing else. Measured on 12/10/2026,
/// Escape on the Project Manager of DaVinci Resolve closes it and Resolve quits.
@Suite("Closing the only window of an application")
struct WindowClosureTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows

    // MARK: Fixtures

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                       title: "Project Manager", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56),
                                        title: nil, number: 9)

    private func button(_ label: String, x: Double, y: Double = 0.9) -> SceneElement {
        SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: y, width: 0.08, height: 0.03), role: "AXButton")
    }

    private func scene(_ elements: [SceneElement]) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "Project Manager",
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements
        ), frame: frame)
    }

    private var projectManager: [SceneElement] {
        [button("Open", x: 0.1), button("New Project", x: 0.3), button("Cancel", x: 0.7)]
    }

    private let atRisk = ActionPermissions(windowClosure: WindowClosureGuard(mayEndTheApplication: true))

    private func engine(
        _ elements : [SceneElement],
        actuator   : RecordingActuator = RecordingActuator(),
        windows    : ScriptedWindows? = nil,
        permissions: ActionPermissions
    ) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: ScriptedScenes([scene(elements)]), actuator: actuator,
                windows: windows ?? ScriptedWindows([[mainWindow]])
            ),
            permissions: permissions, pause: { _ in }
        )
    }

    private func press(_ chord: KeyChord, times: Int = 1) -> InputRequest {
        InputRequest(processID: pid, bundleID: "com.x", appName: "DaVinci Resolve",
                     input: .pressKey(chord, times: times))
    }

    private func act(_ target: String) -> ActionRequest {
        ActionRequest(processID: pid, bundleID: "com.x", appName: "DaVinci Resolve", target: target,
                      verb: .click, section: nil, desiredState: nil)
    }

    // MARK: Escape

    @Test("Escape is refused before any event, whatever modifiers and count, and the sentence names real controls",
          arguments: [
              (KeyChord.Name.escape, KeyModifiers(), 1),
              (KeyChord.Name.escape, KeyModifiers(), 5),
              (KeyChord.Name.escape, KeyModifiers.shift, 1),
              (KeyChord.Name.escape, KeyModifiers([.command, .option]), 2),
          ])
    func escapeIsRefused(key: KeyChord.Name, modifiers: KeyModifiers, times: Int) async {
        let actuator = RecordingActuator()
        let outcome = await engine(projectManager, actuator: actuator, permissions: atRisk)
            .deliver(press(KeyChord(key, modifiers: modifiers), times: times))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty)
        #expect(actuator.confirmations.isEmpty)
        #expect(outcome.message.first?.isUppercase == true, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("'Project Manager', the only window of DaVinci Resolve"))
        #expect(outcome.message.contains("Nothing was sent"))
        #expect(outcome.message.contains("(Open, New Project)"))
        #expect(!outcome.message.contains("Cancel"), "a Cancel the window has is not an alternative")
    }

    @Test("without controls to name, the sentence offers none and never invents a Cancel")
    func noControlsToName() async {
        let outcome = await engine([], permissions: atRisk)
            .deliver(press(KeyChord(.escape)))
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("a control of the window by name"))
        #expect(!outcome.message.contains("Cancel"))
    }

    @Test("Escape is not refused when the window is not at risk, when the person allowed it or in a dismissal")
    func escapeGoesOut() async {
        let key = Gesture.key(code: Key.escape)
        let editor = RecordingActuator()
        _ = await engine(projectManager, actuator: editor, permissions: ActionPermissions())
            .deliver(press(KeyChord(.escape)))
        #expect(editor.gestures == [key])

        let allowed = RecordingActuator()
        let permissions = ActionPermissions(
            allowsDestructive: true, windowClosure: WindowClosureGuard(mayEndTheApplication: true)
        )
        _ = await engine(projectManager, actuator: allowed, permissions: permissions)
            .deliver(press(KeyChord(.escape)))
        #expect(allowed.gestures == [key])

        let popup = RecordingActuator()
        _ = await engine(
            projectManager, actuator: popup,
            windows: ScriptedWindows([[popupWindow, mainWindow]]), permissions: atRisk
        ).deliver(press(KeyChord(.escape)))
        #expect(popup.gestures == [key], "an open pop-up is what Escape closes")
    }

    @Test("other keys are not refused for the same window")
    func otherKeysGoOut() async {
        let actuator = RecordingActuator()
        _ = await engine(projectManager, actuator: actuator, permissions: atRisk)
            .deliver(press(KeyChord(.return)))
        #expect(actuator.gestures == [.key(code: Key.return)])
    }

    // MARK: Text that carries a key

    private let nameField = SceneElement(
        id: "control|name", kind: .control, label: "Project Name",
        bounds: NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.03), role: "AXTextField", value: ""
    )

    private func text(_ text: String, insert: Bool) -> InputRequest {
        InputRequest(processID: pid, bundleID: "com.x", appName: "DaVinci Resolve", input: insert
            ? .insertText(text, expecting: nil)
            : .typeText(text, into: "Project Name", replacing: true))
    }

    @Test("text with a control character is refused before any event, with the rule on or off", arguments: [
        "\u{1B}", "Braus\u{1B}", "\u{1B}[A", "a\u{0}b", "\u{7}", "\u{8}", "\u{1F}",
    ])
    func controlCharactersAreRefused(text value: String) async {
        for permissions in [atRisk, ActionPermissions(), ActionPermissions(allowsDestructive: true)] {
            for insert in [true, false] {
                let actuator = RecordingActuator()
                let outcome = await engine([nameField], actuator: actuator, permissions: permissions)
                    .deliver(text(value, insert: insert))
                #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
                #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
                #expect(actuator.gestures.isEmpty)
            }
        }
    }

    @Test("tabs and line breaks are text and still go out", arguments: ["a\tb", "one\ntwo", "one\r\ntwo", "\r"])
    func tabsAndLineBreaksGoOut(text value: String) async {
        for insert in [true, false] {
            let actuator = RecordingActuator()
            _ = await engine([nameField], actuator: actuator, permissions: atRisk)
                .deliver(text(value, insert: insert))
            #expect(!actuator.gestures.isEmpty, Comment(rawValue: value))
        }
    }

    // MARK: Closing controls

    @Test("the window's own closing control is refused by its name, exactly", arguments: [
        "Cancel", "cancel", "Close", "Annulla", "Chiudi", "Cancel...",
    ])
    func closingLabelIsRefused(label: String) async {
        let actuator = RecordingActuator()
        let outcome = await engine([button("Open", x: 0.1), button(label, x: 0.7)], actuator: actuator,
                                   permissions: atRisk).act(act(label))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("Clicking '\(label)' would close"))
        #expect(outcome.message.contains("(Open)"))
        #expect(actuator.gestures.isEmpty)
    }

    @Test("a control whose name only contains a closing word is clicked", arguments: [
        "Cancel download", "Close sidebar", "Disclose",
    ])
    func similarLabelIsNotRefused(label: String) async {
        let actuator = RecordingActuator()
        let outcome = await engine([button(label, x: 0.7)], actuator: actuator, permissions: atRisk)
            .act(act(label))
        #expect(
            outcome.kind != .refused || !outcome.message.contains("would close"),
            Comment(rawValue: outcome.message)
        )
        #expect(!actuator.gestures.isEmpty)
    }

    @Test("a control that is the window's AXCancelButton or AXCloseButton is refused whatever its name")
    func closingControlByIdentity() async {
        // The button below is centred at 100 + 0.74 * 1000 = 840, 100 + 0.915 * 800 = 832.
        let frames = [CGRect(x: 820, y: 820, width: 40, height: 24)]
        let guardian = WindowClosureGuard(mayEndTheApplication: true, controlFrames: frames)
        let actuator = RecordingActuator()
        let outcome = await engine(
            [button("Go back", x: 0.7)], actuator: actuator,
            permissions: ActionPermissions(windowClosure: guardian)
        ).act(act("Go back"))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty)

        let elsewhere = WindowClosureGuard(
            mayEndTheApplication: true, controlFrames: [CGRect(x: 0, y: 0, width: 20, height: 20)]
        )
        let clicked = RecordingActuator()
        _ = await engine(
            [button("Go back", x: 0.7)], actuator: clicked,
            permissions: ActionPermissions(windowClosure: elsewhere)
        ).act(act("Go back"))
        #expect(!clicked.gestures.isEmpty)
    }

    @Test("a closing control is clicked when the window is not at risk or the person allowed it")
    func closingControlGoesOut() async {
        let normal = RecordingActuator()
        _ = await engine([button("Cancel", x: 0.7)], actuator: normal, permissions: ActionPermissions())
            .act(act("Cancel"))
        #expect(!normal.gestures.isEmpty)

        let allowed = RecordingActuator()
        let permissions = ActionPermissions(
            allowsDestructive: true, windowClosure: WindowClosureGuard(mayEndTheApplication: true)
        )
        _ = await engine([button("Cancel", x: 0.7)], actuator: allowed, permissions: permissions)
            .act(act("Cancel"))
        #expect(!allowed.gestures.isEmpty)
    }

    @Test("a name the window does not have stays an ordinary miss")
    func missingControlIsAMiss() async {
        let actuator = RecordingActuator()
        let outcome = await engine(Array(projectManager.dropLast()), actuator: actuator, permissions: atRisk)
            .act(act("Cancel"))
        #expect(outcome.kind == .honestMiss, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty)
    }

    @Test("a batch step is the same delivery and is refused the same way")
    func batchStepIsRefused() async {
        // The batch tool calls deliver() once per step, so one step is one call.
        let actuator = RecordingActuator()
        let engine = engine(projectManager, actuator: actuator, permissions: atRisk)
        let first = await engine.deliver(press(KeyChord(.escape)))
        let second = await engine.deliver(press(KeyChord(.escape)))
        #expect(first.kind == .refused && second.kind == .refused)
        #expect(actuator.gestures.isEmpty)
    }

    @Test("Command-Q and Command-W stay refused with the person's permission and the rule off")
    func quitStaysRefused() async {
        let actuator = RecordingActuator()
        for chord in [KeyChord(.character("q"), modifiers: .command), KeyChord(.character("w"), modifiers: .command)] {
            let outcome = await engine(projectManager, actuator: actuator,
                                       permissions: ActionPermissions(allowsDestructive: true))
                .deliver(press(chord))
            #expect(outcome.kind == .refused)
        }
        #expect(actuator.gestures.isEmpty)
    }

    @Test("permissions encoded before the rule existed decode with it off, and the rule round-trips")
    func permissionsRoundTrip() throws {
        let older = try JSONDecoder().decode(ActionPermissions.self, from: Data(#"{"allowsDestructive":false}"#.utf8))
        #expect(older.windowClosure == WindowClosureGuard())
        let rule = ActionPermissions(windowClosure: WindowClosureGuard(
            mayEndTheApplication: true, controlFrames: [CGRect(x: 1, y: 2, width: 3, height: 4)]
        ))
        #expect(try JSONDecoder().decode(ActionPermissions.self, from: JSONEncoder().encode(rule)) == rule)
    }
}
