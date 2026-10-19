//
//  WebDrivingLiveTests.swift
//  Braus
//

import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
import WebDriving

/// The engine roles on a real headless Chrome and the local fixture. Opt in with
/// `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No network.
@Suite(
    "Web driving, live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebDrivingLiveTests {

    static func withFixture(
        _ fixture: String = "web-scene",
        _ body   : (WebTabs, pid_t, WebPage) async throws -> Void
    ) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
        do {
            let page = try await browser.openPage()
            let url  = try #require(Bundle.module.url(forResource: fixture, withExtension: "html"))
            try await page.navigate(to: url.absoluteString)
            let tabs = WebTabs()
            try await body(tabs, tabs.register(page), page)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    static func element(_ label: String, in window: PerceivedWindow) throws -> SceneElement {
        try #require(window.scene.elements.first { $0.label == label }, "no \(label) in \(window.scene.elements.map(\.label))")
    }

    @Test("The fixture's scene: roles, values, sections, and nothing below the fold")
    func scene() async throws {
        try await Self.withFixture { tabs, id, _ in
            let window = try await WebScenes(tabs: tabs).currentScene(of: id)
            #expect(window.scene.bundleID == "web:file")
            #expect(window.scene.windowTitle == "Braus web scene")
            #expect(try Self.element("Name", in: window).role == "AXTextField")
            #expect(try Self.element("Note", in: window).role == "AXTextArea")
            #expect(try Self.element("Agree", in: window).state == .off)
            #expect(try Self.element("Color", in: window).value == "Red")
            #expect(try Self.element("Send", in: window).section == "form (Message)")
            #expect(try Self.element("Idle", in: window).kind == .text)
            #expect(window.scene.sections.map(\.name).contains("navigation (Sections)"))
            #expect(!window.scene.elements.contains { $0.label == "Far away" })
            let rows = try WebWindows(tabs: tabs).windows(ownedBy: id)
            #expect(rows.first?.frame == window.frame && rows.count == 1)
        }
    }

    @Test("Click a field, type, read it back, press Send, and see the page answer")
    func act() async throws {
        try await Self.withFixture { tabs, id, _ in
            let scenes   = WebScenes(tabs: tabs)
            let actuator = WebActuator(tabs: tabs)
            let controls = WebControls(tabs: tabs)
            let settler  = WebSettler(tabs: tabs)
            var window   = try await scenes.currentScene(of: id)

            try await actuator.perform(.click(at: window.globalPoint(of: try Self.element("Name", in: window))), in: id)
            try await actuator.perform(.type("Ada"), in: id)
            #expect(await controls.focusedFieldValue(in: id) == "Ada")
            try await actuator.perform(.character("a", modifiers: .command), in: id)
            try await actuator.perform(.insert("Grace"), in: id)
            #expect(await controls.focusedFieldValue(in: id) == "Grace")

            let agree = window.globalPoint(of: try Self.element("Agree", in: window))
            #expect(await controls.toggleState(at: agree, in: id) == .off)
            try await actuator.perform(.click(at: agree), in: id)
            #expect(await controls.toggleState(at: agree, in: id) == .on)
            #expect(await controls.controlValue(matchingAny: ["red", "blue"], in: id) == "Red")

            try await actuator.perform(.click(at: window.globalPoint(of: try Self.element("Send", in: window))), in: id)
            await settler.settle(in: id, cap: .seconds(2))
            window = try await scenes.currentScene(of: id)
            #expect(try Self.element("Sent Grace", in: window).kind == .text)
            #expect(try Self.element("Agree", in: window).state == .on)
        }
    }

    @Test("After a wheel scroll the far button is in the scene where the page paints it")
    func scroll() async throws {
        try await Self.withFixture { tabs, id, page in
            let scenes = WebScenes(tabs: tabs)
            var window = try await scenes.currentScene(of: id)
            try await WebActuator(tabs: tabs).perform(.scroll(at: CGPoint(x: 400, y: 300), deltaY: -60), in: id)
            await WebSettler(tabs: tabs).settle(in: id, cap: .seconds(2))
            window = try await scenes.currentScene(of: id)
            let far  = try Self.element("Far away", in: window)
            let rect = try await page.evaluate("JSON.stringify(document.getElementById('far').getBoundingClientRect())")
            let box  = try JSONDecoder().decode([String: Double].self, from: Data(try #require(rect.stringValue).utf8))
            let painted = CGRect(x: box["x"]!, y: box["y"]!, width: box["width"]!, height: box["height"]!)
            let point = window.globalPoint(of: far)
            #expect(painted.contains(point))
        }
    }

    @Test("A page that rewrites the DOM's methods in its own world changes nothing the engine reads")
    func hostilePage() async throws {
        try await Self.withFixture("web-hostile") { tabs, id, page in
            let controls = WebControls(tabs: tabs)
            let actuator = WebActuator(tabs: tabs)
            let window   = try await WebScenes(tabs: tabs).currentScene(of: id)
            let agree    = window.globalPoint(of: try Self.element("Agree", in: window))

            #expect(await controls.toggleState(at: agree, in: id) == .off)
            try await actuator.perform(.click(at: window.globalPoint(of: try Self.element("Name", in: window))), in: id)
            try await actuator.perform(.type("Ada"), in: id)
            #expect(await controls.focusedFieldValue(in: id) == "Ada")
            #expect(try await page.evaluate("document.getElementById('name').value") == "patched")
            #expect(await controls.pressControl(labelled: "Color", in: id))
            #expect(await controls.controlValue(matchingAny: ["red", "blue"], in: id) == "Red")
            // What the engine keeps on its world's window never reaches the page's.
            #expect(try await page.evaluate("typeof window.__brausSelect") == "undefined")
            #expect(try await page.evaluate("window.__brausProbe") == "page")
        }
    }

    @Test("Through the engine: a click opens a select's list, a click on an option chooses it")
    func select() async throws {
        try await Self.withFixture { tabs, id, page in
            let engine = ActionEngine(ActionEngine.Dependencies(
                scenes  : WebScenes(tabs: tabs),
                actuator: WebActuator(tabs: tabs),
                windows : WebWindows(tabs: tabs),
                controls: WebControls(tabs: tabs),
                settling: WebSettler(tabs: tabs)
            ))
            func click(_ target: String) async -> ActOutcome {
                await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "file", target: target,
                                               verb: .click))
            }
            _ = try await WebScenes(tabs: tabs).currentScene(of: id)

            let opened = await click("Color")
            let blue = try #require(opened.scene?.elements.first { $0.label == "Blue" }, "\(opened.message)")
            #expect(blue.role == "AXMenuItem")
            #expect(try WebWindows(tabs: tabs).windows(ownedBy: id).first?.layer == 101)

            let chose = await click("Blue")
            #expect(chose.isSuccess, "\(chose.message)")
            #expect(try await page.evaluate("document.getElementById('color').value").stringValue == "Blue")
            #expect(try await page.evaluate("document.getElementById('status').textContent").stringValue == "Color Blue")
            let window = try await WebScenes(tabs: tabs).currentScene(of: id)
            #expect(try Self.element("Color", in: window).value == "Blue")
            #expect(!window.scene.elements.contains { $0.role == "AXMenuItem" })
            #expect(try WebWindows(tabs: tabs).windows(ownedBy: id).count == 1)

            _ = await click("Color")
            _ = try await WebActuator(tabs: tabs).perform(.key(code: Key.escape), in: id)
            #expect(try WebWindows(tabs: tabs).windows(ownedBy: id).count == 1)
            #expect(try await page.evaluate("document.getElementById('color').value").stringValue == "Blue")
        }
    }
}
