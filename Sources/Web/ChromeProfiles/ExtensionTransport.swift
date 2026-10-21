//
//  ExtensionTransport.swift
//  Braus
//

import Foundation
import Synchronization
import WebDriver

/// ExtensionTransport is `CDPTransporting` over one paired profile's Braus extension: the DevTools messages of
/// the tabs Braus opens there travel to that instance alone, which relays them with `chrome.debugger`.
///
/// It answers the few browser-level commands `WebBrowser` sends itself, for Braus's own tabs only:
/// - `Target.createTarget` opens a tab through the instance (which attaches its debugger), named `tab-<id>`;
/// - `Target.attachToTarget` gives that tab's session, `tab-<id>`;
/// - `Target.closeTarget` closes a tab Braus opened, never another;
/// - `Target.getTargets` lists Braus's tabs only;
/// - `Browser.close` closes Braus's tabs and never the browser.
/// Any other browser-level command is refused. Every command of a session goes to its tab, and every event
/// and answer comes back from it, through the hub, which routes by tab.
///
/// Ownership: a tab is Braus's when this transport opened it, or when a page of Braus's opened it (a popup the
/// instance reports). Closing the transport closes Braus's tabs that are still open. When the instance
/// disconnects or the person revokes the pairing, the transport ends without sending anything: commands still
/// waiting fail as unanswered, so their effects stay uncertain, and the person's tabs stay as they are.
///
/// Every message to the instance passes one barrier that `end` closes under the same lock: once an end or a
/// revocation returned, nothing more is dispatched, and what went out before it stays sent. A new tab and every
/// command of a tab also pass the session's `gate`, closed when the conversation's choice of profile changes:
/// from then on they are refused with nothing sent, while closing Braus's tabs still goes out.
final class ExtensionTransport: CDPTransporting {

    let incoming  : AsyncStream<Data>
    let instanceID: String
    let label     : String

    private enum Pending {
        case open(command: Int)
        case close(command: Int, tab: Int)
    }

    private struct State {
        var isClosed = false
        var tabs     : Set<Int> = []
        var popups   : Set<Int> = []
        var pending  : [String: Pending] = [:]
    }

    /// The link this transport's messages go out on; the hub accepts answers for it from this link only.
    let link: ExtensionLink

    private let hub  : ChromeProfileHub
    private let gate : CommandGate
    private let feed : AsyncStream<Data>.Continuation
    private let state = Mutex(State())
    /// The dispatch barrier: true once ended; nothing is sent to the instance after.
    private let ended = Mutex(false)

    init(hub: ChromeProfileHub, link: ExtensionLink, instanceID: String, label: String, gate: CommandGate) {
        self.hub        = hub
        self.gate       = gate
        self.link       = link
        self.instanceID = instanceID
        self.label      = label
        (incoming, feed) = AsyncStream<Data>.makeStream()
    }

    static func session(of tab: Int) -> String { "tab-\(tab)" }

    static func tab(of name: String) -> Int? {
        name.hasPrefix("tab-") ? Int(name.dropFirst(4)) : nil
    }

    // MARK: From the connection

    func send(_ message: Data) throws {
        // No check here: every message to the instance goes through `dispatch`, the one barrier `end` closes.
        let command = try JSONDecoder().decode(JSONValue.self, from: message)
        guard let id = command["id"]?.intValue, let method = command["method"]?.stringValue else { return }
        let params = command["params"] ?? .object([:])
        if let session = command["sessionId"]?.stringValue {
            guard let tab = Self.tab(of: session), state.withLock({ $0.tabs.contains(tab) }) else {
                return refuse(id, "the session \(session) is not a tab Braus opened in '\(label)'")
            }
            let admitted = try gate.admit {
                try dispatch(.object([
                    "type": .string("cdp"), "instanceId": .string(instanceID), "tabId": .number(Double(tab)),
                    "id": .number(Double(id)), "method": .string(method), "params": params,
                ]))
            }
            if !admitted { refuse(id, Self.choiceChanged(label)) }
            return
        }
        switch method {
            case "Browser.getVersion":
                answer(id, .object(["product": .string("Chrome profile '\(label)' through the Braus extension")]))
            case "Target.createTarget":
                let request = UUID().uuidString
                let admitted = try gate.admit {
                    state.withLock { $0.pending[request] = .open(command: id) }
                    hub.track(request: request, for: self)
                    try dispatch(.object([
                        "type": .string("openTab"), "requestId": .string(request), "instanceId": .string(instanceID),
                        "url": params["url"] ?? .string("about:blank"),
                    ]))
                }
                if !admitted { refuse(id, Self.choiceChanged(label)) }
            case "Target.attachToTarget":
                guard gate.isOpen else { return refuse(id, Self.choiceChanged(label)) }
                guard let tab = params["targetId"]?.stringValue.flatMap(Self.tab(of:)),
                      state.withLock({ $0.tabs.contains(tab) })
                else { return refuse(id, "not a tab Braus opened in '\(label)'") }
                answer(id, .object(["sessionId": .string(Self.session(of: tab))]))
            case "Target.closeTarget":
                guard let tab = params["targetId"]?.stringValue.flatMap(Self.tab(of:)), owns(tab) else {
                    return refuse(id, "not a tab Braus opened in '\(label)': it is not closed")
                }
                let request = UUID().uuidString
                state.withLock { $0.pending[request] = .close(command: id, tab: tab) }
                hub.track(request: request, for: self)
                try closeTab(tab, request: request)
            case "Target.getTargets":
                let tabs = state.withLock { $0.tabs.union($0.popups) }.sorted()
                answer(id, .object(["targetInfos": .array(tabs.map { tab in
                    .object(["targetId": .string(Self.session(of: tab)), "type": .string("page"),
                             "url": .string(""), "title": .string(""), "attached": .bool(true)])
                })]))
            case "Browser.close":
                closeOwnedTabs()
                answer(id, .object([:]))
            default:
                refuse(id, "\(method) is not available through the Braus extension")
        }
    }

