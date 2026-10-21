//
//  InputDeliveryTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// The inputs beyond a click over the act cycle's own doubles: what goes out, in which order, and
/// which outcome the reading afterwards earns. No screen, no sleep.
@Suite("Input delivery")
struct InputDeliveryTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls
    typealias FakeActivation    = ActionEngineTests.FakeActivation

    // MARK: Fixtures

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let pid: pid_t = 4242
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                       title: "Export", number: 1)
    private let popupWindow = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56),
                                        title: nil, number: 9)

    /// A text field centred at 500,432.
    private func field(value: String?, id: String = "control|name") -> SceneElement {
        SceneElement(id: id, kind: .control, label: "Project Name",
                     bounds: NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.03), role: "AXTextField",
                     value: value)
    }

    /// A line of text read from pixels, two hundredths of the window high.
    private func text(_ label: String, x: Double, y: Double, width: Double) -> SceneElement {
        SceneElement(id: "text|\(label)", kind: .text, label: label,
                     bounds: NormalizedRect(x: x, y: y, width: width, height: 0.02))
    }

    /// A row centred at 940,832.
    private let export = SceneElement(id: "control|export", kind: .control, label: "Export",
                                      bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.08, height: 0.03))

    private let trash = SceneElement(id: "control|trash", kind: .control, label: "Trash",
                                     bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.08, height: 0.03))

    private func scene(_ elements: [SceneElement], title: String = "Export", token: String? = nil) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: elements,
            token: token.map(SceneToken.init(rawValue:))
        ), frame: frame)
    }

    /// The window with a contextual menu of these rows open in the pop-up at 300,300.
    private func menuScene(_ labels: [String]) -> PerceivedWindow {
        let rows = labels.enumerated().map { index, label in
            SceneElement(id: "text|\(label.lowercased())", kind: .text, label: label, bounds: NormalizedRect(
                x: 0.22, y: Double(207 + 28 * index) / 800, width: 0.05, height: 14.0 / 800.0))
        }
        return scene([export] + rows)
    }

    private func request(_ input: InputRequest.Input, dryRun: Bool = false) -> InputRequest {
        InputRequest(processID: pid, bundleID: "com.x", appName: "X", input: input, isDryRun: dryRun)
    }

    private func engine(
        scenes     : ScriptedScenes,
        actuator   : RecordingActuator = RecordingActuator(),
        windows    : ScriptedWindows? = nil,
        controls   : FakeControls? = nil,
        activation : FakeActivation? = nil,
        permissions: ActionPermissions = ActionPermissions()
    ) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes: scenes, actuator: actuator, windows: windows ?? ScriptedWindows([[mainWindow]]),
                controls: controls, activation: activation
            ),
            permissions: permissions, pause: { _ in }
        )
    }

    private var fieldPoint: CGPoint { scene([]).globalPoint(of: field(value: nil)) }

    /// Where the engine aims at `export`: 940,832, give or take the last bit of a double.
    private var exportPoint: CGPoint { scene([]).globalPoint(of: export) }

    private let selectAll: [Gesture] = [
        .key(code: Key.upArrow, modifiers: .command),
        .key(code: Key.downArrow, modifiers: [.command, .shift]),
        .character("a", modifiers: .command),
    ]

    // MARK: type_text

    @Test("typing names its field when preparing the click")
    func typingBindsTheFieldLabel() async {
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([field(value: "Old")])]), actuator: actuator)
            .deliver(request(.typeText("New", into: "Project Name", replacing: true)))
        #expect(actuator.labels == ["Project Name"])
    }

    @Test("typing into a same-value native field uses its measured point rather than a version row")
    func textEntryUsesTheField() async {
        var name = field(value: "26.3")
        name.label = "26.3"
        let version = SceneElement(id: "version-row", kind: .control, label: "26.3",
                                   bounds: NormalizedRect(x: 0.27, y: 0.7, width: 0.1, height: 0.03))
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focused = "Braus Qt é 🧪"
        let outcome = await engine(scenes: ScriptedScenes([scene([version, name])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText("Braus Qt é 🧪", into: "26.3", replacing: true)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: fieldPoint)] + selectAll + [.insert("Braus Qt é 🧪")])
        #expect(actuator.confirmations == [.observed])

        var other = name
        other.id = "other-field"
        other.bounds.x = 0.7
        let ambiguous = RecordingActuator()
        let refusal = await engine(scenes: ScriptedScenes([scene([version, name, other])]), actuator: ambiguous)
            .deliver(request(.typeText("Braus Qt é 🧪", into: "26.3", replacing: true)))
        #expect(refusal.kind == .ambiguous)
        #expect(ambiguous.gestures.isEmpty)
    }

    @Test("replacing clicks the field, selects what it holds, types, and the value read back decides")
    func replaceIsVerifiedByTheValue() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "My Project"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message == "typed into 'Project Name': the field reads 'My Project'")
        #expect(actuator.gestures == [.click(at: fieldPoint)] + selectAll + [.type("My Project")])
        #expect(actuator.confirmations == [.observed])
    }

    @Test("an unreadable field is selected with a triple click, and one read as empty is only clicked, with no key")
    func replaceSendsNoKeyToAFieldItCannotRead() async {
        for (value, preparation) in [(nil, [Gesture.click(at: fieldPoint, count: 3)]),
                                     ("",  [Gesture.click(at: fieldPoint)])] as [(String?, [Gesture])] {
            let actuator = RecordingActuator()
            _ = await engine(scenes: ScriptedScenes([scene([field(value: value)])]), actuator: actuator)
                .deliver(request(.typeText("io la sto usando", into: "Project Name", replacing: true)))
            // Slack's empty composer reads as nothing, and an Up arrow there edits the last message.
            #expect(actuator.gestures == preparation + [.type("io la sto usando")])
        }
    }

    @Test("in a file panel the system draws, a field holding text is selected with a triple click and no key")
    func replaceInARemoteFilePanelSendsNoKey() async {
        let panel    = ActionPermissions(selectsFieldsByTripleClick: true)
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "braus-probe-a"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "Untitled-1")])]),
                                   actuator: actuator, controls: controls, permissions: panel)
            .deliver(request(.typeText("braus-probe-a", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: fieldPoint, count: 3), .type("braus-probe-a")])

        // Appending there still clicks and moves to the end, as everywhere else.
        let appending = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([field(value: "Budget")])]), actuator: appending,
                         permissions: panel)
            .deliver(request(.typeText(" 2027", into: "Project Name", replacing: false)))
        #expect(appending.gestures == [.click(at: fieldPoint), .key(code: Key.downArrow, modifiers: .command),
                                       .type(" 2027")])
    }

    @Test("in a file panel the system draws, a name replaced without an extension keeps the one it had")
    func replaceInARemoteFilePanelKeepsTheExtension() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "braus-ps-test.psd"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "Untitled-1.psd")])]),
                                   actuator: actuator, controls: controls,
                                   permissions: ActionPermissions(selectsFieldsByTripleClick: true))
            .deliver(request(.typeText("braus-ps-test", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message
            == "typed into 'Project Name' (kept the extension .psd): the field reads 'braus-ps-test.psd'")
        #expect(actuator.gestures == [.click(at: fieldPoint, count: 3), .type("braus-ps-test.psd")])

        // Anything else is typed as given, and nothing is added without the panel's rule.
        for (value, text, rule) in [("Untitled-1.psd", "report.pdf", true), ("Untitled-1.psd", "~/Desktop", true),
                                    ("Untitled-1.psd", "/tmp/x", true), ("Untitled-1", "braus-ps-test", true),
                                    ("Untitled-1.psd", "braus-ps-test", false)] {
            let plain = RecordingActuator()
            _ = await engine(scenes: ScriptedScenes([scene([field(value: value)])]), actuator: plain,
                             permissions: ActionPermissions(selectsFieldsByTripleClick: rule))
                .deliver(request(.typeText(text, into: "Project Name", replacing: true)))
            #expect(plain.gestures.last == .type(text), Comment(rawValue: "\(value) + \(text), rule \(rule)"))
        }
    }

    @Test("a value that is not the typed text is acted_unverified, and says what the field reads")
    func wrongValueIsUnverified() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "New Project 2My Project"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("reads 'New Project 2My Project', not 'My Project'"))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("without a focus reading the after-scene's value decides, and no value at all is unverified")
    func sceneValueIsTheFallback() async {
        let typed = await engine(scenes: ScriptedScenes([scene([field(value: "New Project 2")]),
                                                         scene([field(value: "My Project")])]))
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(typed.kind == .foundActed, Comment(rawValue: typed.message))
        let unread = await engine(scenes: ScriptedScenes([scene([field(value: nil)])]))
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true)))
        #expect(unread.kind == .actedUnverified)
        #expect(unread.message.contains("no field's value could be read"))
    }

    @Test("Pro Tools replaces a field without selection shortcuts or filename rewriting")
    func proToolsFieldSelection() async {
        let actuator = RecordingActuator()
        let result = await engine(
            scenes: ScriptedScenes([scene([field(value: "1.0")]), scene([field(value: "2")])]),
            actuator: actuator
        ).deliver(InputRequest(
            processID: pid, bundleID: "com.avid.ProTools", appName: "Pro Tools",
            input: .typeText("2", into: "Project Name", replacing: true)
        ))
        #expect(await actuator.gestures == [.click(at: fieldPoint, count: 3), .type("2")])
        #expect(result.kind == .foundActed)
    }

    @Test("a short text is typed a key pair per character and a long one is inserted on one event")
    func shortTypesLongInserts() async {
        for (count, inserts) in [(ActionEngine.typedTextLimit, false), (ActionEngine.typedTextLimit + 1, true)] {
            let text = String(repeating: "a", count: count)
            let actuator = RecordingActuator()
            _ = await engine(scenes: ScriptedScenes([scene([field(value: "")])]), actuator: actuator)
                .deliver(request(.typeText(text, into: "Project Name", replacing: true)))
            #expect(actuator.gestures.last == (inserts ? .insert(text) : .type(text)))
        }
    }

    @Test("supplementary Unicode and line breaks use one intact text payload", arguments: ["🧪", "Braus é 🧪", "Prima\nSeconda", "Prima\r\nSeconda"])
    func richTextInserts(text: String) async {
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([field(value: "")])]), actuator: actuator)
            .deliver(request(.typeText(text, into: "Project Name", replacing: true)))
        #expect(actuator.gestures.last == .insert(text))
    }

    @Test("appending moves to the field's end instead of selecting, and expects the old value first")
    func appendKeepsTheValue() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "Budget 2027"
        let outcome = await engine(scenes: ScriptedScenes([scene([field(value: "Budget")])]),
                                   actuator: actuator, controls: controls)
            .deliver(request(.typeText(" 2027", into: "Project Name", replacing: false)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: fieldPoint), .key(code: Key.downArrow, modifiers: .command),
                                      .type(" 2027")])
    }

    @Test("appending after a click that went through accessibility does not press the end key that would drop the field",
          arguments: ["AXTextField", "AXTextArea", "AXGroup"])
    func appendAfterAnAccessibilityClick(role: String) async {
        let actuator = RecordingActuator()
        actuator.route = .accessibility
        var target = field(value: "Budget")
        target.role = role
        _ = await engine(scenes: ScriptedScenes([scene([target])]), actuator: actuator)
            .deliver(request(.typeText(" 2027", into: "Project Name", replacing: false)))
        // Its caret is already at the end of the text; a group that is no field keeps the key.
        let isField = role != "AXGroup"
        #expect(actuator.gestures == (isField
            ? [.click(at: fieldPoint), .type(" 2027")]
            : [.click(at: fieldPoint), .key(code: Key.downArrow, modifiers: .command), .type(" 2027")]))
    }

    @Test("a plain character key pressed while a field has the focus says to use type_text, and a shortcut does not")
    func aCharacterKeySaysToTypeText() async {
        let scenes = [scene([field(value: "")]), scene([field(value: "a")])]
        for (chord, focused, says) in [
            (KeyChord(.character("a")), "a", true),
            (KeyChord(.character("a"), modifiers: .shift), "A", true),
            (KeyChord(.character("a"), modifiers: .command), "a", false),
            (KeyChord(.return), "a", false),
            (KeyChord(.character("a")), nil, false),
        ] as [(KeyChord, String?, Bool)] {
            let controls = FakeControls(); controls.focused = focused
            let outcome = await engine(scenes: ScriptedScenes(scenes), controls: controls)
                .deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.message.contains(ActionEngine.typeTextNote) == says,
                    Comment(rawValue: "\(chord) focused \(focused ?? "nothing"): \(outcome.message)"))
        }
    }

    @Test("a dry run types nothing, and an empty text is refused")
    func typeDryRunAndEmpty() async {
        let actuator = RecordingActuator()
        let rehearsal = await engine(scenes: ScriptedScenes([scene([field(value: "x")])]), actuator: actuator)
            .deliver(request(.typeText("My Project", into: "Project Name", replacing: true), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(rehearsal.message == "would click 'Project Name' at 500,432, select what it holds and type 10 "
            + "characters")
        let empty = await engine(scenes: ScriptedScenes([scene([field(value: "x")])]), actuator: actuator)
            .deliver(request(.typeText("", into: "Project Name", replacing: true)))
        #expect(empty.kind == .refused)
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: insert_text

    @Test("inserting preserves focus and selection, and exact native readback verifies the complete value")
    func insertionKeepsTheExistingSelection() async {
        let text = "Braus-à-中-🙂\nSeconda\r\nTerza"
        let actuator = RecordingActuator()
        // An insertion is read back only into a focus its provider attests ordinary (W1).
        let controls = FakeControls(); controls.focused = text; controls.focus = [.ordinary(TargetIdentity("double|field"))]
        let activation = FakeActivation(frontmost: 9999)
        let result = await engine(
            scenes: ScriptedScenes([scene([field(value: "Layer 1")])]), actuator: actuator,
            controls: controls, activation: activation
        ).deliver(request(.insertText(text, expecting: text)))
        #expect(result.kind == .foundActed, Comment(rawValue: result.message))
        #expect(actuator.gestures == [.insert(text)])
        #expect(actuator.confirmations == [.observed])
        #expect(activation.activated.isEmpty)
    }

    @Test("an unreadable focused value or a missing expectation cannot verify insertion",
          arguments: [nil, "different", "Braus"] as [String?])
    func insertionNeedsNativeReadback(value: String?) async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = value; controls.focus = [.ordinary(TargetIdentity("double|field"))]
        let result = await engine(
            scenes: ScriptedScenes([scene([field(value: "Braus")])]), actuator: actuator, controls: controls
        ).deliver(request(.insertText("Braus", expecting: value == "Braus" ? nil : "Braus")))
        #expect(result.kind == .actedUnverified)
        #expect(actuator.gestures == [.insert("Braus")])
        #expect(actuator.confirmations == [.unknown])
        #expect(result.message.contains("never insert again blindly"))
    }

    @Test("a complete value expectation can verify insertion into a partially selected field")
    func insertionVerifiesTheWholeValue() async {
        let actuator = RecordingActuator()
        let controls = FakeControls(); controls.focused = "prefix Braus suffix"
        controls.focus = [.ordinary(TargetIdentity("double|field"))]
        let result = await engine(
            scenes: ScriptedScenes([scene([])]), actuator: actuator, controls: controls
        ).deliver(request(.insertText("Braus", expecting: "prefix Braus suffix")))
        #expect(result.kind == .foundActed)
        #expect(actuator.gestures == [.insert("Braus")])
    }

    @Test("dry run, empty text and missing initial scene never insert")
    func insertionRequiresAnObservedSession() async {
        let actuator = RecordingActuator()
        let rehearsal = await engine(scenes: ScriptedScenes([scene([])]), actuator: actuator)
            .deliver(request(.insertText("Braus"), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        let empty = await engine(scenes: ScriptedScenes([scene([])]), actuator: actuator)
            .deliver(request(.insertText("")))
        #expect(empty.kind == .refused)
        let missing = await engine(scenes: ScriptedScenes([]), actuator: actuator)
            .deliver(request(.insertText("Braus")))
        #expect(missing.kind == .honestMiss)
        #expect(actuator.gestures.isEmpty)
        #expect(actuator.confirmations.isEmpty)
    }

    @Test("failed insertion delivery stays uncertain without fallback or replay")
    func insertionDeliveryFailureIsNotRetried() async {
        let actuator = RecordingActuator()
        actuator.failure = CocoaError(.userCancelled)
        let result = await engine(scenes: ScriptedScenes([scene([])]), actuator: actuator)
            .deliver(request(.insertText("Braus", expecting: "Braus")))
        #expect(result.kind == .actedUnverified)
        #expect(result.message.contains("delivery failed"))
        #expect(actuator.gestures.isEmpty)
        #expect(actuator.confirmations == [.unknown])
    }

    // MARK: press_key

    @Test("Command-Q and Command-W are refused before any event, even with destructive actions allowed")
    func quitAndCloseAreRefused() async {
        let actuator = RecordingActuator()
        let allowed = ActionPermissions(allowsDestructive: true)
        for chord in [KeyChord(.character("q"), modifiers: .command),
                      KeyChord(.character("w"), modifiers: [.command, .shift])] {
            let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator,
                                       permissions: allowed)
                .deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == .refused)
        }
        #expect(actuator.gestures.isEmpty)
    }

    @Test("R07: Command-Delete is refused without the person's permission, and with it: no route here verifies it")
    func commandDeleteIsDestructive() async {
        let chord = KeyChord(.delete, modifiers: .command)
        let refused = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.pressKey(chord, times: 1)))
        #expect(refused.kind == .refused && refused.message.contains("person must allow destructive actions"))
        let blind = RecordingActuator()
        let unconfirmed = await engine(scenes: ScriptedScenes([scene([export])]), actuator: blind,
                                       permissions: ActionPermissions(allowsDestructive: true))
            .deliver(request(.pressKey(chord, times: 1)))
        #expect(unconfirmed.kind == .refused && unconfirmed.message.contains("cannot read its effect back"),
                Comment(rawValue: unconfirmed.message))
        #expect(blind.gestures.isEmpty)
    }

    @Test("a key's changed native selection is verified without a text or pixel change")
    func keyChangesNativeSelection() async {
        var before = field(value: "Aé🧪")
        before.selectedRange = NSRange(location: 0, length: 0)
        var after = before
        after.selectedRange = NSRange(location: 0, length: 1)
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes: ScriptedScenes([scene([before]), scene([after])]), actuator: actuator
        ).deliver(request(.pressKey(KeyChord(.right, modifiers: .shift), times: 1)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("text selection"))
        #expect(actuator.confirmations == [.observed])
        #expect(actuator.gestures == [.key(code: Key.rightArrow, modifiers: .shift)])
    }

    @Test("unknown, invalid or ambiguous selection cannot verify a key", arguments: [
        "unknown before", "unknown after", "different identity",
        "different role", "duplicate ID", "invalid range"
    ])
    func uncertainSelectionCannotVerifyAKey(_ issue: String) async {
        var before = field(value: "Aé🧪")
        before.selectedRange = NSRange(location: 4, length: 0)
        var after = before
        after.selectedRange = NSRange(location: 0, length: 1)
        switch issue {
            case "unknown before"   : before.selectedRange = nil
            case "unknown after"    : after.selectedRange = nil
            case "different identity": after.id = "another-field"
            case "different role"   : after.role = "AXStaticText"
            case "invalid range"    : after.selectedRange = NSRange(location: Int.max, length: 1)
            default                  : break
        }
        let beforeElements = issue == "duplicate ID" ? [before, before] : [before]
        let afterElements = issue == "duplicate ID" ? [after, after] : [after]
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes: ScriptedScenes([scene(beforeElements), scene(afterElements)]), actuator: actuator
        ).deliver(request(.pressKey(KeyChord(.right, modifiers: .shift), times: 1)))
        #expect(outcome.kind == .actedUnverified)
        #expect(actuator.confirmations == [.unknown])
        #expect(actuator.gestures.count == 1)
    }

    @Test("a key that changes a field's value is verified by the new value, caret included or not")
    func keyChangesFieldValue() async {
        var before = field(value: "")
        before.selectedRange = NSRange(location: 0, length: 0)
        var after = field(value: "a")
        after.selectedRange = NSRange(location: 1, length: 0)
        for (was, now) in [(before, after), (field(value: ""), field(value: "a"))] {
            let actuator = RecordingActuator()
            let outcome = await engine(
                scenes: ScriptedScenes([scene([was]), scene([now])]), actuator: actuator
            ).deliver(request(.pressKey(KeyChord(.character("a")), times: 1)))
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.message == "pressed a: 'Project Name' now reads 'a'")
            #expect(actuator.confirmations == [.observed])
        }
    }

    @Test("a value unreadable on either side is no change for a key", arguments: ["before", "after"])
    func unreadableValueIsNoChange(_ side: String) async {
        let before = field(value: side == "before" ? nil : "")
        let after = field(value: side == "after" ? nil : "a")
        let actuator = RecordingActuator()
        let outcome = await engine(
            scenes: ScriptedScenes([scene([before], token: "t1"), scene([after], token: "t2")]), actuator: actuator
        ).deliver(request(.pressKey(KeyChord(.character("a")), times: 1)))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("a caret move that the scene cannot read stays unverified when the value is the same")
    func caretMoveWithoutReadableRangeStaysUnverified() async {
        var after = field(value: "abc")
        after.role = "AXTextField"
        let outcome = await engine(
            scenes: ScriptedScenes([scene([field(value: "abc")], token: "t1"), scene([after], token: "t2")])
        ).deliver(request(.pressKey(KeyChord(.left), times: 1)))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
    }

    @Test("a key is found_acted only when the scene changed, and repeats go out as separate presses")
    func keyIsJudgedByTheScene() async {
        let actuator = RecordingActuator()
        let landed = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Render Queue")]),
                                  actuator: actuator)
            .deliver(request(.pressKey(KeyChord(.return), times: 1)))
        #expect(landed.kind == .foundActed)
        #expect(landed.message == "pressed return: navigates to Render Queue")
        #expect(actuator.gestures == [.key(code: Key.return)])

        let repeated = RecordingActuator()
        let ghost = await engine(scenes: ScriptedScenes([scene([export])]), actuator: repeated)
            .deliver(request(.pressKey(KeyChord(.down), times: 3)))
        #expect(ghost.kind == .actedUnverified)
        #expect(ghost.message.hasPrefix("pressed down 3 times: this window did NOT change"))
        #expect(repeated.gestures == Array(repeating: .key(code: Key.downArrow), count: 3))
        #expect(repeated.confirmations == [.absent])
    }

    @Test("Tab and Shift-Tab with a change that is not the focus moving stay unverified", arguments: [
        "selection of the focused field", "element elsewhere"
    ])
    func focusKeyWithoutFocusMoveIsUnverified(_ change: String) async {
        // Safari, 14/10: Shift-Tab select-alled the field that already held the focus.
        var before = field(value: "hello1")
        before.selectedRange = NSRange(location: 6, length: 0)
        var after = before
        if change == "selection of the focused field" { after.selectedRange = NSRange(location: 0, length: 6) }
        let extra = change == "element elsewhere" ? [trash] : []
        for chord in [KeyChord(.tab), KeyChord(.tab, modifiers: .shift)] {
            let actuator = RecordingActuator()
            let outcome = await engine(
                scenes: ScriptedScenes([scene([before]), scene([after] + extra)]), actuator: actuator
            ).deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
            #expect(outcome.message.hasPrefix("pressed \(chord): the focus did not visibly move"))
            #expect(outcome.message.contains("click the field"))
            #expect(outcome.check?.verdict == .unknown)
            #expect(actuator.confirmations == [.unknown])
        }
    }

    @Test("Tab is found_acted when the focus moved to another field or left the one it was in")
    func focusKeyWithFocusMoveIsFound() async {
        var name = field(value: "hello1")
        name.selectedRange = NSRange(location: 6, length: 0)
        var email = field(value: "", id: "control|email")
        email.label = "Email"
        var focused = email
        focused.selectedRange = NSRange(location: 0, length: 0)
        let cases: [(PerceivedWindow, PerceivedWindow, KeyChord, String)] = [
            (scene([name, email]), scene([field(value: "hello1"), focused]), KeyChord(.tab),
             "pressed tab: the focus moved to 'Email'"),
            (scene([name, email]), scene([field(value: "hello1"), email]), KeyChord(.tab, modifiers: .shift),
             "pressed shift+tab: the focus left 'Project Name'"),
        ]
        for (before, after, chord, message) in cases {
            let actuator = RecordingActuator()
            let outcome = await engine(scenes: ScriptedScenes([before, after]), actuator: actuator)
                .deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.message == message)
            #expect(outcome.check?.verdict == .passed)
            #expect(actuator.confirmations == [.observed])
        }
    }

    @Test("Tab in a native form whose fields all hold a selection keeps the window-wide verdict")
    func focusKeyAmongSeveralSelectionsKeepsTheOldRule() async {
        // AppKit reports a selection on every text field, focused or not: the holders cannot show the focus.
        var name = field(value: "hello1")
        name.selectedRange = NSRange(location: 6, length: 0)
        var email = field(value: "a@b", id: "control|email")
        email.label = "Email"
        email.selectedRange = NSRange(location: 0, length: 0)
        var left = name, entered = email
        left.selectedRange = NSRange(location: 0, length: 0)
        entered.selectedRange = NSRange(location: 0, length: 3)
        for chord in [KeyChord(.tab), KeyChord(.tab, modifiers: .shift)] {
            let actuator = RecordingActuator()
            let outcome = await engine(
                scenes: ScriptedScenes([scene([name, email]), scene([left, entered])]), actuator: actuator
            ).deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.message == "pressed \(chord): changes text selection")
            #expect(actuator.confirmations == [.observed])
        }
    }

    @Test("in Safari the address bar's selection does not hide the web field's focus")
    func focusKeyBesideTheAddressBarIsJudgedByTheFocus() async {
        // Safari 14/10: `[field] smart search field ... = file:///.../bench.html [sel 0..0/106] @32,2` in the top
        // bar, `[field] Name id:'control|name' = hello0 [sel 0..6/6] @7,19` in content (Bench Page).
        let search = SceneElement(id: "control|smartsearchfield", kind: .control, label: "smart search field",
                                  bounds: NormalizedRect(x: 0.32, y: 0.02, width: 0.33, height: 0.03),
                                  role: "AXTextField", value: "file:///Users/mac/bench.html",
                                  selectedRange: NSRange(location: 0, length: 0), section: "top bar")
        let name = SceneElement(id: "control|name", kind: .control, label: "Name",
                                bounds: NormalizedRect(x: 0.07, y: 0.19, width: 0.14, height: 0.03),
                                role: "AXTextField", value: "hello0",
                                selectedRange: NSRange(location: 6, length: 0), section: "content (Bench Page)")
        var selectedAll = name, blurred = name
        selectedAll.selectedRange = NSRange(location: 0, length: 6)
        blurred.selectedRange = nil
        let cases: [(SceneElement, KeyChord, ActOutcomeKind, String)] = [
            (selectedAll, KeyChord(.tab, modifiers: .shift), .actedUnverified,
             "pressed shift+tab: the focus did not visibly move; what changed (changes text selection) is not "
                + "the focus moving. To reach a field, click the field instead of pressing again."),
            (blurred, KeyChord(.tab), .foundActed, "pressed tab: the focus left 'Name'"),
        ]
        for (after, chord, kind, message) in cases {
            let outcome = await engine(scenes: ScriptedScenes([scene([search, name]), scene([search, after])]))
                .deliver(request(.pressKey(chord, times: 1)))
            #expect(outcome.kind == kind, Comment(rawValue: outcome.message))
            #expect(outcome.message == message)
        }
    }

    @Test("Tab typed into a text area is found_acted with the area's new value")
    func tabTypedIntoTextAreaIsFound() async {
        var notes = field(value: "hello")
        notes.role = "AXTextArea"
        notes.label = "Notes"
        notes.selectedRange = NSRange(location: 5, length: 0)
        var typed = notes
        typed.value = "hello\t"
        typed.selectedRange = NSRange(location: 6, length: 0)
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([notes]), scene([typed])]), actuator: actuator)
            .deliver(request(.pressKey(KeyChord(.tab), times: 1)))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message == "pressed tab: 'Notes' now reads 'hello\t'")
        #expect(actuator.confirmations == [.observed])
    }

    @Test("text read from pixels again in place is no effect of a key, and new text elsewhere still is")
    func pixelTextRereadIsNoKeyEffect() async {
        // TextEdit, 14/10: Command-Z answered "reveals elements" from OCR re-reading the same lines.
        let lines = [text("Line 4 of the scratch documenti", x: 0.01, y: 0.23, width: 0.4),
                     text("Line 7 ot cne", x: 0.01, y: 0.33, width: 0.15)]
        let reread = [text("ine4 ot", x: 0.01, y: 0.24, width: 0.08),
                      text("scratch document", x: 0.15, y: 0.23, width: 0.2),
                      text("Line 7 of thel", x: 0.01, y: 0.33, width: 0.16)]
        let undo = KeyChord(.character("z"), modifiers: .command)
        let actuator = RecordingActuator()
        let jitter = await engine(scenes: ScriptedScenes([scene(lines), scene(reread)]), actuator: actuator)
            .deliver(request(.pressKey(undo, times: 1)))
        #expect(jitter.kind == .actedUnverified, Comment(rawValue: jitter.message))
        #expect(actuator.confirmations == [.unknown])

        let saved = text("Saved", x: 0.6, y: 0.9, width: 0.1)
        let appeared = await engine(scenes: ScriptedScenes([scene(lines), scene(lines + [saved])]))
            .deliver(request(.pressKey(undo, times: 1)))
        #expect(appeared.kind == .foundActed, Comment(rawValue: appeared.message))
        #expect(appeared.message == "pressed cmd+z: reveals elements")
    }

    @Test("a line re-read in place is no key effect although its fragments repeat on other lines")
    func repeatedFragmentRereadIsNoKeyEffect() async {
        // TextEdit 14/10 14:36, Command-Z: `- of the scratch document @8,35` `+ otthe scratch document @8,35`,
        // `- Line 7 of the scratch document @1,32` `+ Line @1,33` `+ the scratch document @11,33`.
        let kept = [text("Line", x: 0.01, y: 0.27, width: 0.05),
                    text("of the scratch document", x: 0.08, y: 0.26, width: 0.3),
                    text("Line", x: 0.01, y: 0.29, width: 0.05),
                    text("of the scratch document", x: 0.08, y: 0.29, width: 0.3),
                    text("Line", x: 0.01, y: 0.39, width: 0.05),
                    text("of the scratch document", x: 0.08, y: 0.38, width: 0.3)]
        let lines = [text("Line 7 of the scratch document", x: 0.01, y: 0.32, width: 0.38),
                     text("of the scratch document", x: 0.08, y: 0.35, width: 0.3)]
        let reread = [text("Line", x: 0.01, y: 0.33, width: 0.05),
                      text("the scratch document", x: 0.11, y: 0.33, width: 0.27),
                      text("otthe scratch document", x: 0.08, y: 0.35, width: 0.3)]
        let undo = KeyChord(.character("z"), modifiers: .command)
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene(kept + lines), scene(kept + reread)]),
                                   actuator: actuator)
            .deliver(request(.pressKey(undo, times: 1)))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("a line a key restores above lines that move down is found, and a status relabeled in place is not")
    func restoredLineAboveMovedLinesIsFound() async {
        let undo = KeyChord(.character("z"), modifiers: .command)
        let before = [text("First line", x: 0.01, y: 0.10, width: 0.2),
                      text("Second line", x: 0.01, y: 0.13, width: 0.2)]
        let after = [text("Restored line", x: 0.01, y: 0.10, width: 0.2),
                     text("First line", x: 0.01, y: 0.13, width: 0.2),
                     text("Second line", x: 0.01, y: 0.16, width: 0.2)]
        let restored = await engine(scenes: ScriptedScenes([scene(before), scene(after)]))
            .deliver(request(.pressKey(undo, times: 1)))
        #expect(restored.kind == .foundActed, Comment(rawValue: restored.message))
        #expect(restored.message == "pressed cmd+z: reveals elements")

        let saving = [text("Saving", x: 0.6, y: 0.9, width: 0.1)]
        let saved = [text("Saved", x: 0.6, y: 0.9, width: 0.1)]
        let relabeled = await engine(scenes: ScriptedScenes([scene(before + saving), scene(before + saved)]))
            .deliver(request(.pressKey(undo, times: 1)))
        #expect(relabeled.kind == .actedUnverified, Comment(rawValue: relabeled.message))
    }

    @Test("a bare slash or tilde is typed, and with a modifier it goes by character like a letter")
    func slashIsTyped() async throws {
        let slash = try #require(KeyChord.Name("/"))
        #expect(KeyChord.Name("~") != nil && KeyChord.Name.all.contains("/"))
        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.pressKey(KeyChord(slash), times: 1)))
        #expect(actuator.gestures == [.type("/")])
        #expect(KeyChord(slash, modifiers: .command).gesture == .character("/", modifiers: .command))
    }

    @Test("an unseen Command chord preserves delivery uncertainty and target-dependent guidance")
    func menuShortcutNote() async {
        let actuator = RecordingActuator()
        let copy = KeyChord(.character("c"), modifiers: .command)
        let background = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.pressKey(copy, times: 1)))
        #expect(actuator.gestures == [.character("c", modifiers: .command)])
        #expect(background.kind == .actedUnverified)
        #expect(!background.message.contains("does nothing on this background window"))
        #expect(background.message.contains("depends on the target"))
        #expect(background.message.contains("Do not repeat an unconfirmed command"))
        let foreground = await engine(scenes: ScriptedScenes([scene([export])]),
                                      activation: FakeActivation(frontmost: pid))
            .deliver(request(.pressKey(copy, times: 1)))
        #expect(!foreground.message.contains("depends on the target"))
    }

    @Test("a key dry run presses nothing")
    func keyDryRun() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.pressKey(KeyChord(.character("n"), modifiers: [.command, .shift]), times: 1),
                             dryRun: true))
        #expect(outcome.kind == .dryRun)
        #expect(outcome.message == "would press shift+cmd+n into X's window")
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: scroll

    @Test("a scroll goes out over its target, down negative, and new rows are its effect")
    func scrollOverTarget() async {
        let actuator = RecordingActuator()
        let row = SceneElement(id: "text|budget", kind: .text, label: "Budget 2027",
                               bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.02))
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export, row])]),
                                   actuator: actuator)
            .deliver(request(.scroll(lines: -3, over: "Export")))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message == "scrolled 3 lines down over 'Export': reveals elements")
        #expect(actuator.gestures == [.scroll(at: exportPoint, deltaY: -3)])
    }

    @Test("without a target a scroll turns over the window's centre, and nothing moving is unverified")
    func scrollOverWindow() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.scroll(lines: 2, over: nil)))
        #expect(actuator.gestures == [.scroll(at: CGPoint(x: 600, y: 500), deltaY: 2)])
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("Nothing moved"))
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.scroll(lines: 1, over: nil), dryRun: true))
        #expect(rehearsal.message == "would scroll 1 line up over the window's centre at 600,500")
        let none = await engine(scenes: ScriptedScenes([scene([export])]))
            .deliver(request(.scroll(lines: 0, over: nil)))
        #expect(none.kind == .refused)
    }

    // MARK: drag

    @Test("a drag goes from one target to the other, and a mere repaint is unverified")
    func dragBetweenTargets() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export, field(value: nil)], token: "a"),
                                                           scene([export, field(value: nil)], token: "b")]),
                                   actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Project Name"))))
        #expect(actuator.gestures == [.drag(from: exportPoint, to: fieldPoint)])
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("cannot be told from a repaint"))
        #expect(actuator.confirmations == [.unknown])
    }

    @Test("a drag by an offset ends that far away, and a change it caused is found_acted")
    func dragByOffset() async {
        let actuator = RecordingActuator()
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), scene([export], title: "Moved")]),
                                   actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .offset(dx: -40, dy: 10))))
        let end = CGPoint(x: exportPoint.x - 40, y: exportPoint.y + 10)
        #expect(actuator.gestures == [.drag(from: exportPoint, to: end)])
        #expect(outcome.kind == .foundActed)
    }

    @Test("dropping on a destructive target is refused, and a drag dry run drags nothing")
    func dragPolicyAndDryRun() async {
        let actuator = RecordingActuator()
        let refused = await engine(scenes: ScriptedScenes([scene([export, trash])]), actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Trash"))))
        #expect(refused.kind == .refused)
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export, field(value: nil)])]), actuator: actuator)
            .deliver(request(.drag(from: "Export", to: .target("Project Name")), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(actuator.gestures.isEmpty)
    }

    // MARK: context_menu

    @Test("a contextual menu opens with a right click and its row is chosen by the pop-up path, its keys claiming nothing")
    func contextMenuChoosesByKeyboard() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[mainWindow], [popupWindow, mainWindow], [popupWindow, mainWindow],
                                       [popupWindow, mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menuScene(["Copy", "Paste"]),
                                                           scene([export])]),
                                   actuator: actuator, windows: windows)
            .deliver(request(.contextMenu(on: "Export", item: "Paste")))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(actuator.gestures == [.click(at: exportPoint, button: .right), .type("Paste"),
                                      .key(code: Key.rightArrow), .key(code: Key.return)])
        #expect(actuator.confirmations == [.unknown], "a menu closing after typed keys is not the item's effect")
    }

    @Test("an item the menu does not offer is an honest miss, and the menu is closed instead of guessed at")
    func contextMenuMissingItem() async {
        let actuator = RecordingActuator()
        let windows = ScriptedWindows([[mainWindow], [popupWindow, mainWindow], [mainWindow]])
        let outcome = await engine(scenes: ScriptedScenes([scene([export]), menuScene(["Copy", "Paste"])]),
                                   actuator: actuator, windows: windows)
            .deliver(request(.contextMenu(on: "Export", item: "Rename")))
        #expect(outcome.kind == .honestMiss)
        #expect(outcome.message.contains("it offered 'Copy', 'Paste'; the menu was closed"))
        #expect(actuator.gestures == [.click(at: exportPoint, button: .right), .key(code: Key.escape)])
    }

    /// DaVinci Resolve's media pool opened its menu on the person's screen and left the seat suspended.
    @Test("where menus open under the person's pointer, only a text field is right-clicked")
    func contextMenuOutsideTheSeatIsRefused() async {
        let qt = ActionPermissions(contextMenusOnTextFieldsOnly: true)
        let untouched = RecordingActuator()
        let refused = await engine(scenes: ScriptedScenes([scene([export])]), actuator: untouched, permissions: qt)
            .deliver(request(.contextMenu(on: "Export", item: "Import Media...")))
        #expect(refused.kind == .refused)
        #expect(refused.message.contains("outside the seat"))
        #expect(untouched.gestures.isEmpty)

        let actuator = RecordingActuator()
        _ = await engine(scenes: ScriptedScenes([scene([field(value: "x")])]), actuator: actuator, permissions: qt)
            .deliver(request(.contextMenu(on: "Project Name", item: "Paste")))
        #expect(actuator.gestures == [.click(at: fieldPoint, button: .right)])
    }

    @Test("no menu after the right click is unverified, a destructive item is refused, a dry run clicks nothing")
    func contextMenuEdges() async {
        let actuator = RecordingActuator()
        let noMenu = await engine(scenes: ScriptedScenes([scene([export])]), actuator: actuator)
            .deliver(request(.contextMenu(on: "Export", item: "Copy")))
        #expect(noMenu.kind == .actedUnverified)
        #expect(noMenu.message.contains("no contextual menu could be read"))
        #expect(actuator.confirmations == [.unknown])

        let untouched = RecordingActuator()
        let destructive = await engine(scenes: ScriptedScenes([scene([export])]), actuator: untouched)
            .deliver(request(.contextMenu(on: "Export", item: "Move to Trash")))
        #expect(destructive.kind == .refused)
        let rehearsal = await engine(scenes: ScriptedScenes([scene([export])]), actuator: untouched)
            .deliver(request(.contextMenu(on: "Export", item: "Copy"), dryRun: true))
        #expect(rehearsal.kind == .dryRun)
        #expect(untouched.gestures.isEmpty)
    }
}
