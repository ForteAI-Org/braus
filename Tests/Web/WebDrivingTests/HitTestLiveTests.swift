//
//  HitTestLiveTests.swift
//  Braus
//

import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
import WebDriving

/// W10 and W09 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture
/// `hit-test.html`: a click goes out only when the page would hit, at its point, the element the scene names. Opt in
/// with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No network.
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

    @Test("a button its scroll container clips is in the scene, but not what the page would hit at its point: refused, no press")
    func clipped() async throws {
        try await WebDrivingLiveTests.withFixture("hit-test") { tabs, id, page in
            let refused = try await Self.click("Nascosto", tabs: tabs, id: id)
            #expect(refused?.reason == "target_covered", "\(String(describing: refused))")
            let counted = try await Self.counts("hidden", on: page)
            #expect(counted.downs == 0 && counted.clicks == 0)
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
