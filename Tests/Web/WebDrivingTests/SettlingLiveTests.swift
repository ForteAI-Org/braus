//
//  SettlingLiveTests.swift
//  Braus
//

import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
import WebDriving

/// W12 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture `settle.html`:
/// the settler waits while the page's text keeps changing at one length, and the limit it keeps, a reaction that comes
/// later than its quiet window, is measured. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in
/// `/Applications`. No network.
@Suite(
    "Settling, live (W12)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct SettlingLiveTests {

    /// Prepares the settler, clicks `label` as the engine does, settles with a cap of three seconds, and answers how
    /// long the settling took and what the status reads then.
    private static func settle(after label: String, tabs: WebTabs, id: pid_t, page: WebPage) async throws
        -> (took: Duration, state: String?) {
        let window  = try await WebScenes(tabs: tabs).currentScene(of: id)
        let element = try WebDrivingLiveTests.element(label, in: window)
        let settler = WebSettler(tabs: tabs)
        await settler.prepare(in: id)
        try await WebActuator(tabs: tabs).perform(.click(at: window.globalPoint(of: element)), expecting: element.label,
                                                  in: id)
        let started = ContinuousClock.now
        await settler.settle(in: id, cap: .seconds(3))
        let took = ContinuousClock.now - started
        return (took, try await page.evaluate("document.getElementById('state').textContent").stringValue)
    }

    @Test("a text replaced every 60 ms by one of the same length, for 660 ms: the settler returns after the last one, before the cap")
    func sameLength() async throws {
        try await WebDrivingLiveTests.withFixture("settle") { tabs, id, page in
            let settled = try await Self.settle(after: "Avvia", tabs: tabs, id: id, page: page)
            #expect(settled.state == "Pronto!", "settled after \(settled.took)")
            #expect(settled.took >= .milliseconds(600) && settled.took < .seconds(3), "settled after \(settled.took)")
        }
    }

    @Test("the limit: a reaction 400 ms after a click that changed nothing before it is not waited for")
    func lateReaction() async throws {
        try await WebDrivingLiveTests.withFixture("settle") { tabs, id, page in
            let settled = try await Self.settle(after: "Carica", tabs: tabs, id: id, page: page)
            withKnownIssue("W12: the settler returns once the page held still for its quiet window") {
                #expect(settled.state == "Caricato", "settled after \(settled.took)")
            }
            #expect(settled.took < .milliseconds(400), "settled after \(settled.took)")
        }
    }
}
