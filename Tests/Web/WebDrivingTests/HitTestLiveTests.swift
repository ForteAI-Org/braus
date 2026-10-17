//
//  HitTestLiveTests.swift
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

/// W10 and W09 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture
/// `hit-test.html`: a pointer gesture goes out only when the page would hit, at its point, the element the scene
/// names, and what a scroll container hides is not in the scene. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google
/// Chrome in `/Applications`. No network.
@Suite(
    "Hit test, live (W10, W09)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct HitTestLiveTests {

    /// Reads the scene and clicks `label` at its point, as the engine does: nil when the click went out.
    private static func click(_ label: String, tabs: WebTabs, id: pid_t) async throws -> GestureNotSent? {
        let window  = try await WebScenes(tabs: tabs).currentScene(of: id)
        let element = try WebDrivingLiveTests.element(label, in: window)
        do {
            try await WebActuator(tabs: tabs).perform(.click(at: window.globalPoint(of: element)), expecting: element.label,
                                                      in: id)
            return nil
        } catch let refused as GestureNotSent {
            return refused
        }
    }

    /// Presses that reached the document, and clicks the control `id` received.
    private static func counts(_ id: String, on page: WebPage) async throws -> (downs: Int?, clicks: Int?) {
        (try await page.evaluate("window.__downs").intValue,
         try await page.evaluate("window.__clicks['\(id)'] || 0").intValue)
    }

    @Test("a button under a dialog's backdrop: the click is refused, the backdrop named, no press reached the page")
    func covered() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let refused = try await Self.click("Sotto", tabs: tabs, id: id)
            #expect(refused?.reason == "target_covered", "\(String(describing: refused))")
            #expect(refused?.sentence.contains("Avviso cookie") == true, "\(String(describing: refused))")
            let counted = try await Self.counts("under", on: page)
            #expect(counted.downs == 0 && counted.clicks == 0)
        }
    }

    @Test("an overlay that lets pointer events through, a link and its text, a button in an open shadow root: each click goes out and lands on its control")
    func reaches() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            for (label, control) in [("Attraverso", "through"), ("Collegamento", "link"), ("Ombra", "shadow")] {
                let refused = try await Self.click(label, tabs: tabs, id: id)
                #expect(refused == nil, "\(label): \(String(describing: refused))")
                #expect(try await Self.counts(control, on: page).clicks == 1, "\(label)")
            }
        }
    }

    private static func engine(_ tabs: WebTabs) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(
            scenes  : WebScenes(tabs: tabs),
            actuator: WebActuator(tabs: tabs),
            windows : WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs),
            settling: WebSettler(tabs: tabs)
        ))
    }

    private static func input(_ input: InputRequest.Input, tabs: WebTabs, id: pid_t) async -> ActOutcome {
        await engine(tabs).deliver(InputRequest(processID: id, bundleID: "web:file", appName: "file", input: input))
    }

    /// The labels of the current scene.
    private static func labels(_ tabs: WebTabs, id: pid_t) async throws -> [String] {
        try await WebScenes(tabs: tabs).currentScene(of: id).scene.elements.map(\.label)
    }

    @Test("W09: a button its container hides is out of the scene; a scroll over the container brings it in to click")
    func clipped() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let before = try await Self.labels(tabs, id: id)
            #expect(!before.contains("Nascosto"), "hidden by its container")
            let scrolled = await Self.input(.scroll(lines: -5, over: "Inizio"), tabs: tabs, id: id)
            #expect(scrolled.kind != .refused, Comment(rawValue: scrolled.message))
            let offset = try await page.evaluate("document.getElementById('box').scrollTop").doubleValue ?? 0
            let after  = try await Self.labels(tabs, id: id)
            #expect(offset > 0 && after.contains("Nascosto"), "brought into view at \(offset)")
            let clicked = await Self.engine(tabs).act(ActionRequest(
                processID: id, bundleID: "web:file", appName: "file", target: "Nascosto", verb: .click
            ))
            #expect(clicked.kind != .refused, Comment(rawValue: clicked.message))
            #expect(try await Self.counts("hidden", on: page).clicks == 1)
        }
    }

    @Test("W09: a button its container cuts is in the scene by its seen part only, and a click there lands on it")
    func partlyClipped() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            // The button's top 20 points under the box's bottom edge: about 20 of its 40 points are seen.
            _ = try await page.evaluate("""
                (() => { const box = document.getElementById('box'), button = document.getElementById('hidden');
                  box.scrollTop = button.offsetTop - box.clientHeight + 20; return box.scrollTop; })()
                """)
            let window = try await WebScenes(tabs: tabs).currentScene(of: id)
            let element = try WebDrivingLiveTests.element("Nascosto", in: window)
            let seen = element.bounds.pixelBox(in: window.frame.size)
            #expect(seen.height > 10 && seen.height < 30, "only its seen part: \(seen)")
            let refused = try await Self.click("Nascosto", tabs: tabs, id: id)
            #expect(refused == nil, "\(String(describing: refused))")
            #expect(try await Self.counts("hidden", on: page).clicks == 1)
        }
    }

    @Test("W09: a button its inner container shows is out of the scene while the outer container hides the inner one")
    func nestedClipping() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let below = try await Self.labels(tabs, id: id)
            #expect(!below.contains("Annidato"), "below the inner container's view")
            _ = try await page.evaluate("document.getElementById('inner').scrollTop = 1000")
            let shown = try await Self.labels(tabs, id: id)
            #expect(shown.contains("Annidato"), "the inner container shows it")
            _ = try await page.evaluate("document.getElementById('outer').scrollTop = 140")
            let hidden = try await Self.labels(tabs, id: id)
            #expect(!hidden.contains("Annidato"), "the outer container hides the inner")
            _ = try await page.evaluate("document.getElementById('outer').scrollTop = 0")
            let back = try await Self.labels(tabs, id: id)
            #expect(back.contains("Annidato"))
            let refused = try await Self.click("Annidato", tabs: tabs, id: id)
            #expect(refused == nil, "\(String(describing: refused))")
            #expect(try await Self.counts("nested", on: page).clicks == 1)
        }
    }

    /// Context menus, wheel turns and key presses that reached the page, and the two fields' values.
    private static func reached(
        on page: WebPage
    ) async throws -> (menus: Int?, wheels: Int?, keys: Int?, covered: String?) {
        (try await page.evaluate("Object.values(window.__menus).reduce((a, b) => a + b, 0)").intValue,
         try await page.evaluate("window.__wheels").intValue,
         try await page.evaluate("window.__keys").intValue,
         try await page.evaluate("document.getElementById('covered-field').value").stringValue)
    }

    @Test("W10: under the backdrop a right click, typing, a scroll and a drag are refused; nothing reaches the page")
    func pointerGesturesCovered() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let engine = Self.engine(tabs)
            let outcomes = [
                await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "file", target: "Sotto",
                                               verb: .rightClick)),
                await Self.input(.typeText("Grace", into: "Campo coperto", replacing: true), tabs: tabs, id: id),
                await Self.input(.scroll(lines: -2, over: "Sotto"), tabs: tabs, id: id),
                await Self.input(.drag(from: "Sotto", to: .offset(dx: 0, dy: 200)), tabs: tabs, id: id),
            ]
            for outcome in outcomes {
                #expect(outcome.kind == .refused && outcome.message.contains("Avviso cookie"),
                        Comment(rawValue: outcome.message))
            }
            let reached = try await Self.reached(on: page)
            #expect(reached.menus == 0 && reached.wheels == 0 && reached.keys == 0 && reached.covered == "",
                    "\(reached)")
            #expect(try await Self.counts("under", on: page).downs == 0)
        }
    }

    @Test("W10: the same gestures where nothing covers the target go out: a context menu, the typed text, a wheel turn")
    func pointerGesturesReach() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let menu = await Self.engine(tabs).act(ActionRequest(processID: id, bundleID: "web:file", appName: "file",
                                                                 target: "Attraverso", verb: .rightClick))
            #expect(menu.kind != .refused, Comment(rawValue: menu.message))
            #expect(try await page.evaluate("window.__menus['through'] || 0").intValue == 1)
            let typed = await Self.input(.typeText("Grace", into: "Campo libero", replacing: true), tabs: tabs, id: id)
            #expect(typed.kind != .refused, Comment(rawValue: typed.message))
            #expect(try await page.evaluate("document.getElementById('free-field').value").stringValue == "Grace")
            let scrolled = await Self.input(.scroll(lines: -1, over: "Inizio"), tabs: tabs, id: id)
            #expect(scrolled.kind != .refused, Comment(rawValue: scrolled.message))
            let wheels = try await page.evaluate("window.__wheels").intValue ?? 0
            #expect(wheels >= 1)
        }
    }

    @Test("through the engine: a click on the covered button is refused, nothing was sent")
    func throughTheEngine() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let engine = ActionEngine(ActionEngine.Dependencies(
                scenes  : WebScenes(tabs: tabs),
                actuator: WebActuator(tabs: tabs),
                windows : WebWindows(tabs: tabs),
                controls: WebControls(tabs: tabs),
                settling: WebSettler(tabs: tabs)
            ))
            let outcome = await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "file",
                                                         target: "Sotto", verb: .click))
            #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
            #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
            let counted = try await Self.counts("under", on: page)
            #expect(counted.downs == 0)
        }
    }
}
