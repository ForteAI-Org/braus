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
/// scene of a tab measured.
public final class WebTabs: Sendable {

    struct Tab {
        let page    : WebPage
        var viewport: CGSize
        var title   : String
        /// The select whose list Braus draws, while it is open.
        var popup   : WebSelectPopup?
    }

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
            state.tabs[id] = Tab(page: page, viewport: viewport, title: "", popup: nil)
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
