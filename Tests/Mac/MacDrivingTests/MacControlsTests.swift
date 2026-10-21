import CoreGraphics
import EngineCore
import Foundation
import MacDriver
@testable import MacDriving
import PerceptionCore
import Synchronization
import Testing

/// NoMenus answers every menu press false and counts them.
struct NoMenus: ControlPressing {
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool { false }
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
    func focusedFieldValue(in processID: pid_t) async -> String? { nil }
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool { false }
}

/// The MacDriver's controls on a small built window: what each answers, and the accessibility rules
/// that hold for every app (spec section 3, rule 3): no call on the caller's actor, and `pressControl`
/// costs no read when the scene has no matching control.
@Suite("MacDriver controls")
struct MacControlsTests {

    static let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A pop-up showing "Medio", a button titled "Grande", a pop-up and a combo box both showing
    /// "Doppio", a checked box, a focused field and a secure field.
    static let window: MacTreeNode = Trees.window("Prova", frame, children: [
        MacTreeNode(role: "AXPopUpButton", value: "Medio", frame: CGRect(x: 10, y: 10, width: 80, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXButton", title: "Grande", frame: CGRect(x: 100, y: 10, width: 60, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXPopUpButton", value: "Doppio", frame: CGRect(x: 10, y: 40, width: 80, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXComboBox", value: "Doppio", frame: CGRect(x: 100, y: 40, width: 80, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXCheckBox", title: "Muto", value: "1", frame: CGRect(x: 10, y: 70, width: 60, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXTextField", value: "ciao", isFocused: true, frame: CGRect(x: 10, y: 100, width: 200, height: 20)),
    ])

    static let secure: MacTreeNode = Trees.window("Accesso", frame, children: [
        MacTreeNode(role: "AXTextField", subrole: MacTreeNode.secureSubrole, value: "•••", isFocused: true,
                    frame: CGRect(x: 10, y: 10, width: 200, height: 20)),
    ])

    private func controls(_ failure: MacTreeFailure? = nil, tree: MacTreeNode = window, cached: Bool = true)
        -> (MacControls, FakeTreeReader) {
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: Self.frame, isFocused: true)
        let reader = FakeTreeReader(windows: [9: [(summary, tree)]], performFailure: failure)
        let cache = MacSceneCache()
        if cached { cache.store(MacSceneCache.Entry(window: tree, windowIndex: 0, windowNumber: 77), for: 9) }
        return (MacControls(cache: cache, reader: reader, actor: reader, menus: NoMenus()), reader)
    }

    @Test("The one pop-up whose value is the label is pressed, from the scene, with no read")
    func pressesPopUp() async {
        let (controls, reader) = controls()
        #expect(await controls.pressControl(labelled: "medio", in: 9))
        #expect(reader.steps.withLock { $0 } == ["perform AXPress [0]"])
        #expect(reader.onMainThread.withLock { $0.count } == 1, "the press, and no read")
    }

    @Test("No pop-up, a plain button, two matches or no scene: nothing is pressed and nothing is read",
          arguments: ["Nessuno", "Grande", "Doppio"])
    func pressesNothing(_ label: String) async {
        let (controls, reader) = controls()
        #expect(await controls.pressControl(labelled: label, in: 9) == false)
        let (bare, bareReader) = self.controls(cached: false)
        #expect(await bare.pressControl(labelled: "Medio", in: 9) == false)
        #expect(reader.steps.withLock { $0 }.isEmpty && bareReader.steps.withLock { $0 }.isEmpty)
        #expect(reader.onMainThread.withLock { $0 }.isEmpty)
    }

    @Test("A press the app did not answer in time counts as pressed; a refused one does not")
    func uncertainPress() async {
        let (uncertain, _) = controls(.uncertain("AXPress: the app did not answer in time"))
        #expect(await uncertain.pressControl(labelled: "Medio", in: 9))
        let (refused, _) = controls(.actionFailed("AXPress: AXError -25200"))
        #expect(await refused.pressControl(labelled: "Medio", in: 9) == false)
    }

    @Test("A control's value among the labels, only when one control has it")
    func controlValue() async {
        let (controls, _) = controls()
        #expect(await controls.controlValue(matchingAny: ["medio", "piccolo"], in: 9) == "Medio")
        #expect(await controls.controlValue(matchingAny: ["doppio"], in: 9) == nil)
        #expect(await controls.controlValue(matchingAny: ["grande"], in: 9) == nil)
    }

    @Test("The toggle under the point, the focused field's value, never a secure field's")
    func reads() async {
        let (controls, _) = controls()
        #expect(await controls.toggleState(at: CGPoint(x: 20, y: 80), in: 9) == .on)
        #expect(await controls.toggleState(at: CGPoint(x: 20, y: 20), in: 9) == nil)
        #expect(await controls.focusedFieldValue(in: 9) == "ciao")
        let (secure, _) = self.controls(tree: Self.secure)
        #expect(await secure.focusedFieldValue(in: 9) == nil)
    }

    enum Entry: String, CaseIterable, Sendable {
        case pressControl, controlValue, toggleState, focusedFieldValue, scene
    }

    @Test("Rule: no accessibility call runs on the caller's actor, whatever the entry point", arguments: Entry.allCases)
    @MainActor
    func offMainActor(_ entry: Entry) async throws {
        let (controls, reader) = controls()
        switch entry {
            case .pressControl     : _ = await controls.pressControl(labelled: "Medio", in: 9)
            case .controlValue     : _ = await controls.controlValue(matchingAny: ["medio"], in: 9)
            case .toggleState      : _ = await controls.toggleState(at: CGPoint(x: 20, y: 80), in: 9)
            case .focusedFieldValue: _ = await controls.focusedFieldValue(in: 9)
            case .scene            : _ = try await MacScenes(reader: reader, serverWindows: { _ in [] }).scene(of: 9)
        }
        let calls = reader.onMainThread.withLock { $0 }
        #expect(!calls.isEmpty)
        #expect(!calls.contains(true))
    }

    // MARK: M2: no single match over a tree that did not answer in full

    @Test("M2: over a tree with a part that did not answer, from the cache or a read, no match is the only one: no press, no value")
    func unreadTree() async {
        var tree = Self.window
        tree.children.append(MacTreeNode(path: [tree.children.count], role: "AXUnknown",
                                         unread: MacUnread(cause: .timedOut, element: true)))
        let (controls, reader) = controls(tree: tree)
        #expect(await !controls.pressControl(labelled: "medio", in: 9))
        #expect(reader.steps.withLock { $0 }.isEmpty, "no AXPress")
        #expect(await controls.controlValue(matchingAny: ["medio", "piccolo"], in: 9) == nil)
    }

    // MARK: M1: the person first in the fast paths

    /// Answers a touch for one process only, whether or not it says it is watching.
    struct TouchOf: MacPersonWatching {
        let processID: pid_t
        let at: ContinuousClock.Instant?
        var isWatching = true
        func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? { processID == self.processID ? at : nil }
    }

    /// Counts the presses delegated to it, and answers each as made.
    final class CountingMenus: ControlPressing, @unchecked Sendable {
        let presses = Mutex<Int>(0)
        func pressControl(labelled label: String, in processID: pid_t) async -> Bool { false }
        func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
        func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
        func focusedFieldValue(in processID: pid_t) async -> String? { nil }
        func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
            presses.withLock { $0 += 1 }
            return true
        }
    }

    private func watched(_ person: (any MacPersonWatching)?, readAt: ContinuousClock.Instant,
                         failure: MacTreeFailure? = nil) -> (MacControls, FakeTreeReader, CountingMenus) {
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: Self.frame, isFocused: true)
        let reader = FakeTreeReader(windows: [9: [(summary, Self.window)]], performFailure: failure)
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: Self.window, windowIndex: 0, windowNumber: 77, readAt: readAt), for: 9)
        let menus = CountingMenus()
        return (MacControls(cache: cache, reader: reader, actor: reader, menus: menus, person: person), reader, menus)
    }

    private static let item = SceneElement(id: "control|pdf", kind: .control, label: "PDF",
                                           bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05), role: "AXMenuItem")

    @Test("M1: the person touched the process after the scene was read, or at that instant, watching or not: no AXPress, no menu press, the choice refused",
          arguments: [(1, true), (0, true), (1, false)])
    func personVetoesTheFastPaths(after seconds: Int, watching: Bool) async {
        let readAt = ContinuousClock.now
        let touch = TouchOf(processID: 9, at: readAt + .seconds(seconds), isWatching: watching)
        let (controls, reader, menus) = watched(touch, readAt: readAt)
        #expect(await !controls.pressControl(labelled: "medio", in: 9))
        #expect(await !controls.pressMenuItem(titled: "PDF", within: .zero, in: 9))
        let choice = await controls.chooseMenuItem(Self.item, within: .zero, in: 9)
        if case .refused = choice {} else { Issue.record("\(choice)") }
        #expect(reader.steps.withLock { $0 }.isEmpty, "no accessibility step")
        #expect(menus.presses.withLock { $0 } == 0, "the menu controller was not called")
    }

    /// Answers its touches one question at a time, in order, then the last one again: a touch that shows up only at
    /// a later check.
    final class TouchesInTurn: MacPersonWatching, @unchecked Sendable {
        let answers: [ContinuousClock.Instant?]
        let asked = Mutex<Int>(0)
        init(_ answers: [ContinuousClock.Instant?]) { self.answers = answers }
        var isWatching: Bool { true }
        func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? {
            let turn = asked.withLock { count in
                defer { count += 1 }
                return count
            }
            return answers[min(turn, answers.count - 1)]
        }
    }

    @Test("M1: a touch that shows up only at the last check, right before the delegation, still refuses the choice: the veto stays a receipt, never 'not handled'")
    func vetoAtTheLastCheck() async {
        let readAt = ContinuousClock.now
        let person = TouchesInTurn([nil, readAt + .seconds(1)])
        let (controls, reader, menus) = watched(person, readAt: readAt)
        let choice = await controls.chooseMenuItem(Self.item, within: .zero, in: 9)
        if case .refused = choice {} else { Issue.record("\(choice)") }
        #expect(person.asked.withLock { $0 } == 2, "the touch was found at the second check")
        #expect(menus.presses.withLock { $0 } == 0, "the menu controller was not called")
        #expect(reader.steps.withLock { $0 }.isEmpty, "no accessibility step")
    }

    @Test("M1, positive controls: a touch before the read, a touch of another process, no touch, no watch: pressed as before",
          arguments: ["older", "other", "none", "no watch"])
    func noVetoOtherwise(kind: String) async {
        let readAt = ContinuousClock.now
        let person: (any MacPersonWatching)? = switch kind {
            case "older": TouchOf(processID: 9, at: readAt - .seconds(1))
            case "other": TouchOf(processID: 10, at: readAt + .seconds(1))
            case "none" : TouchOf(processID: 9, at: nil)
            default     : nil
        }
        let (controls, reader, menus) = watched(person, readAt: readAt)
        #expect(await controls.pressControl(labelled: "medio", in: 9))
        #expect(reader.steps.withLock { $0 } == ["perform AXPress [0]"])
        #expect(await controls.chooseMenuItem(Self.item, within: .zero, in: 9) == .sent(.unattested))
        #expect(menus.presses.withLock { $0 } == 1)
    }

    @Test("M1: a press that timed out stays a press that may have acted: answered once, never pressed again")
    func timedOutPressIsNotReplayed() async {
        let (controls, reader, _) = watched(nil, readAt: .now, failure: .uncertain("timed out"))
        #expect(await controls.pressControl(labelled: "medio", in: 9))
        #expect(reader.onMainThread.withLock { $0 }.count == 1, "one attempt")
    }
}
