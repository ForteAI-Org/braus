//
//  SelectChoiceLiveTests.swift
//  Braus
//

import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W2 and W3 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture
/// `select-choices.html`, through the engine and the web roles: the option a row names (twins, long and empty
/// options), the refusals with no event (disabled, a disabled group, a replaced select, reordered options), and the
/// read-back that sees a value the page puts back synchronously, in a microtask or on a timer. The page answers
/// indices, booleans and its own event counts only. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in
/// `/Applications`; no network, no account.
@Suite(
    "Native select choices, live (W2, W3)",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct SelectChoiceLiveTests {

    static func withPage(_ body: (WebTabs, pid_t, WebPage) async throws -> Void) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-w23-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile, isHeadless: true))
        do {
            let page = try await browser.openPage()
            let url = try #require(Bundle.module.url(forResource: "select-choices", withExtension: "html"))
            try await page.navigate(to: url.absoluteString)
            let tabs = WebTabs()
            try await body(tabs, tabs.register(page), page)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    static func engine(_ tabs: WebTabs) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(
            scenes: WebScenes(tabs: tabs), actuator: WebActuator(tabs: tabs), windows: WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs), settling: WebSettler(tabs: tabs)
        ))
    }

    /// Opens the select `name` and chooses its row `row`, as two engine clicks.
    static func choose(_ row: String, in name: String, _ engine: ActionEngine, _ id: pid_t) async -> (ActOutcome, ActOutcome) {
        func click(_ target: String) async -> ActOutcome {
            await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "fixture", target: target, verb: .click))
        }
        let opened = await click(name)
        return (opened, await click(row))
    }

    static func index(_ id: String, on page: WebPage) async throws -> Int {
        try await page.evaluate("document.getElementById('\(id)').selectedIndex").intValue ?? -1
    }

    static func count(_ id: String, _ event: String, on page: WebPage) async throws -> Int {
        try await page.evaluate("window.__counts['\(id)'].\(event)").intValue ?? -1
    }

    @Test("twins, long and empty options on Chrome: each row chooses its own option, once, found and acted")
    func eachRowItsOption() async throws {
        try await Self.withPage { tabs, id, page in
            let engine = Self.engine(tabs)
            let (_, twin) = await Self.choose("Blue #2", in: "Color", engine, id)
            #expect(twin.kind == .foundActed && twin.check?.verdict == .passed, Comment(rawValue: twin.message))
            let colorIndex = try await Self.index("color", on: page)
            let colorChanges = try await Self.count("color", "change", on: page)
            #expect(colorIndex == 2 && colorChanges == 1, "index \(colorIndex), changes \(colorChanges)")
            let opened = await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "fixture", target: "Lunga", verb: .click))
            let rows = opened.scene?.elements.filter { $0.role == "AXMenuItem" }.map(\.label) ?? []
            #expect(rows.count == 3 && rows.first == "empty option", "\(rows)")
            let last = try #require(rows.last)
            let second = await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "fixture",
                                                        target: last, verb: .click))
            #expect(second.kind == .foundActed, Comment(rawValue: second.message))
            let longIndex = try await Self.index("long", on: page)
            #expect(longIndex == 2)
            let (_, empty) = await Self.choose("empty option", in: "Lunga", engine, id)
            #expect(empty.kind == .foundActed, Comment(rawValue: empty.message))
            let emptyIndex = try await Self.index("long", on: page)
            let keys = try await Self.count("color", "keydown", on: page) + Self.count("long", "keydown", on: page)
            #expect(emptyIndex == 0 && keys == 0, "index \(emptyIndex), keys \(keys)")
        }
    }

    @Test("a disabled option, an option of a disabled group, a replaced select, reordered options on Chrome: refused, no event, no key",
          arguments: ["", "", "document.getElementById('color').replaceWith(document.getElementById('color').cloneNode(true))",
                      "const c = document.getElementById('color'); c.insertBefore(c.options[3], c.options[0])"])
    func refusals(change: String) async throws {
        try await Self.withPage { tabs, id, page in
            let engine = Self.engine(tabs)
            let (select, row, name) = change.isEmpty ? ("groups", "B", "Gruppi") : ("color", "Blue #2", "Color")
            let opened = await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "fixture", target: name, verb: .click))
            #expect(opened.kind != .refused, Comment(rawValue: opened.message))
            if !change.isEmpty { _ = try await page.evaluate(change) }
            let before = try await Self.index(select, on: page)
            let chosen = await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "fixture", target: row, verb: .click))
            #expect(chosen.kind == .refused, Comment(rawValue: chosen.message))
            let after = try await Self.index(select, on: page)
            #expect(after == before)
            let changes = try await page.evaluate("document.getElementById('\(select)') ? (window.__counts['\(select)'] || {}).change || 0 : 0").intValue
            #expect(changes == 0)
            if change.isEmpty {
                let (_, group) = await Self.choose("C", in: "Gruppi", engine, id)
                #expect(group.kind == .refused, Comment(rawValue: group.message))
                let groupChanges = try await Self.count("groups", "change", on: page)
                #expect(groupChanges == 0)
            }
        }
    }

    @Test("the page puts the value back on Chrome, synchronously, in a microtask, on a timer of 0 or 100 ms, or to the twin: unverified, its check failed, one change, no key",
          arguments: [("Sincrona", "sync", "Blue"), ("Microtask", "micro", "Blue"), ("Timer zero", "timer0", "Blue"),
                      ("Timer cento", "timer100", "Blue"), ("Gemella", "twin", "Blue #2")])
    func restored(name: String, select: String, row: String) async throws {
        try await Self.withPage { tabs, id, page in
            let engine = Self.engine(tabs)
            let (_, chosen) = await Self.choose(row, in: name, engine, id)
            #expect(chosen.kind == .actedUnverified, Comment(rawValue: chosen.message))
            #expect(chosen.check?.verdict == .failed, "\(String(describing: chosen.check))")
            let changes = try await Self.count(select, "change", on: page)
            let keys = try await Self.count(select, "keydown", on: page)
            #expect(changes == 1, "one choice, no replay")
            #expect(keys == 0, "no keyboard fallback")
        }
    }
}
