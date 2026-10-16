//
//  AriaListboxLiveTests.swift
//  Braus
//

import AutomationRuntime
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving
@testable import WebSession

/// W05 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture
/// `aria-listbox.html`: `select` on ARIA combo boxes whose lists open in the page, through the session's choice, the
/// engine and the web roles, with a temporary memory. The page answers indices and its own counts of option clicks
/// and keys only. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`; no network, no account.
@Suite(
    "ARIA lists in the page, live (W05)",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
@MainActor
struct AriaListboxLiveTests {

    static func withPage(_ body: (WebPage, (String, String) async throws -> ActOutcome) async throws -> Void) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-w05-\(UUID().uuidString)", directoryHint: .isDirectory)
        let memory = FileManager.default.temporaryDirectory.appending(path: "braus-w05-memory-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: profile)
            try? FileManager.default.removeItem(at: memory)
        }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile, isHeadless: true))
        do {
            let page = try await browser.openPage()
            let url = try #require(Bundle.module.url(forResource: "aria-listbox", withExtension: "html"))
            try await page.navigate(to: url.absoluteString)
            let tabs = WebTabs()
            let processID = tabs.register(page)
            let runtime = WebEngineRuntime(knowledgeDirectory: memory, tabs: tabs)
            let recorder = runtime.recorder(ActionContext(source: .app, streamID: "w05", traceID: "w05", sessionID: "s1"))
            try await body(page) { control, item in
                try await WebAutomationSession.select(control: control, item: item, processID: processID,
                                                      runtime: runtime) { target in
                    await runtime.engine(recorder: recorder, allowsDestructive: false)
                        .act(ActionRequest(processID: processID, bundleID: "web:file", appName: "fixture",
                                           target: target, verb: .click))
                }
            }
            await runtime.service.close()
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    static func number(_ expression: String, on page: WebPage) async throws -> Int {
        try await page.evaluate(expression).intValue ?? -99
    }

    @Test("an option of an ARIA list is chosen by one click on it, and the control's value read back passes the check")
    func chosen() async throws {
        try await Self.withPage { page, select in
            let outcome = try await select("Colore", "Blu")
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.check?.condition == .valueReadBack && outcome.check?.verdict == .passed)
            let chosen = try await Self.number("window.__chosen.colore", on: page)
            let clicks = try await Self.number("window.__clicks.colori", on: page)
            let keys = try await Self.number("window.__keys", on: page)
            #expect(chosen == 1 && clicks == 1 && keys == 0, "chosen \(chosen), clicks \(clicks), keys \(keys)")
        }
    }

    @Test("twins: the name alone is refused with no click in the list; the ordinal the scene shows chooses the second")
    func twins() async throws {
        try await Self.withPage { page, select in
            let alone = try await select("Gemelli", "Blue")
            #expect(alone.kind == .refused, Comment(rawValue: alone.message))
            #expect(try await Self.number("window.__clicks['gemelli-list']", on: page) == 0)
            // The list is still open from the refused choice: close it so the next choice opens it again.
            _ = try await page.evaluate("document.getElementById('gemelli').click()")
            let second = try await select("Gemelli", "Blue #2")
            #expect(second.kind == .foundActed, Comment(rawValue: second.message))
            let chosen = try await Self.number("window.__chosen.gemelli", on: page)
            #expect(chosen == 2, "the second Blue, index 2, not \(chosen)")
        }
    }

    @Test("a disabled option is refused, and an option the list does not have is an honest miss: no click in the list")
    func refusals() async throws {
        try await Self.withPage { page, select in
            let disabled = try await select("Taglia", "M")
            #expect(disabled.kind == .refused, Comment(rawValue: disabled.message))
            #expect(try await Self.number("window.__clicks.taglie", on: page) == 0)
            #expect(try await Self.number("window.__chosen.taglia", on: page) == 0)
            _ = try await page.evaluate("document.getElementById('taglia').click()")
            let missing = try await select("Colore", "Viola")
            #expect(missing.kind == .honestMiss, Comment(rawValue: missing.message))
            #expect(try await Self.number("window.__clicks.colori", on: page) == 0)
        }
    }

    @Test("a control that puts its value back 100 ms after the choice fails the check, with one click and no replay")
    func restored() async throws {
        try await Self.withPage { page, select in
            let outcome = try await select("Ripristino", "Blu")
            #expect(outcome.kind == .actedUnverified && outcome.check?.verdict == .failed, Comment(rawValue: outcome.message))
            #expect(outcome.check?.observed == "Rosso")
            #expect(try await Self.number("window.__clicks.ripristini", on: page) == 1)
        }
    }

    @Test("a button that opens no list answers its click as before: nothing chosen, no click in any list")
    func noList() async throws {
        try await Self.withPage { page, select in
            let outcome = try await select("Aiuto", "Blu")
            #expect(outcome.check?.condition != .valueReadBack, Comment(rawValue: outcome.message))
            #expect(try await Self.number("window.__clicks.colori", on: page) == 0)
        }
    }
}