    /// Closes Braus's tabs still open, then ends. Idempotent.
    func close() {
        guard !state.withLock({ $0.isClosed }) else { return }
        closeOwnedTabs()
        end()
    }

    // MARK: From the hub

    /// Ends without sending anything: the instance disconnected or the pairing was revoked. Idempotent.
    func end() {
        let wasEnded = ended.withLock { ended in
            defer { ended = true }
            return ended
        }
        guard !wasEnded else { return }
        state.withLock { $0.isClosed = true }
        feed.finish()
        hub.unregister(self)
    }

    /// One message of the instance for this transport: an answer to an open or a close, a DevTools answer or
    /// event of one of its tabs, a tab gone, or a popup one of its pages opened.
    func receive(_ message: JSONValue) {
        switch message["type"]?.stringValue {
            case "result":
                guard let request = message["requestId"]?.stringValue,
                      let pending = state.withLock({ $0.pending.removeValue(forKey: request) }) else { return }
                let failure = message["error"]?.stringValue ?? "the extension refused it"
                switch pending {
                    case .open(let command):
                        guard message["ok"]?.boolValue == true, let tab = message["tabId"]?.intValue else {
                            return refuse(command, failure)
                        }
                        state.withLock { _ = $0.tabs.insert(tab) }
                        hub.track(tab: tab, for: self)
                        answer(command, .object(["targetId": .string(Self.session(of: tab))]))
                    case .close(let command, let tab):
                        guard message["ok"]?.boolValue == true else { return refuse(command, failure) }
                        forget(tab)
                        answer(command, .object(["success": .bool(true)]))
                }
            case "cdpResult":
                guard let id = message["id"]?.intValue else { return }
                if let error = message["error"] {
                    yield(.object(["id": .number(Double(id)), "error": .object([
                        "code": error["code"] ?? .number(-32000),
                        "message": error["message"] ?? .string("the extension's debugger refused it"),
                    ])]))
                } else {
                    yield(.object(["id": .number(Double(id)), "result": message["result"] ?? .object([:])]))
                }
            case "cdpEvent":
                guard let tab = message["tabId"]?.intValue, let method = message["method"] else { return }
                yield(.object(["method": method, "params": message["params"] ?? .object([:]),
                               "sessionId": .string(Self.session(of: tab))]))
            case "detached", "tabClosed":
                guard let tab = message["tabId"]?.intValue, owns(tab) else { return }
                forget(tab)
                yield(.object(["method": .string("Target.detachedFromTarget"), "params": .object([
                    "sessionId": .string(Self.session(of: tab)), "targetId": .string(Self.session(of: tab)),
                ])]))
            case "popup":
                guard let tab = message["tabId"]?.intValue, let opener = message["openerTabId"]?.intValue,
                      owns(opener) else { return }
                state.withLock { _ = $0.popups.insert(tab) }
                hub.track(tab: tab, for: self)
            default:
                return
        }
    }

    // MARK: Private

    private static func choiceChanged(_ label: String) -> String {
        "not sent: the conversation's Chrome profile is no longer '\(label)'"
    }

    private func owns(_ tab: Int) -> Bool {
        state.withLock { $0.tabs.contains(tab) || $0.popups.contains(tab) }
    }

    private func forget(_ tab: Int) {
        state.withLock { state in
            state.tabs.remove(tab)
            state.popups.remove(tab)
        }
        hub.untrack(tab: tab, of: self)
    }

    /// Sends one message to the instance through the barrier: refused once `end` ran, never half way.
    private func dispatch(_ message: JSONValue) throws {
        try ended.withLock { ended in
            guard !ended else { throw ChromeProfileError.disconnected(label: label) }
            try link.send(message)
        }
    }

    private func closeTab(_ tab: Int, request: String) throws {
        try dispatch(.object([
            "type": .string("closeTab"), "requestId": .string(request), "instanceId": .string(instanceID),
            "tabId": .number(Double(tab)),
        ]))
    }

    /// Asks the instance to close every tab Braus owns, without waiting for its answers.
    private func closeOwnedTabs() {
        let owned = state.withLock { $0.tabs.union($0.popups) }
        for tab in owned {
            let request = UUID().uuidString
            try? closeTab(tab, request: request)
            forget(tab)
        }
    }

    private func answer(_ id: Int, _ result: JSONValue) {
        yield(.object(["id": .number(Double(id)), "result": result]))
    }

    private func refuse(_ id: Int, _ message: String) {
        yield(.object(["id": .number(Double(id)), "error": .object([
            "code": .number(-32000), "message": .string(message),
        ])]))
    }

    private func yield(_ message: JSONValue) {
        guard var frame = try? JSONEncoder().encode(message) else { return }
        frame.append(0)
        feed.yield(frame)
    }
}
