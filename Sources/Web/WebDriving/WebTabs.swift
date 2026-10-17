//
//  WebTabs.swift
//  Braus
//

import CoreGraphics
import Foundation
import Synchronization
import WebDriver

/// WebTabs names each driven tab with a synthetic process id, because every engine role is keyed by
/// one. The ids are negative, so none can be taken for a running process's.
///
/// It also keeps what the window listing must answer synchronously: the viewport and title the last
/// scene of a tab measured, and the isolated world the engine's scripts run in (`evaluate`).
public final class WebTabs: Sendable {

    /// One element of a tab's last scene, as a click aimed at it is checked: its label as the scene shows it, its box
    /// in viewport CSS pixels, and its DOM node, nil for one the page has no node for (a row of a list Braus draws).
    struct Target: Sendable {
        let label: String
        let box  : CGRect
        let node : Int?
    }

    struct Tab {
        let page    : WebPage
        var viewport: CGSize
        var title   : String
        /// The select whose list Braus draws, while it is open.
        var popup   : WebSelectPopup?
        /// The world the engine's scripts run in, made on the first script of each document.
        var world   : WebWorld?
        /// The document node the last scene was read from, nil when none was read or it could not be (W11).
        var document: Int?
        /// The elements of the last scene, for the check of a click (W10).
        var targets : [Target] = []
        /// The node, and its document, a gesture under way was decided on by a read before the engine's own: a click
        /// reaches that node only, and no gesture reaches another document, even when the engine's read saw it (W05).
        var held    : (document: Int, node: Int)?
    }

    /// The name Chrome shows for the engine's world in the DevTools context list.
    static let worldName = "braus"

    struct State {
        var tabs  : [pid_t: Tab] = [:]
        var nextID: pid_t        = -100
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers a page and returns the id the engine addresses it by. `viewport` is the size the
    /// window listing reports until a scene measures the real one.
    public func register(_ page: WebPage, viewport: CGSize = CGSize(width: 1280, height: 720)) -> pid_t {
        state.withLock { state in
            let id = state.nextID
            state.nextID -= 1
            state.tabs[id] = Tab(page: page, viewport: viewport, title: "", popup: nil, world: nil)
            return id
        }
    }

    /// Forgets a tab. Its id is never handed out again.
    public func remove(_ processID: pid_t) {
        state.withLock { _ = $0.tabs.removeValue(forKey: processID) }
    }

    /// The page behind an id. Throws `WebDrivingError.unknownTab` for an id never registered or removed.
    public func page(for processID: pid_t) throws -> WebPage {
        guard let tab = state.withLock({ $0.tabs[processID] }) else { throw WebDrivingError.unknownTab(processID) }
        return tab.page
    }

    /// The ids of the registered tabs, newest last.
    public var processIDs: [pid_t] {
        state.withLock { $0.tabs.keys.sorted(by: >) }
    }

    /// Runs one of the engine's scripts in the tab's isolated world, never the page's own, so nothing
    /// the page redefined changes what it reads and nothing it sets reaches the page's globals.
    ///
    /// The world is made on the first script of a document and kept for the next ones. A call Chrome
    /// refuses ran nothing, which is what a world whose document has gone answers, so the world is made
    /// again for the document there now and the script is sent once more; a refusal while the world's
    /// document is still there, and any other failure, is thrown as it came. Errors as
    /// `WebPage.evaluate(_:in:timeoutSeconds:)` and `page(for:)`.
    public func evaluate(
        _ script      : String,
        in processID  : pid_t,
        timeoutSeconds: Double? = nil
    ) async throws -> JSONValue {
        try await inWorld(of: processID) { page, world in
            try await page.evaluate(script, in: world, timeoutSeconds: timeoutSeconds)
        }
    }

