//
//  SelectChoiceTests.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing
import WebDriver
@testable import WebDriving
import WebSession

/// W2 and W3 on a native select over a `SyntheticSelectPage`, with `WebControls`'s own scripts in JavaScriptCore:
/// an option is chosen by the row the scene showed, mapped to the observed option node, index, value and full text,
/// never by its rendered label; a choice that cannot be made safely is refused with no event; an applied choice is
/// judged by the value read back after the page's handlers, a microtask and the timers ran, within one deadline,
/// never by the list's closing. Through the engine and the production recorder too, counting events.
@MainActor
@Suite("Native select choices (W2, W3)", .serialized)
struct SelectChoiceTests {

    struct Stack {
        let page     : SyntheticSelectPage
        let tabs     : WebTabs
        let processID: pid_t
        let controls : WebControls
    }

    nonisolated static let colors = "__select('color', 'Color', [__option('Red', 'r'), __option('Blue', 'b1'), __option('Blue', 'b2'), "
        + "__option('Green', 'g')], [100, 100, 200, 24], 0);"

    static func stack(_ setup: String, budget: Duration = .seconds(3)) async -> Stack {
        let page = SyntheticSelectPage(setup: setup)
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        return Stack(page: page, tabs: tabs, processID: processID, controls: WebControls(tabs: tabs, choiceBudget: budget))
    }

    /// Opens the select named `name` as the engine's click does, and answers the scene with its list.
    static func open(_ stack: Stack, _ name: String) async throws -> SceneSnapshot {
        let opened = await stack.controls.pressControl(labelled: name, in: stack.processID)
        #expect(opened, "the list of \(name) opened")
        return try await WebScenes(tabs: stack.tabs).currentScene(of: stack.processID).scene
    }

