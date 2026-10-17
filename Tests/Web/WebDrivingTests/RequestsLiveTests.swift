//
//  RequestsLiveTests.swift
//  Braus
//

import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
import WebDriving

/// W12, G4b, on a real headless Chrome with a new temporary profile, removed afterwards, and the fixture
/// `requests.html` served by the test's own `FixtureHTTPServer` on 127.0.0.1: the settler waits for a fetch the click
/// started, for one that fails and for one that is aborted, and does not wait without its watch. Two limits are
/// measured as known issues: a timer is no request, and the engine's own wait ends at its 300 ms cap with the request
/// in flight. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No external network.
@Suite(
    "Requests in flight, live (W12)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct RequestsLiveTests {

    /// Runs `body` on the fixture served by a new server: the browser is closed first, then the server stopped, on
    /// success and on a throw; afterwards its port refuses connections.
    static func withServedFixture(_ body: (WebTabs, pid_t, WebPage, FixtureHTTPServer) async throws -> Void) async throws {
        let file = try #require(Bundle.module.url(forResource: "requests", withExtension: "html"))
        let server = try await FixtureHTTPServer.start(page: try String(contentsOf: file, encoding: .utf8))
        do {
            try await WebDrivingLiveTests.withFixture(at: server.url) { tabs, id, page in
                try await body(tabs, id, page, server)
            }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(FixtureHTTPServer.refuses(port: server.port), "the server's port is closed")
    }

    /// Clicks `label` as the engine does, after the settler's `prepare` when `watched`, settles with a cap of three
    /// seconds, and answers how long the settling took and what the status reads then.
    static func settle(after label: String, watched: Bool = true, tabs: WebTabs, id: pid_t, page: WebPage) async throws
        -> (took: Duration, state: String?) {
        let window  = try await WebScenes(tabs: tabs).currentScene(of: id)
        let element = try WebDrivingLiveTests.element(label, in: window)
        let settler = WebSettler(tabs: tabs)
        if watched { await settler.prepare(in: id) }
        try await WebActuator(tabs: tabs).perform(.click(at: window.globalPoint(of: element)), expecting: element.label,
                                                  in: id)
        let started = ContinuousClock.now
        await settler.settle(in: id, cap: .seconds(3))
        let took = ContinuousClock.now - started
        return (took, try await page.evaluate("document.getElementById('state').textContent").stringValue)
    }

    @Test("a fetch the click started, answered after 600 ms: the settler returns once it is answered, before the cap")
    func slowFetch() async throws {
        try await Self.withServedFixture { tabs, id, page, server in
            let settled = try await Self.settle(after: "Carica", tabs: tabs, id: id, page: page)
            #expect(settled.state == "Caricato", "settled after \(settled.took)")
            #expect(settled.took >= .milliseconds(550) && settled.took < .seconds(3), "settled after \(settled.took)")
            #expect(await server.counts["/slow"] == 1)
        }
    }

    @Test("control: the same fetch with no watch (no prepare) is not waited for")
    func unwatched() async throws {
        try await Self.withServedFixture { tabs, id, page, _ in
            let settled = try await Self.settle(after: "Carica", watched: false, tabs: tabs, id: id, page: page)
            #expect(settled.state == "Attesa!", "settled after \(settled.took)")
            #expect(settled.took < .milliseconds(550), "settled after \(settled.took)")
        }
    }

    @Test("a fetch whose connection closes with no answer fails on the page: the settler returns once it failed")
    func failedFetch() async throws {
        try await Self.withServedFixture { tabs, id, page, server in
            let settled = try await Self.settle(after: "Rompi", tabs: tabs, id: id, page: page)
            #expect(settled.state == "Errore", "settled after \(settled.took)")
            #expect(settled.took < .seconds(3), "settled after \(settled.took)")
            #expect(await server.counts["/fail", default: 0] >= 1)
        }
    }

    @Test("a fetch the page aborts after 500 ms: the settler returns once it was cancelled")
    func abortedFetch() async throws {
        try await Self.withServedFixture { tabs, id, page, _ in
            let settled = try await Self.settle(after: "Annulla", tabs: tabs, id: id, page: page)
            #expect(settled.state == "Annullato", "settled after \(settled.took)")
            #expect(settled.took >= .milliseconds(450) && settled.took < .seconds(3), "settled after \(settled.took)")
        }
    }

    @Test("the limit: a timer is no request, so a reaction 400 ms after a click that changed nothing is not waited for")
    func lateTimer() async throws {
        try await Self.withServedFixture { tabs, id, page, _ in
            let settled = try await Self.settle(after: "Attendi", tabs: tabs, id: id, page: page)
            withKnownIssue("W12: a timer is not a request; the settler returns once the page held still") {
                #expect(settled.state == "Scaduto", "settled after \(settled.took)")
            }
            #expect(settled.took < .milliseconds(400), "settled after \(settled.took)")
        }
    }

    @Test("the limit: through the engine, whose wait is capped at 300 ms, the click is judged before the 600 ms answer")
    func engineCap() async throws {
        try await Self.withServedFixture { tabs, id, page, _ in
            let engine = ActionEngine(ActionEngine.Dependencies(
                scenes  : WebScenes(tabs: tabs),
                actuator: WebActuator(tabs: tabs),
                windows : WebWindows(tabs: tabs),
                controls: WebControls(tabs: tabs),
                settling: WebSettler(tabs: tabs)
            ))
            let outcome = await engine.act(ActionRequest(processID: id, bundleID: "web:127.0.0.1", appName: "127.0.0.1",
                                                         target: "Carica", verb: .click))
            withKnownIssue("W12: the engine's 300 ms cap ends the wait with the request in flight; the verdict does not say so yet") {
                #expect(outcome.scene?.elements.contains { $0.label == "Caricato" } == true, Comment(rawValue: outcome.message))
            }
            try await Task.sleep(for: .seconds(1))
            #expect(try await page.evaluate("document.getElementById('state').textContent").stringValue == "Caricato",
                    "the request did finish, after the engine judged")
        }
    }
}
