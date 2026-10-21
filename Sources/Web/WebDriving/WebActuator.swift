//
//  WebActuator.swift
//  Braus
//

import CoreGraphics
import EngineCore
import Foundation
import WebDriver

/// WebActuator is `Actuating` for tabs: each gesture becomes `Input` events dispatched to the page
/// over the DevTools protocol. Nothing reaches the desktop, no window has to be in front, and the
/// person's mouse and keyboard stay theirs.
///
/// A point is a CSS pixel of the viewport, which is what `WebScenes` makes a global point.
public struct WebActuator: Actuating {

    /// The pixels one line of a wheel gesture scrolls.
    static let lineHeight = 40.0
    static let dragSteps  = 8

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        try await deliver(gesture, expecting: nil, in: processID)
    }

    /// The same, for a click aimed at the element the scene names `label`: it goes out only when the page would hit
    /// that element at its point, or the node the tab is held to (W10, W09, W05).
    public func perform(_ gesture: Gesture, expecting label: String, in processID: pid_t) async throws {
        try await deliver(gesture, expecting: label, in: processID)
    }

    /// The same check for any pointer gesture over `label`: a right click and the click that focuses a field at their
    /// point, a drag at its start, a scroll at its point (W10).
    public func perform(_ gesture: Gesture, over label: String, in processID: pid_t) async throws {
        try await deliver(gesture, expecting: label, in: processID)
    }

    private func deliver(_ gesture: Gesture, expecting label: String?, in processID: pid_t) async throws {
        let page = try tabs.page(for: processID)
        // A gesture reaches only the document the scene was read from (W11), and the one it was decided on when the
        // tab is held (W05). A navigation or a reload since then is another document, and a scene whose document could
        // not be read names none: nothing is sent. A change between this check and the events is not seen.
        guard let read = tabs.document(of: processID) else {
            throw GestureNotSent(reason: "page_unread",
                                 sentence: "The page's document could not be read with its scene, so it is not known "
                                     + "whether this gesture would reach the page that was read. Observe it again "
                                     + "before acting.")
        }
        let current = try? await WebScenes.documentNode(of: page)
        if current != read || tabs.held(of: processID).map({ $0.document != current }) == true {
            throw GestureNotSent(reason: "page_changed",
                                 sentence: "The page is no longer the document that was read: it navigated or "
                                     + "reloaded. Observe it again before acting.")
        }
        if let label, let point = Self.point(of: gesture) {
            try await hitCheck(point, label: label, in: processID)
        }
        // An open select's list goes, as Chrome's own does, on Escape or on a click outside it.
        if let window = tabs.window(of: processID), let popup = window.popup {
            switch gesture {
                case .key(Key.escape, _):
                    await WebControls(tabs: tabs).closePopup(in: processID)
                    return
                case .click(let point, _, _) where !popup.frame(in: window.viewport).contains(point):
                    await WebControls(tabs: tabs).closePopup(in: processID)
                default:
                    break
            }
        }
        // What is known of the send, for the record (M05): the method, the commands planned, the ones handed to the
        // connection, the ones the browser acknowledged, and how it ended. Noted once, as the sequence ends or as a
        // command throws (the counts up to that command); a gesture of no command notes nothing, and nothing is
        // known of the wire itself.
        let events = try Self.events(for: gesture)
        guard let first = events.first, let method = WebSend.Method(rawValue: first.0) else { return }
        var attempted = 0, acknowledged = 0
        func note(_ outcome: WebSend.Outcome) {
            tabs.note(send: WebSend(method: method, planned: events.count, attempted: attempted,
                                    acknowledged: acknowledged, outcome: outcome), for: processID)
        }
        for (name, params) in events {
            attempted += 1
            do { _ = try await page.send(name, params) } catch {
                note(Self.outcome(of: error))
                throw error
            }
            acknowledged += 1
        }
        note(.completed)
    }

    /// How a sequence ended when a command threw: rejected by the browser (`protocolError`, which had no effect), or
    /// unanswered (the connection closed, the deadline passed, the call was cancelled, anything else).
    static func outcome(of error: any Error) -> WebSend.Outcome {
        if case CDPError.protocolError = error { return .rejectedByBrowser }
        return .unanswered
    }

    /// Refuses, with nothing sent, a pointer gesture at `point` that the page would not deliver to the element the
    /// scene names `label` there, or to the node the tab is held to: something is on top of it (an overlay, a banner,
    /// a frame), a scroll container clips it, or the node is gone. The page's own hit-testing decides, through open
    /// shadow roots. Several elements of that label holding the point (a link and its text) each count as the target.
    private func hitCheck(_ point: CGPoint, label: String, in processID: pid_t) async throws {
        let nodes = tabs.held(of: processID).map { [$0.node] }
            ?? tabs.targets(of: processID).filter { $0.label == label && $0.box.contains(point) }.compactMap(\.node)
        guard !nodes.isEmpty else {
            throw GestureNotSent(reason: "target_unbound",
                                 sentence: "'\(label)' has no node in the page at that point that the gesture could "
                                     + "be checked against: nothing was sent. Observe it again before acting.")
        }
        // The hit test runs in the isolated world, on the target nodes resolved there.
        let answer: JSONValue?
        do {
            answer = try await tabs.call(
                Self.hitFunction,
                in            : processID,
                arguments     : [.number(point.x), .number(point.y)],
                nodes         : nodes,
                timeoutSeconds: 5
            )
        } catch CDPError.protocolError(method: "DOM.resolveNode", _, _) {
            throw Self.gone(label)
        } catch {
            answer = nil
        }
        switch answer?["kind"]?.stringValue {
            case "target"?:
                return
            case "gone"?:
                throw Self.gone(label)
            case "covered"?:
                let cover = answer?["cover"]?.stringValue ?? "another element"
                throw GestureNotSent(reason: "target_covered",
                                     sentence: "'\(label)' is not what the page would reach at its point: \(cover) is "
                                         + "on top of it there (an overlay, a banner, or a scroll container that clips "
                                         + "it). Nothing was sent. Close or scroll away what covers it, then observe "
                                         + "again.")
            default:
                throw GestureNotSent(reason: "target_unchecked",
                                     sentence: "Whether the gesture would reach '\(label)' could not be checked in the "
                                         + "page: nothing was sent. Observe it again before acting.")
        }
    }

    /// Where a pointer gesture first reaches the page: a click's point, a drag's start, a scroll's point; nil for keys.
    static func point(of gesture: Gesture) -> CGPoint? {
        switch gesture {
            case .click(let point, _, _), .scroll(let point, _, _), .drag(let point, _): point
            case .key, .character, .type, .insert: nil
        }
    }

    private static func gone(_ label: String) -> GestureNotSent {
        GestureNotSent(reason: "target_gone",
                       sentence: "'\(label)' is no longer the element that was read: the page removed or replaced it. "
                           + "Nothing was sent. Observe it again before acting.")
    }

    /// Run in the isolated world with a viewport point and the target nodes resolved there: whether the element the
    /// page would hit there is a target or inside one. The hit goes down through open shadow roots, and up through
    /// their hosts. A text node counts as its element.
    static let hitFunction = """
    function (x, y, ...nodes) {
      /* braus:hit-test */
      const targets = nodes.map(n => n && n.nodeType === 3 ? n.parentElement : n);
      if (targets.some(t => !t || !t.isConnected)) return { kind: 'gone' };
      let hit = document.elementFromPoint(x, y);
      while (hit && hit.shadowRoot) {
        const inner = hit.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === hit) break;
        hit = inner;
      }
      for (let n = hit; n; n = n.parentNode || n.host) {
        if (targets.includes(n)) return { kind: 'target' };
      }
      if (!hit) return { kind: 'covered', cover: 'nothing of the page' };
      const role = hit.getAttribute('role') || hit.tagName.toLowerCase();
      const name = (hit.getAttribute('aria-label') || hit.getAttribute('title') || hit.textContent || '')
        .replace(/\\s+/g, ' ').trim().slice(0, 40);
      return { kind: 'covered', cover: name ? role + " '" + name + "'" : role };
    }
    """

    /// Delivery keeps no receipts.
    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}

    /// The protocol commands a gesture is delivered as, in order.
    static func events(for gesture: Gesture) throws -> [(String, JSONValue)] {
        let mouse = "Input.dispatchMouseEvent"
        let key   = "Input.dispatchKeyEvent"
        func pointer(_ type: String, _ point: CGPoint, button: String = "none", buttons: Int = 0,
                     clickCount: Int = 0) -> (String, JSONValue) {
            (mouse, ["type": .string(type), "x": .number(point.x), "y": .number(point.y),
                     "button": .string(button), "buttons": .number(Double(buttons)),
                     "clickCount": .number(Double(clickCount))])
        }
        switch gesture {
            case .click(let point, let button, let count):
                let name = button == .left ? "left" : "right"
                let mask = button == .left ? 1 : 2
                var events = [pointer("mouseMoved", point)]
                for click in 1...max(1, count) {
                    events.append(pointer("mousePressed", point, button: name, buttons: mask, clickCount: click))
                    events.append(pointer("mouseReleased", point, button: name, clickCount: click))
                }
                return events
            case .scroll(let point, let deltaY, let deltaX):
                // A wheel line up is a positive delta on macOS and a negative one in the DOM.
                return [pointer("mouseMoved", point),
                        (mouse, ["type": "mouseWheel", "x": .number(point.x), "y": .number(point.y),
                                 "deltaX": .number(-Double(deltaX) * lineHeight),
                                 "deltaY": .number(-Double(deltaY) * lineHeight)])]
            case .key(let code, let modifiers):
                return try WebKeys.press(code: code, modifiers: modifiers).map { (key, $0) }
            case .character(let character, let modifiers):
                return WebKeys.press(character: character, modifiers: modifiers).map { (key, $0) }
            case .type(let text):
                return text.flatMap { WebKeys.press(character: $0, modifiers: []) }.map { (key, $0) }
            case .insert(let text):
                return [("Input.insertText", ["text": .string(text)])]
            case .drag(let from, let to):
                var events = [pointer("mouseMoved", from),
                              pointer("mousePressed", from, button: "left", buttons: 1, clickCount: 1)]
                for step in 1...dragSteps {
                    let t = Double(step) / Double(dragSteps)
                    let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    events.append(pointer("mouseMoved", point, button: "left", buttons: 1))
                }
                events.append(pointer("mouseReleased", to, button: "left", clickCount: 1))
                return events
        }
    }
}
