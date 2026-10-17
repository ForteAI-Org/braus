import Foundation
import Testing
import WebDriver
@testable import WebDriving

/// W12: the web settler does not take a page for quiet while a request its gesture started is in flight. `prepare`
/// starts a watch of the tab's requests, `settle` waits for them and ends the watch; a watch no settle ends goes at its
/// lifetime, and no observer or `Network` domain is left. Over `SyntheticPage`, which emits the protocol's events on its
/// session and counts the commands it received, with the production settler; Chrome's own events are the Chrome tier's.
@Suite("Settling waits for the requests in flight (W12)")
struct WebRequestsTests {

    struct Watched {
        let stack  : SyntheticForm.Stack
        let page   : WebPage
        let settler: WebSettler
    }

    static func watched(lifetime: Duration = .seconds(10)) async throws -> Watched {
        let stack = await SyntheticForm.stack()
        return Watched(stack: stack, page: try stack.tabs.page(for: stack.processID),
                       settler: WebSettler(tabs: stack.tabs, lifetime: lifetime))
    }

    static func started(_ id: String, _ type: String = "Fetch", redirected: Bool = false) -> JSONValue {
        var params: [String: JSONValue] = ["requestId": .string(id), "type": .string(type)]
        if redirected { params["redirectResponse"] = ["status": 302] }
        return .object(params)
    }

    /// Settles with `cap` and answers how long it took.
    static func settle(_ watched: Watched, cap: Duration = .seconds(3)) async -> Duration {
        let started = ContinuousClock.now
        await watched.settler.settle(in: watched.stack.processID, cap: cap)
        return ContinuousClock.now - started
    }

    /// No observer left on the connection, and the domain disabled as often as it was enabled.
    static func cleaned(_ watched: Watched) async -> Bool {
        await watched.page.connection.observerCount == 0
            && watched.stack.page.count(of: "Network.enable") == watched.stack.page.count(of: "Network.disable")
    }

    /// Emits `method` for request `id` after `delay`.
    static func later(_ delay: Duration, _ method: String, _ params: JSONValue, on page: SyntheticPage) {
        Task {
            try? await Task.sleep(for: delay)
            page.emit(method, params)
        }
    }

    @Test("a fetch the gesture started, answered after 500 ms: the settler returns after it, before the cap, and leaves no observer and no domain enabled")
    func fetchInFlight() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r1"))
        Self.later(.milliseconds(500), "Network.loadingFinished", ["requestId": "r1"], on: watched.stack.page)
        let took = await Self.settle(watched)
        #expect(took >= .milliseconds(500) && took < .seconds(3), "\(took)")
        #expect(await Self.cleaned(watched) && watched.stack.page.count(of: "Network.enable") == 1)
    }

    @Test("a request that failed, or was cancelled, ends the wait as a finished one does", arguments: [false, true])
    func failed(canceled: Bool) async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r1", "XHR"))
        Self.later(.milliseconds(400), "Network.loadingFailed",
                   ["requestId": "r1", "canceled": .bool(canceled), "errorText": "net::ERR_FAILED"], on: watched.stack.page)
        let took = await Self.settle(watched)
        #expect(took >= .milliseconds(400) && took < .seconds(3), "\(took)")
        #expect(await Self.cleaned(watched))
    }

    @Test("a redirect keeps its id: one request, which ends")
    func redirect() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r1"))
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r1", redirected: true))
        Self.later(.milliseconds(400), "Network.loadingFinished", ["requestId": "r1"], on: watched.stack.page)
        let took = await Self.settle(watched)
        #expect(took >= .milliseconds(400) && took < .seconds(3), "\(took)")
    }

    @Test("an event stream, and the end of a request the watch never saw start, are not counted: the page settles as a still one")
    func notCounted() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r2", "EventSource"))
        watched.stack.page.emit("Network.loadingFinished", ["requestId": "r9"])
        let took = await Self.settle(watched)
        #expect(took < .seconds(1), "\(took)")
        #expect(await Self.cleaned(watched))
    }

    @Test("the connection closes with a request in flight: the wait ends by the cap, and no observer is left")
    func closed() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.page.emit("Network.requestWillBeSent", Self.started("r1"))
        let page = watched.stack.page
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            page.close()
        }
        let took = await Self.settle(watched, cap: .seconds(1))
        #expect(took < .milliseconds(1500), "\(took)")
        #expect(await watched.page.connection.observerCount == 0)
        #expect(await watched.page.connection.isClosed)
    }

    @Test("prepared for a gesture never sent, with no settle: at its lifetime the watch leaves no observer and disables the domain")
    func preparedNeverSettled() async throws {
        let watched = try await Self.watched(lifetime: .milliseconds(300))
        await watched.settler.prepare(in: watched.stack.processID)
        #expect(await watched.page.connection.observerCount == 1)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await Self.cleaned(watched) && watched.stack.page.count(of: "Network.disable") == 1)
    }

    @Test("two prepares for one action keep one watch, and the settle ends it")
    func preparedTwice() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        await watched.settler.prepare(in: watched.stack.processID)
        #expect(watched.stack.page.count(of: "Network.enable") == 1)
        _ = await Self.settle(watched)
        #expect(await Self.cleaned(watched))
    }

    @Test("an old watch's late end never stops the watch that replaced it")
    func staleEnd() async throws {
        let watched = try await Self.watched()
        let processID = watched.stack.processID
        await watched.settler.prepare(in: processID)
        let first = try #require(watched.stack.tabs.requests(of: processID))
        _ = await Self.settle(watched)
        await watched.settler.prepare(in: processID)
        let second = try #require(watched.stack.tabs.requests(of: processID))
        await WebSettler.end(first, of: processID, tabs: watched.stack.tabs)
        #expect(watched.stack.tabs.requests(of: processID) === second, "the new watch is still the tab's")
        #expect(await watched.page.connection.observerCount == 1)
        #expect(watched.stack.page.count(of: "Network.disable") == 1, "only the first watch's own end disabled the domain")
        _ = await Self.settle(watched)
        #expect(await Self.cleaned(watched))
    }

    @Test("the tab removed while watching: no observer is left, and the domain is disabled")
    func tabRemoved() async throws {
        let watched = try await Self.watched()
        await watched.settler.prepare(in: watched.stack.processID)
        watched.stack.tabs.remove(watched.stack.processID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Self.cleaned(watched))
    }
}
