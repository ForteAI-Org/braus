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
        if current != read || tabs.held(of: processID).map({ $0 != current }) == true {
            throw GestureNotSent(reason: "page_changed",
                                 sentence: "The page is no longer the document that was read: it navigated or "
                                     + "reloaded. Observe it again before acting.")
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
        for (method, params) in try Self.events(for: gesture) {
            _ = try await page.send(method, params)
        }
    }

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
