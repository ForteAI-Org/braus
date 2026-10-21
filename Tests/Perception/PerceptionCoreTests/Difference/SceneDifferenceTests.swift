//
//  SceneDifferenceTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation
@testable import PerceptionCore
import Testing

/// The differ names causality from text, so its rules are pinned on scene pairs shaped like the
/// measurements that produced them: a flipped switch, an opened menu, meter noise, title churn.
@Suite("Scene difference")
struct SceneDifferenceTests {

    private func scene(_ elements: [SceneElement], title: String = "Export") -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements
        )
    }

    private func element(_ id: String, _ label: String, kind: ElementKind = .control,
                         x: Double = 0.2, y: Double = 0.2, state: ControlState? = nil) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, bounds: NormalizedRect(x: x, y: y, width: 0.05, height: 0.02), state: state)
    }

    @Test("a state flip on the target")
    func stateFlipOnTarget() {
        let before = scene([element("sw", "Facebook", state: .off)])
        let after  = scene([element("sw", "Facebook", state: .on)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw") == .stateFlip(from: .off, to: .on))
    }

    @Test("a state flip survives id churn through kind and label")
    func stateFlipSurvivesIDChurn() {
        let before = scene([element("sw1", "Facebook", state: .off)])
        let after  = scene([element("sw2", "Facebook", x: 0.201, state: .on)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw1") == .stateFlip(from: .off, to: .on))
    }

    @Test("a repeated toggle cannot borrow another scope's state", arguments: ["selected", "other", "ambiguous", "missing"])
    func scopedToggleState(change: String) {
        var first = element("control|mute", "Mute", state: .off)
        first.role = "AXButton"
        first.container = "Bus"
        var target = first
        target.container = "Kick"
        target.bounds.x = 0.4
        var current = target
        var other = first
        if change == "other" { other.state = .on } else { current.state = .on }
        let after = change == "missing" ? [other] : change == "ambiguous" ? [other, current, current] : [other, current]
        let effect = SceneDifference.effect(
            before: scene([first, target]), after: scene(after), targetID: target.id, target: target
        )
        #expect(effect == (change == "selected" ? .stateFlip(from: .off, to: .on) : nil))
        #expect(SceneDifference.effect(
            before: scene([first, target]), after: scene(after), targetID: target.id
        ) == nil)
    }

    @Test("a clustered appearance is a menu, with sorted labels")
    func menuOpened() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "Cut", kind: .text, x: 0.30, y: 0.30),
                            element("m2", "Copy", kind: .text, x: 0.30, y: 0.33),
                            element("m3", "Paste", kind: .text, x: 0.30, y: 0.36)])
        let effect = SceneDifference.effect(before: before, after: after, targetID: "t")
        #expect(effect == .menuOpened(labels: ["Copy", "Cut", "Paste"]))
        #expect(effect?.encoded == "menuOpened:Copy|Cut|Paste")
    }

    @Test("scattered new elements are an appearance, not a menu")
    func scatteredAppearance() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "Alpha", x: 0.05, y: 0.05),
                            element("m2", "Beta", x: 0.90, y: 0.10),
                            element("m3", "Gamma", x: 0.10, y: 0.90)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil)
                == .elementsAppeared(labels: ["Alpha", "Beta", "Gamma"]))
    }

    @Test("live measurements are not UI")
    func measurementsAreNotUI() {
        let before = scene([element("t", "Sequence", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text),
                            element("m1", "+17.6 db", x: 0.3, y: 0.3),
                            element("m2", "00:00:12:00", x: 0.3, y: 0.35),
                            element("m3", "2827313", x: 0.3, y: 0.4),
                            element("m4", "-Od", x: 0.3, y: 0.45)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("the same action produces the same encoded effect")
    func sameActionSameEffect() {
        let before = scene([element("t", "Track", kind: .text)])
        let first = scene([element("t", "Track", kind: .text),
                           element("x1", "Hide", x: 0.3, y: 0.30), element("x2", "Hide All Tracks", x: 0.3, y: 0.33),
                           element("x3", "New Track", x: 0.3, y: 0.36), element("noise", "+3.3 db", x: 0.3, y: 0.39)])
        let second = scene([element("t", "Track", kind: .text),
                            element("y9", "New Track", x: 0.302, y: 0.36), element("y7", "Hide", x: 0.301, y: 0.30),
                            element("y8", "Hide All Tracks", x: 0.3, y: 0.33), element("noise", "-17.9 db", x: 0.3, y: 0.4)])
        let e1 = SceneDifference.effect(before: before, after: first, targetID: nil)
        let e2 = SceneDifference.effect(before: before, after: second, targetID: nil)
        #expect(e1 != nil)
        #expect(e1 == e2)
    }

    @Test("a jittered relabel is not an appearance")
    func jitteredRelabelIsNotNew() {
        let before = scene([element("a1", "Export")])
        let after  = scene([element("a2", "Export", x: 0.202)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("a closed menu is a disappearance")
    func menuClosed() {
        let before = scene([element("t", "Sequence", kind: .text), element("m1", "Cut", kind: .text),
                            element("m2", "Copy", kind: .text), element("m3", "Paste", kind: .text)])
        let after  = scene([element("t", "Sequence", kind: .text)])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil)
                == .elementsDisappeared(labels: ["Copy", "Cut", "Paste"]))
    }

    @Test("a title change wins over everything")
    func titleChangeWins() {
        let before = scene([element("sw", "Facebook", state: .off)], title: "Export")
        let after  = scene([element("sw", "Facebook", state: .on)], title: "Render Queue")
        #expect(SceneDifference.effect(before: before, after: after, targetID: "sw") == .windowTitleChanged(title: "Render Queue"))
    }

    @Test("a counter in the title is not a change")
    func titleCounterChurn() {
        let before = scene([element("a", "Export")], title: "Project v4")
        let after  = scene([element("a", "Export")], title: "Project v5")
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
    }

    @Test("no change is nil")
    func noChange() {
        let before = scene([element("a", "Export"), element("sw", "Facebook", state: .off)])
        #expect(SceneDifference.effect(before: before, after: before, targetID: "a") == nil)
    }

    @Test("native selection identifies the field even beside a checkbox with the same ID",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func nativeSelectionBesideASharedID(_ role: String) {
        var field = element("search", "Search #2")
        field.role = role
        field.value = "Aé🧪"
        field.selectedRange = NSRange(location: 0, length: 0)
        var selected = field
        selected.selectedRange = NSRange(location: 0, length: 4)
        var checkbox = element("search", "Search", state: .on)
        checkbox.role = "AXCheckBox"
        #expect(SceneDifference.effect(
            before: scene([checkbox, field]), after: scene([checkbox, selected]), targetID: nil
        ) == .textSelectionChanged)
    }

    @Test("a selection cannot be attributed across a different application or document")
    func nativeSelectionNeedsTheSameWindow() {
        var field = element("name", "Name")
        field.role = "AXTextField"
        field.value = "Aé🧪"
        field.selectedRange = NSRange(location: 0, length: 0)
        var selected = field
        selected.selectedRange = NSRange(location: 0, length: 4)
        let before = scene([field], title: "Untitled-1")
        var otherDocument = scene([selected], title: "Untitled-2")
        #expect(SceneDifference.effect(before: before, after: otherDocument, targetID: nil) == nil)
        otherDocument.bundleID = "com.other"
        otherDocument.windowTitle = before.windowTitle
        #expect(SceneDifference.effect(before: before, after: otherDocument, targetID: nil) == nil)
    }

    @Test("a text field's new value is an effect only when the caller counts it")
    func valueChangeIsOptIn() {
        var field = element("name", "First Text View")
        field.role = "AXTextArea"
        field.value = ""
        var typed = field
        typed.value = "a"
        let before = scene([field]), after = scene([typed])
        #expect(SceneDifference.effect(before: before, after: after, targetID: nil) == nil)
        let effect = SceneDifference.effect(before: before, after: after, targetID: nil, countsValueChange: true)
        #expect(effect == .valueChanged(label: "First Text View", value: "a"))
        #expect(effect?.summary == "'First Text View' now reads 'a'")
    }

    @Test("a value needs a text field, one match each side and a readable value on both")
    func valueChangeNeedsAReadableMatchedField() {
        var field = element("name", "Name")
        field.role = "AXTextField"
        field.value = "x"
        var changed = field
        changed.value = "y"
        func effect(_ old: [SceneElement], _ new: [SceneElement]) -> SceneEffect? {
            SceneDifference.effect(before: scene(old), after: scene(new), targetID: nil, countsValueChange: true)
        }
        var unreadable = field
        unreadable.value = nil
        #expect(effect([unreadable], [changed]) == nil)
        #expect(effect([field], [unreadable]) == nil)
        #expect(effect([field, field], [changed, changed]) == nil)
        var other = changed
        other.id = "another"
        #expect(effect([field], [other]) == nil)
        var label = changed
        label.role = "AXStaticText"
        var staticOld = field
        staticOld.role = "AXStaticText"
        #expect(effect([staticOld], [label]) == nil)
        // A caret move with the same value keeps its own effect.
        var moved = field
        moved.selectedRange = NSRange(location: 1, length: 0)
        var start = field
        start.selectedRange = NSRange(location: 0, length: 0)
        #expect(effect([start], [moved]) == .textSelectionChanged)
    }

    @Test("a text read natively that now reads another value is an effect, for a click too")
    func nativeTextChange() {
        var display = element("m0.1", "6", kind: .text)
        display.value = "6"
        var result = display
        result.label = "42"
        result.value = "42"
        let effect = SceneDifference.effect(before: scene([display]), after: scene([result]), targetID: "m0.5",
                                            countsNativeTextChange: true)
        #expect(effect == .valueChanged(label: "6", value: "42"))
        #expect(effect?.summary == "'6' now reads '42'")
    }

    @Test("by default a static text that reads another value is no effect: a clock or timecode changes alone")
    func nativeTextChangeIsOptIn() {
        var clock = element("t0", "00:00:01:12", kind: .text)
        clock.value = "00:00:01:12"
        var later = clock
        later.label = "00:00:01:19"
        later.value = "00:00:01:19"
        #expect(SceneDifference.effect(before: scene([clock]), after: scene([later]), targetID: "b1") == nil)
        #expect(SceneDifference.effect(before: scene([clock]), after: scene([later]), targetID: "b1",
                                       countsNativeTextChange: true) != nil, "only a source that asks for it")
    }

    @Test("a recognized text, a duplicate id, an unread side or another app names no text change")
    func nativeTextChangeNeedsAReading() {
        var display = element("m0.1", "6", kind: .text)
        display.value = "6"
        var result = display
        result.label = "42"
        result.value = "42"
        func effect(_ old: [SceneElement], _ new: [SceneElement], app: String = "com.x") -> SceneEffect? {
            var after = scene(new)
            after.bundleID = app
            return SceneDifference.effect(before: scene(old), after: after, targetID: nil, countsNativeTextChange: true)
        }
        // Pixels: the words are only in the label, and a relabel is no effect.
        #expect(effect([element("m0.1", "6", kind: .text)], [element("m0.1", "42", kind: .text)]) == nil)
        var unread = result
        unread.value = nil
        #expect(effect([display], [unread]) == nil)
        #expect(effect([display, display], [result, result]) == nil)
        #expect(effect([display], [result], app: "com.y") == nil)
        #expect(effect([display], [display]) == nil)
    }

    @Test("a display whose id moved names its new value at the same place")
    func nativeTextChangeAtTheSamePlace() {
        // On = Calculator adds the expression area above: the display's path shifts, and its old id
        // now names the expression, which still reads 7×6.
        var typed = element("m0.0", "7×6", kind: .text, y: 0.2)
        typed.value = "7×6"
        var expression = element("m0.0", "7×6", kind: .text, y: 0.1)
        expression.value = "7×6"
        var result = element("m1.0", "42", kind: .text, y: 0.2)
        result.value = "42"
        let effect = SceneDifference.effect(before: scene([typed]), after: scene([expression, result]), targetID: "m2",
                                            countsNativeTextChange: true)
        #expect(effect == .valueChanged(label: "7×6", value: "42"))
    }

    @Test("a place reading needs a native text alone at that place on both sides")
    func nativeTextChangeAtTheSamePlaceNeedsOneReading() {
        var typed = element("m0.0", "7×6", kind: .text)
        typed.value = "7×6"
        var result = element("m1.0", "42", kind: .text)
        result.value = "42"
        var elsewhere = result
        elsewhere.bounds = NormalizedRect(x: 0.6, y: 0.6, width: 0.05, height: 0.02)
        func effect(_ old: [SceneElement], _ new: [SceneElement]) -> SceneEffect? {
            SceneDifference.effect(before: scene(old), after: scene(new), targetID: nil, countsNativeTextChange: true)
        }
        // Pixels at the same place carry no value.
        #expect(effect([element("m0.0", "7×6", kind: .text)], [element("m1.0", "42", kind: .text)]) == nil)
        #expect(effect([typed], [elsewhere]) == nil)
        var other = result
        other.id = "m1.1"
        other.value = "43"
        #expect(effect([typed], [result, other]) == nil)
    }

    @Test("a scoped target and a native text reading compose: a homonym's flip is never the target's, a text is its own")
    func scopedTargetWithNativeText() {
        var bus = element("control|mute", "Mute", state: .off)
        bus.role = "AXButton"
        bus.container = "Bus"
        var kick = bus
        kick.container = "Kick"
        kick.bounds.x = 0.4
        var display = element("m0.1", "-12 dB", kind: .text, y: 0.6)
        display.value = "-12 dB"
        var busOn = bus
        busOn.state = .on
        var read = display
        read.label = "-6 dB"
        read.value = "-6 dB"
        func effect(_ after: [SceneElement], native: Bool) -> SceneEffect? {
            SceneDifference.effect(before: scene([bus, kick, display]), after: scene(after), targetID: kick.id,
                                   target: kick, countsNativeTextChange: native)
        }
        // The homonym in another container flipped, the selected one did not: no state flip, with or without texts.
        #expect(effect([busOn, kick, display], native: false) == nil)
        #expect(effect([busOn, kick, display], native: true) == nil)
        // A native reading that changed is named as a text change, never as the selected control's state.
        #expect(effect([busOn, kick, read], native: true) == .valueChanged(label: "-12 dB", value: "-6 dB"))
        #expect(effect([busOn, kick, read], native: false) == nil)
        // The selected control's own flip still wins over a text that also changed.
        var kickOn = kick
        kickOn.state = .on
        #expect(effect([bus, kickOn, read], native: true) == .stateFlip(from: .off, to: .on))
    }

    @Test("a value change summary is shortened and survives the encoded round trip")
    func valueChangeSummaryAndRoundTrip() {
        let long = SceneEffect.valueChanged(label: "Notes", value: String(repeating: "x", count: 80))
        #expect(long.summary == "'Notes' now reads '" + String(repeating: "x", count: 59) + "…'")
        let effect = SceneEffect.valueChanged(label: "Name", value: "a|b>c:d")
        #expect(effect.family == "valueChanged")
        #expect(SceneEffect(encoded: effect.encoded) == effect)
        #expect(SceneEffect(encoded: "valueChanged:no separator") == nil)
    }

    @Test("family, summary and round trip through the encoded string")
    func familySummaryAndRoundTrip() {
        let flip = SceneEffect.stateFlip(from: .off, to: .on)
        #expect(flip.family == "stateFlip")
        #expect(flip.summary == "toggles")
        #expect(SceneEffect.menuOpened(labels: ["Copy", "Cut", "Paste", "Undo"]).summary == "opens menu(Copy|Cut|Paste…)")
        #expect(SceneEffect.windowTitleChanged(title: "Render Queue").summary == "navigates to Render Queue")
        #expect(SceneEffect.stateFlip(from: .on, to: .off).family == flip.family)
        for effect in [flip, SceneEffect.menuOpened(labels: ["A", "B"]), .elementsAppeared(labels: ["X"]),
                       .elementsDisappeared(labels: []), .windowTitleChanged(title: "Q"), .textSelectionChanged] {
            #expect(SceneEffect(encoded: effect.encoded) == effect)
        }
        #expect(SceneEffect(encoded: "nonsense:x") == nil)
        #expect(SceneEffect(encoded: "textSelectionChanged:unknown") == nil)
    }
}