    static func row(_ label: String, in scene: SceneSnapshot) throws -> SceneElement {
        try #require(scene.elements.first { $0.role == "AXMenuItem" && $0.label == label },
                     "\(label) in \(scene.elements.filter { $0.role == "AXMenuItem" }.map(\.label))")
    }

    static func choose(_ label: String, _ stack: Stack, in scene: SceneSnapshot) async throws -> MenuItemPress {
        await stack.controls.chooseMenuItem(try row(label, in: scene), within: .zero, in: stack.processID)
    }

    // MARK: W2: which option

    @Test("two options with the same text: the row the scene names #2 chooses the second, by index, not the first match")
    func duplicates() async throws {
        let stack = await Self.stack(Self.colors)
        let scene = try await Self.open(stack, "Color")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        #expect(receipt == .sent(.confirmed(expected: "Blue", observed: "Blue")), "\(receipt)")
        #expect(stack.page.read("__selects[0].selectedIndex") == "2" && stack.page.read("__selects[0].value") == "\"b2\"")
        #expect(stack.page.events("change") == 1 && stack.page.events("input") == 1)
    }

    @Test("two long options alike in their first 80 characters, and an empty one: each row chooses its own option")
    func longAndEmpty() async throws {
        let long = String(repeating: "Opzione lunga ", count: 7)
        let stack = await Self.stack("__select('pick', 'Pick', [__option(''), __option('\(long)A', 'a'), __option('\(long)B', 'b')], "
                                     + "[100, 100, 200, 24], 1);")
        let scene = try await Self.open(stack, "Pick")
        let rows = scene.elements.filter { $0.role == "AXMenuItem" }.map(\.label)
        #expect(rows.count == 3 && rows[0] == "empty option" && rows[2].hasSuffix("#2"), "\(rows)")
        let second = try await Self.choose(rows[2], stack, in: scene)
        #expect(second == .sent(.confirmed(expected: "\(long)B".trimmingCharacters(in: .whitespaces),
                                           observed: "\(long)B".trimmingCharacters(in: .whitespaces))), "\(second)")
        #expect(stack.page.read("__selects[0].selectedIndex") == "2")
        let reopened = try await Self.open(stack, "Pick")
        let empty = try await Self.choose("empty option", stack, in: reopened)
        #expect(empty == .sent(.confirmed(expected: "", observed: "")), "\(empty)")
        #expect(stack.page.read("__selects[0].selectedIndex") == "0")
    }

    @Test("a disabled option, an option of a disabled group: refused, no event, the value as it was")
    func disabled() async throws {
        let stack = await Self.stack("var old = __optgroup('Old', true); __select('pick', 'Pick', [__option('A', 'a'), "
                                     + "__option('B', 'b', true), __option('C', 'c', false, old)], [100, 100, 200, 24], 0);")
        for label in ["B", "C"] {
            let scene = try await Self.open(stack, "Pick")
            let receipt = try await Self.choose(label, stack, in: scene)
            if case .refused = receipt {} else { Issue.record("\(label): \(receipt)") }
        }
        #expect(stack.page.events("change") == 0 && stack.page.read("__selects[0].selectedIndex") == "0")
    }

    @Test("the select replaced, its options reordered, an option's text or value changed after the list was read: refused, no event",
          arguments: ["__selects[0].isConnected = false; " + colors,
                      "__selects[0].options.reverse();",
                      "__selects[0].options[2].text = 'Navy';",
                      "__selects[0].options[2].value = 'navy';",
                      "var extra = __option('Blue', 'b0'); extra.owner = __selects[0]; __selects[0].options.splice(1, 0, extra);"])
    func changedSinceRead(change: String) async throws {
        let stack = await Self.stack(Self.colors)
        let scene = try await Self.open(stack, "Color")
        stack.page.run(change)
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        if case .refused = receipt {} else { Issue.record("\(change): \(receipt)") }
        #expect(stack.page.events("change") == 0 && stack.page.events("input") == 0)
    }

    @Test("a row the open list does not show: refused, nothing sent")
    func unknownRow() async throws {
        let stack = await Self.stack(Self.colors)
        _ = try await Self.open(stack, "Color")
        let stranger = SceneElement(id: "control|nowhere", kind: .control, label: "Blue",
                                    bounds: NormalizedRect(x: 0.9, y: 0.9, width: 0.01, height: 0.01), role: "AXMenuItem")
        let receipt = await stack.controls.chooseMenuItem(stranger, within: .zero, in: stack.processID)
        if case .refused = receipt {} else { Issue.record("\(receipt)") }
        #expect(stack.page.events("change") == 0)
    }

    // MARK: W3: what the choice did

    @Test("the page puts the value back, synchronously, in a microtask, on a timer, after 50 or 100 ms, or to the other option of the same text: contradicted, once, never replayed",
          arguments: ["s.selectedIndex = 0;", "Promise.resolve().then(function () { s.selectedIndex = 0; });",
                      "setTimeout(function () { s.selectedIndex = 0; }, 0);",
                      "setTimeout(function () { s.selectedIndex = 0; }, 50);",
                      "setTimeout(function () { s.selectedIndex = 0; }, 100);",
                      "setTimeout(function () { s.selectedIndex = 1; }, 100);"])
    func restored(restore: String) async throws {
        let stack = await Self.stack(Self.colors)
        stack.page.run("var s = __selects[0]; s.addEventListener('change', function () { \(restore) });")
        let scene = try await Self.open(stack, "Color")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        let back = restore.contains("selectedIndex = 1") ? "Blue" : "Red"
        #expect(receipt == .sent(.contradicted(expected: "Blue", observed: back)), "\(receipt)")
        #expect(stack.page.events("change") == 1, "one choice, no replay")
    }

    @Test("a deadline too short to watch the select hold still: applied, unread, not replayed")
    func noTimeToWatch() async throws {
        let stack = await Self.stack(Self.colors, budget: .milliseconds(300))
        let scene = try await Self.open(stack, "Color")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        if case .sent(.unread) = receipt {} else { Issue.record("\(receipt)") }
        #expect(stack.page.events("change") == 1)
    }

    @Test("the limit, stated: a value the page changes only after the watched window is not seen; the receipt says what held then")
    func changeAfterTheWindow() async throws {
        let stack = await Self.stack(Self.colors)
        stack.page.run("var s = __selects[0]; s.addEventListener('change', function () { setTimeout(function () { s.selectedIndex = 0; }, 900); });")
        let scene = try await Self.open(stack, "Color")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        #expect(receipt == .sent(.confirmed(expected: "Blue", observed: "Blue")), "\(receipt)")
    }

    @Test("the read-back gets no answer before the deadline: applied, unread; the choice is not replayed")
    func readBackTimesOut() async throws {
        let stack = await Self.stack(Self.colors, budget: .milliseconds(400))
        let scene = try await Self.open(stack, "Color")
        stack.page.hangs(on: "braus:read-back")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        if case .sent(.unread) = receipt {} else { Issue.record("\(receipt)") }
        #expect(stack.page.events("change") == 1)
    }

    @Test("the choice itself gets no answer: possibly sent, never confirmed by the list's closing")
    func choiceTimesOut() async throws {
        let stack = await Self.stack(Self.colors, budget: .milliseconds(400))
        let scene = try await Self.open(stack, "Color")
        stack.page.hangs(on: "braus:choose")
        let receipt = try await Self.choose("Blue #2", stack, in: scene)
        if case .possiblySent = receipt {} else { Issue.record("\(receipt)") }
    }

    // MARK: Through the engine and the recorder

    @Test("through the engine and the recorder: a kept choice passes; a choice the page puts back on a timer is unverified, its check failed, one change event, no key, nothing learned as passed")
    func throughTheEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braus-w3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = SyntheticSelectPage(setup: Self.colors + " __select('size', 'Size', [__option('S'), __option('M'), "
                                       + "__option('L')], [100, 200, 200, 24], 0);")
        page.run("var z = __selects[1]; z.addEventListener('change', function () { setTimeout(function () { z.selectedIndex = 0; }, 0); });")
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let runtime = WebEngineRuntime(knowledgeDirectory: directory, tabs: tabs)
        let app = AppContextIdentity(bundleID: "web:fixture.test")
        func act(_ target: String) async throws -> ActOutcome {
            let recorder = runtime.recorder(ActionContext(source: .app, streamID: "w3", traceID: "w3", sessionID: "s1"))
            try await recorder.begin(.act(target: target, verb: .click, value: nil, section: nil), app: app)
            let outcome = await runtime.engine(recorder: recorder, allowsDestructive: false)
                .act(ActionRequest(processID: processID, bundleID: app.bundleID, appName: "fixture.test", target: target, verb: .click))
            try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message), tool: .act,
                                   check: outcome.withStatedCheck.check)
            return outcome
        }
        _ = try await act("Color")
        let kept = try await act("Blue #2")
        #expect(kept.kind == .foundActed && kept.check?.verdict == .passed, Comment(rawValue: kept.message))
        #expect(page.read("__selects[0].selectedIndex") == "2")
        _ = try await act("Size")
        let putBack = try await act("L")
        #expect(putBack.kind == .actedUnverified && putBack.check?.verdict == .failed, Comment(rawValue: putBack.message))
        #expect(page.events("change") == 2, "one change for each choice, none replayed")
        #expect(page.keyEvents == 0, "no keyboard fallback")
        #expect(await runtime.service.flush(within: .seconds(10)))
        await runtime.service.close()
        let connectionDB = try SQLiteConnection(path: directory.appendingPathComponent("memory.sqlite").path, readOnly: true)
        defer { connectionDB.close() }
        let verdicts = try connectionDB.query("""
            SELECT o.target_label || ':' || v.verdict FROM memory_operation_verifications o
            JOIN memory_verifications v ON v.event_id = o.event_id ORDER BY o.event_id
            """) { try $0.text(0) ?? "" }
        #expect(!verdicts.contains("L:passed"), "the put-back choice is not learned as passed: \(verdicts)")
        #expect(verdicts.contains("L:failed"), "\(verdicts)")
    }
}