    /// The backend id of the DOM node `expression` evaluates to in the tab's isolated world, nil for anything
    /// else: how a node a script found there is named to the DevTools protocol. Retried and thrown as `evaluate`.
    func node(of expression: String, in processID: pid_t) async throws -> Int? {
        try await inWorld(of: processID) { page, world in
            try await page.node(of: expression, in: world)
        }
    }

    /// Calls `function` in the tab's isolated world with `arguments` by value and then the DOM nodes `nodes`
    /// (backend ids) resolved in that world (`WebPage.call(_:in:arguments:nodes:timeoutSeconds:)`). Retried and
    /// thrown as `evaluate`.
    func call(
        _ function    : String,
        in processID  : pid_t,
        arguments     : [JSONValue] = [],
        nodes         : [Int] = [],
        timeoutSeconds: Double? = nil
    ) async throws -> JSONValue {
        try await inWorld(of: processID) { page, world in
            try await page.call(function, in: world, arguments: arguments, nodes: nodes, timeoutSeconds: timeoutSeconds)
        }
    }

    /// Runs `call` with the tab's world, made for the document there now when the tab has none or Chrome
    /// refused the kept one, as `evaluate` says.
    private func inWorld<Value>(
        of processID: pid_t,
        _ call      : (WebPage, WebWorld) async throws -> Value
    ) async throws -> Value {
        let page = try page(for: processID)
        if let world = state.withLock({ $0.tabs[processID]?.world }) {
            do {
                return try await call(page, world)
            } catch let error as CDPError {
                // A world whose document is still there refused the call itself, a node gone: it stays.
                guard case .protocolError = error, (try? await page.holds(world)) != true else { throw error }
                state.withLock { state in
                    if state.tabs[processID]?.world == world { state.tabs[processID]?.world = nil }
                }
            }
        }
        let world = try await page.makeWorld(named: Self.worldName)
        state.withLock { $0.tabs[processID]?.world = world }
        return try await call(page, world)
    }

    func note(viewport: CGSize, title: String, for processID: pid_t) {
        state.withLock { state in
            state.tabs[processID]?.viewport = viewport
            state.tabs[processID]?.title    = title
        }
    }

    func window(of processID: pid_t) -> (viewport: CGSize, title: String, popup: WebSelectPopup?)? {
        state.withLock { state in state.tabs[processID].map { ($0.viewport, $0.title, $0.popup) } }
    }

    func setPopup(_ popup: WebSelectPopup?, for processID: pid_t) {
        state.withLock { $0.tabs[processID]?.popup = popup }
    }

    /// Keeps the document node a scene was read from, nil when it could not be read.
    func note(document: Int?, for processID: pid_t) {
        state.withLock { $0.tabs[processID]?.document = document }
    }

    /// The document node the last scene of the tab was read from.
    func document(of processID: pid_t) -> Int? {
        state.withLock { $0.tabs[processID]?.document }
    }

    /// Keeps the elements of a scene, for the check of a click.
    func note(targets: [Target], for processID: pid_t) {
        state.withLock { $0.tabs[processID]?.targets = targets }
    }

    /// The elements of the last scene of the tab.
    func targets(of processID: pid_t) -> [Target] {
        state.withLock { $0.tabs[processID]?.targets ?? [] }
    }

    /// Holds the tab to node `node` of document node `document` until it is held to nil.
    func hold(_ held: (document: Int, node: Int)?, for processID: pid_t) {
        state.withLock { $0.tabs[processID]?.held = held }
    }

    /// The node, and its document, the tab is held to, if any.
    func held(of processID: pid_t) -> (document: Int, node: Int)? {
        state.withLock { $0.tabs[processID]?.held }
    }
}

/// WebDrivingError is what a web role throws on its own account; protocol failures pass through as
/// `CDPError`.
public enum WebDrivingError: Error, Sendable, Equatable {

    /// No registered tab has this id.
    case unknownTab(pid_t)
    /// A key code the web actuator has no DOM key for.
    case unsupportedKey(UInt16)
    /// Chrome answered a read without the part the scene needs.
    case unreadablePage(String)
}
