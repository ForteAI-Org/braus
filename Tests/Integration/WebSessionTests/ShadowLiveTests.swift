//
//  ShadowLiveTests.swift
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

/// W08 on a real headless Chrome with a new temporary profile and memory, removed afterwards, and the local fixture
/// `shadow.html`: an ARIA combo box whose list is in the same open shadow root, a custom element that is a switch by its
/// own role, and a native select in an open shadow root, chosen and clicked through the session's choice, the engine and
/// the web roles. The page answers by value what was chosen. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome
/// in `/Applications`; no network, no account.
@Suite(
    "Shadow DOM and custom controls, live (W08)",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
@MainActor
struct ShadowLiveTests {

    typealias Act = (String) async -> ActOutcome
    typealias Choose = (String, String) async throws -> ActOutcome

    /// Runs `body` on the fixture with a click and a choice through the engine; the browser is closed on success and on
    /// a throw, as `AriaListboxLiveTests.withPage` does.
    static func withPage(_ body: (WebPage, WebScenes, pid_t, Act, Choose) async throws -> Void) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-w08-\(UUID().uuidString)", directoryHint: .isDirectory)
        let memory = FileManager.default.temporaryDirectory.appending(path: "braus-w08-memory-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: profile)
            try? FileManager.default.removeItem(at: memory)
        }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile, isHeadless: true))
        do {
            let page = try await browser.openPage()
            let url = try #require(Bundle.module.url(forResource: "shadow", withExtension: "html"))
            try await page.navigate(to: url.absoluteString)
            let tabs = WebTabs()
            let processID = tabs.register(page)
            let runtime = WebEngineRuntime(knowledgeDirectory: memory, tabs: tabs)
            let recorder = runtime.recorder(ActionContext(source: .app, streamID: "w08", traceID: "w08", sessionID: "s1"))
            let click: Act = { target in
                await runtime.engine(recorder: recorder, allowsDestructive: false)
                    .act(ActionRequest(processID: processID, bundleID: "web:file", appName: "fixture", target: target,
                                       verb: .click))
            }
            try await body(page, runtime.scenes, processID, click) { control, item in
                try await WebAutomationSession.select(control: control, item: item, processID: processID, runtime: runtime,
                                                      click: click)
            }
            await runtime.service.close()
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    static func chosen(_ key: String, on page: WebPage) async throws -> String? {
        try await page.evaluate("window.__chosen.\(key)").stringValue
    }

    @Test("the scene: the combo box in a shadow root, the custom switch by its role and state, the select in a shadow root")
    func scene() async throws {
        try await Self.withPage { _, scenes, id, _, _ in
            let elements = try await scenes.currentScene(of: id).scene.elements
            let byLabel = Dictionary(elements.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
            #expect(byLabel["Taglia"]?.kind == .control, "\(elements.map(\.label))")
            #expect(byLabel["Notifiche"]?.role == "AXCheckBox" && byLabel["Notifiche"]?.state == .off, "\(elements.map(\.label))")
            #expect(byLabel["Colore"]?.kind == .control, "\(elements.map(\.label))")
        }
    }

    @Test("select on the ARIA combo box whose list is in its shadow root, named by aria-controls: chosen, and read back")
    func ariaInShadow() async throws {
        try await Self.withPage { page, _, _, _, select in
            let outcome = try await select("Taglia", "M")
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.check?.condition == .valueReadBack && outcome.check?.verdict == .passed,
                    Comment(rawValue: outcome.message))
            #expect(try await Self.chosen("taglia", on: page) == "M")
        }
    }

    @Test("a custom element that is a switch by its role: one click turns it on")
    func customSwitch() async throws {
        try await Self.withPage { page, scenes, id, click, _ in
            let outcome = await click("Notifiche")
            #expect(outcome.kind != .refused && outcome.kind != .honestMiss, Comment(rawValue: outcome.message))
            #expect(try await page.evaluate("document.querySelector('x-switch').getAttribute('aria-checked')").stringValue == "true")
            let state = try await scenes.currentScene(of: id).scene.elements.first { $0.label == "Notifiche" }?.state
            #expect(state == .on)
        }
    }

    @Test("select on a native select in a shadow root: chosen, and the page reads it")
    func nativeInShadow() async throws {
        try await Self.withPage { page, _, _, _, select in
            let outcome = try await select("Colore", "Blu")
            #expect(outcome.isSuccess, Comment(rawValue: outcome.message))
            #expect(try await Self.chosen("colore", on: page) == "Blu")
        }
    }
}
