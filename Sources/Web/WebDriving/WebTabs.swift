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

    struct Tab {
        let page    : WebPage
        var viewport: CGSize
        var title   : String
        /// The select whose list Braus draws, while it is open.
        var popup   : WebSelectPopup?
        /// The world the engine's scripts run in, made on the first script of each document.
        var world   : WebWorld?
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
    /// again for the document there now and the script is sent once more; any other failure is thrown
    /// as it came. Errors as `WebPage.evaluate(_:in:timeoutSeconds:)` and `page(for:)`.
    public func evaluate(
        _ script      : String,
        in processID  : pid_t,
        timeoutSeconds: Double? = nil
    ) async throws -> JSONValue {
        let page = try page(for: processID)
        if let world = state.withLock({ $0.tabs[processID]?.world }) {
            do {
                return try await page.evaluate(script, in: world, timeoutSeconds: timeoutSeconds)
            } catch CDPError.protocolError {
                state.withLock { state in
                    if state.tabs[processID]?.world == world { state.tabs[processID]?.world = nil }
                }
            }
        }
        let world = try await page.makeWorld(named: Self.worldName)
        state.withLock { $0.tabs[processID]?.world = world }
        return try await page.evaluate(script, in: world, timeoutSeconds: timeoutSeconds)
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
