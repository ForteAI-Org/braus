//
//  RequestsLiveTests.swift
//  Braus
//

import Engine
import EngineCore
import Foundation
import PerceptionCore
import Synchronization
import TestScratch
import Testing
import WebDriver
import WebDriving

/// W12, G4b, on a real headless Chrome with a new temporary profile, removed afterwards, and the fixture
/// `requests.html` served by the test's own `FixtureHTTPServer` on 127.0.0.1: the settler waits for a fetch the click
/// started and whose body the page reads, for one that fails and for one that is aborted, and does not wait without its
/// watch. A fetch whose body the page never reads keeps the wait to its cap, a limit the protocol's events show: its
/// start and its answer come, its end does not, in the window measured. Through the engine, whose wait ends at its
/// 300 ms cap, a click on a slow fetch is answered unverified with an unknown check. Two limits are measured as known
/// issues: a timer is no request, and the engine reads the scene before an answer later than its cap. Of the protocol's events only the method, the
/// request id and the timestamp of the fetches are kept, and printed for the evidence; no address, header or body. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No external network.
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

    /// One protocol event of a fetch: its method, request id and timestamp, nothing else.
    struct FetchEvent: Sendable, Equatable {
        let method   : String
        let requestID: String
        let timestamp: Double
    }

    /// Clicks `label` as the engine does, after the settler's `prepare` when `watched`, settles with `cap`, and answers
    /// how long the settling took, how it ended, what the status reads then, and the events of the fetches the click
    /// started, which it prints for the evidence.
    static func settle(after label: String, watched: Bool = true, cap: Duration = .seconds(3), tabs: WebTabs, id: pid_t,
                       page: WebPage) async throws
        -> (took: Duration, result: SettleResult, state: String?, events: [FetchEvent]) {
        let window  = try await WebScenes(tabs: tabs).currentScene(of: id)
        let element = try WebDrivingLiveTests.element(label, in: window)
        let settler = WebSettler(tabs: tabs)
        let seen = Mutex<(fetches: Set<String>, events: [FetchEvent])>(([], []))
        _ = try await page.send("Network.enable")
        let key = await page.observe { event in
            guard let event, let requestID = event.params["requestId"]?.stringValue else { return }
            seen.withLock { seen in
                if event.method == "Network.requestWillBeSent", event.params["type"]?.stringValue == "Fetch" {
                    seen.fetches.insert(requestID)
                }
                guard seen.fetches.contains(requestID),
                      ["Network.requestWillBeSent", "Network.responseReceived", "Network.loadingFinished",
                       "Network.loadingFailed"].contains(event.method)
                else { return }
                seen.events.append(FetchEvent(method: event.method, requestID: requestID,
                                              timestamp: event.params["timestamp"]?.doubleValue ?? -1))
            }
        }
        if watched { await settler.prepare(in: id) }
        try await WebActuator(tabs: tabs).perform(.click(at: window.globalPoint(of: element)), expecting: element.label,
                                                  in: id)
        let started = ContinuousClock.now
        let result = await settler.settle(in: id, cap: cap)
        let took = ContinuousClock.now - started
        let state = try await page.evaluate("document.getElementById('state').textContent").stringValue
        await page.stopObserving(key)
        let events = seen.withLock { $0.events }
        for event in events {
            print("cdp-event \(label): \(event.method) \(event.requestID) \(event.timestamp)")
        }
        return (took, result, state, events)
    }

    @Test("a fetch the click started, answered after 600 ms, whose body the page reads: the settler returns once it ended, before the cap")
    func slowFetch() async throws {
        try await Self.withServedFixture { tabs, id, page, server in
            let settled = try await Self.settle(after: "Carica", tabs: tabs, id: id, page: page)
            #expect(settled.state == "Caricato", "settled after \(settled.took)")
            #expect(settled.result == .settled && settled.took >= .milliseconds(550) && settled.took < .seconds(3),
                    "settled after \(settled.took), \(settled.result)")
            #expect(settled.events.map(\.method) == ["Network.requestWillBeSent", "Network.responseReceived",
                                                     "Network.loadingFinished"], "\(settled.events)")
            #expect(await server.counts["/slow"] == 1)
        }
    }

    @Test("the limit: a fetch whose body the page never reads is answered, but never ends for the protocol, so the wait goes to its cap")
    func unreadBody() async throws {
        try await Self.withServedFixture { tabs, id, page, _ in
            let settled = try await Self.settle(after: "Ignora", cap: .milliseconds(1500), tabs: tabs, id: id, page: page)
            #expect(settled.state == "Ricevuto", "the headers came and resolved the page's promise")
            #expect(settled.result == .capped && settled.took >= .milliseconds(1450), "settled after \(settled.took), \(settled.result)")
            #expect(settled.events.map(\.method) == ["Network.requestWillBeSent", "Network.responseReceived"],
                    "the start and the answer came, no end: \(settled.events)")
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

    @Test("through the engine, whose wait is capped at 300 ms: the wait ends with the fetch in flight, and the click is answered unverified, its check unknown with settle_capped")
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
            #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
            #expect(outcome.check?.verdict == .unknown && outcome.check?.limits.contains(.settleCapped) == true,
                    "\(String(describing: outcome.check))")
            #expect(outcome.message.contains("ended at its cap (300 ms)"), Comment(rawValue: outcome.message))
            withKnownIssue("W12: the engine does not wait past its 300 ms cap, so the scene it read is before the answer") {
                #expect(outcome.scene?.elements.contains { $0.label == "Caricato" } == true, Comment(rawValue: outcome.message))
            }
            try await Task.sleep(for: .seconds(1))
            #expect(try await page.evaluate("document.getElementById('state').textContent").stringValue == "Caricato",
                    "the request did finish, after the engine answered")
        }
    }
}
