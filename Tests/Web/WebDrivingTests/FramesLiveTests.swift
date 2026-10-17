//
//  FramesLiveTests.swift
//  Braus
//

import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
import WebDriving

/// W07 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture `frames.html`:
/// a button "Invia" in the page and one of that name in a frame, a "Paga" only in the frame, and a frame over a button.
/// The frame's contents are not read, so a click reaches the main document's button only, a target only in the frame is
/// a miss, and a frame on top of a button refuses its click. The frame reports its own clicks to the page by message.
/// Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No network.
@Suite(
    "Frames, live (W07)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct FramesLiveTests {

    private static func click(_ target: String, tabs: WebTabs, id: pid_t) async -> ActOutcome {
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes  : WebScenes(tabs: tabs),
            actuator: WebActuator(tabs: tabs),
            windows : WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs),
            settling: WebSettler(tabs: tabs)
        ))
        return await engine.act(ActionRequest(processID: id, bundleID: "web:file", appName: "file", target: target,
                                              verb: .click))
    }

    /// The clicks a main document's button got, and the ones a frame's button reported, once a message had time to come.
    private static func clicks(_ id: String, on page: WebPage) async throws -> (main: Int?, frame: Int?) {
        try await Task.sleep(for: .milliseconds(200))
        return (try await page.evaluate("window.__clicks['\(id)'] || 0").intValue,
                try await page.evaluate("window.__frameClicks['\(id)'] || 0").intValue)
    }

    @Test("the scene: one Invia, the page's own; each frame a section whose contents are not read; nothing of a frame's")
    func scene() async throws {
        try await WebDrivingLiveTests.withFixture("frames") { tabs, id, _ in
            let window = try await WebScenes(tabs: tabs).currentScene(of: id)
            let labels = window.scene.elements.map(\.label)
            #expect(labels.filter { $0.hasPrefix("Invia") } == ["Invia"], "\(labels)")
            #expect(!labels.contains("Paga") && !labels.contains("Annuncio"), "\(labels)")
            let sections = window.scene.sections.map(\.name)
            #expect(sections.contains("frame, contents not read (Pagamento)"), "\(sections)")
            #expect(sections.contains("frame, contents not read (Pubblicità)"), "\(sections)")
        }
    }

    @Test("a click on Invia reaches the page's button only; the frame's Invia gets nothing")
    func sameName() async throws {
        try await WebDrivingLiveTests.withFixture("frames") { tabs, id, page in
            let outcome = await Self.click("Invia", tabs: tabs, id: id)
            #expect(outcome.kind != .refused && outcome.kind != .honestMiss, Comment(rawValue: outcome.message))
            let counted = try await Self.clicks("send", on: page)
            #expect(counted.main == 1 && counted.frame == 0, "main \(String(describing: counted.main)), frame \(String(describing: counted.frame))")
        }
    }

    @Test("Paga, only in a frame, is a miss, and nothing is clicked in the frame")
    func onlyInTheFrame() async throws {
        try await WebDrivingLiveTests.withFixture("frames") { tabs, id, page in
            let outcome = await Self.click("Paga", tabs: tabs, id: id)
            #expect(outcome.kind == .honestMiss, Comment(rawValue: outcome.message))
            let counted = try await Self.clicks("pay", on: page)
            #expect(counted.frame == 0)
        }
    }

    @Test("a button under a frame: the click is refused, the frame named, nothing sent")
    func underAFrame() async throws {
        try await WebDrivingLiveTests.withFixture("frames") { tabs, id, page in
            let outcome = await Self.click("Sotto il frame", tabs: tabs, id: id)
            #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
            #expect(outcome.message.contains("Pubblicità") && outcome.message.contains("nothing was sent"),
                    Comment(rawValue: outcome.message))
            let counted = try await Self.clicks("under", on: page)
            #expect(counted.main == 0)
        }
    }
}
