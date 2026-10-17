//
//  WebRequests.swift
//  Braus
//

import Foundation
import Synchronization
import WebDriver

/// WebRequests is the watch of one tab's own requests in flight, for the settler (W12): a fetch, an XMLHttpRequest
/// or a document that started after the watch did and has not finished, failed or been cancelled. It keeps their
/// protocol ids only, never an address, a header or a body. A redirect keeps its id. An event stream, a socket, a
/// beacon or any other kind is not counted, since it may stay open for as long as the page lives.
///
/// The page's events are counted inline as the connection reads them (`WebPage.observe`), so once a read of the page
/// has answered, every request whose start Chrome reported before that answer is counted. A request that ends before
/// the watch heard it start, or started before the watch did, is not counted.
///
/// The watch ends at `stop`, and its count empties when its connection closes or its tab goes. It has a deadline
/// that `WebSettler` keeps: a gesture prepared for and never sent leaves no observer and no `Network` domain past it.
final class WebRequests: Sendable {

    static let counted: Set<String> = ["Fetch", "XHR", "Document"]

    /// The requests in flight, the deadline and whether the watch ended, shared with the observer.
    private final class Ledger: Sendable {

        struct State {
            var pending  : Set<String> = []
            var isClosed  = false
            var isStopped = false
            var deadline : ContinuousClock.Instant
        }

        let state: Mutex<State>

        init(deadline: ContinuousClock.Instant) {
            state = Mutex(State(deadline: deadline))
        }

        func apply(_ event: CDPEvent?) {
            state.withLock { state in
                guard let event else {
                    state.isClosed = true
                    state.pending.removeAll()
                    return
                }
                guard let id = event.params["requestId"]?.stringValue else { return }
                switch event.method {
                    case "Network.requestWillBeSent":
                        if let type = event.params["type"]?.stringValue, WebRequests.counted.contains(type) {
                            state.pending.insert(id)
                        }
                    case "Network.loadingFinished", "Network.loadingFailed":
                        state.pending.remove(id)
                    default:
                        break
                }
            }
        }
    }

    let page: WebPage
    private let key   : UUID
    private let ledger: Ledger
    /// The task that ends the watch at its deadline, cancelled when the watch stops first.
    private let expiry = Mutex<Task<Void, Never>?>(nil)

    private init(page: WebPage, key: UUID, ledger: Ledger) {
        self.page   = page
        self.key    = key
        self.ledger = ledger
    }

    /// Starts watching `page`'s requests until `stop`, with a deadline `lifetime` from now: the observer first, then
    /// the tab's `Network` domain, so no request it reports is missed. Nil when the domain could not be enabled; no
    /// observer is left then.
    static func start(on page: WebPage, lifetime: Duration) async -> WebRequests? {
        let ledger = Ledger(deadline: .now + lifetime)
        let key = await page.observe { ledger.apply($0) }
        guard (try? await page.send("Network.enable", timeoutSeconds: 2)) != nil else {
            await page.stopObserving(key)
            return nil
        }
        return WebRequests(page: page, key: key, ledger: ledger)
    }

    /// How many counted requests are in flight now.
    var inFlight: Int { ledger.state.withLock { $0.pending.count } }

    /// Whether its connection closed or its tab went: nothing more is heard.
    var isClosed: Bool { ledger.state.withLock { $0.isClosed } }

    var isStopped: Bool { ledger.state.withLock { $0.isStopped } }

    var deadline: ContinuousClock.Instant { ledger.state.withLock { $0.deadline } }

    /// Keeps the task that ends the watch at its deadline, so a `stop` before it cancels it.
    func attach(expiry task: Task<Void, Never>) {
        expiry.withLock { $0 = task }
        if isStopped { task.cancel() }
    }

    /// Moves the deadline to `lifetime` from now, when that is later.
    func extend(by lifetime: Duration) {
        ledger.state.withLock { $0.deadline = max($0.deadline, .now + lifetime) }
    }

    /// Ends the watch, once: its observer goes, then, when `disabling` and its tab is still there, the tab's `Network`
    /// domain is disabled. A watch replaced by another of the same tab is stopped without disabling, so the new one
    /// keeps the domain. A later call does nothing.
    func stop(disabling: Bool) async {
        let first = ledger.state.withLock { state in
            defer { state.isStopped = true }
            return !state.isStopped
        }
        guard first else { return }
        await page.stopObserving(key)
        ledger.state.withLock { $0.pending.removeAll() }
        if disabling, !isClosed { _ = try? await page.send("Network.disable", timeoutSeconds: 2) }
        // Last: a stop at the deadline runs in that task, and a cancelled task sends nothing.
        expiry.withLock { $0?.cancel() }
    }
}
