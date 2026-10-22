//
//  HouseRoomsKeyStop.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI

/// HouseRoomsKeyStop is the rooms grid's place in the window's Tab order.
///
/// A SwiftUI focusable view is a Tab stop on macOS only with Full Keyboard Access on, so the grid
/// would be skipped; an AppKit view that accepts first responder is a stop either way, as the rows
/// list's table is. It sits behind the rooms and takes no clicks. AppKit orders the loop by the
/// view tree, as it does for the rows list: composer, rooms, search field, conversation.
///
/// While it holds the keyboard the arrow keys call `move` and Return calls `confirm` with its
/// window; `isFocused` follows it so the grid can show it.
struct HouseRoomsKeyStop: NSViewRepresentable {

    @Binding var isFocused: Bool

    let move   : (MoveCommandDirection) -> Void
    let confirm: (NSWindow?) -> Void

    func makeNSView(context: Context) -> StopView {
        StopView()
    }

    func updateNSView(
        _ view : StopView,
        context: Context
    ) {
        view.move    = move
        view.confirm = confirm
        view.onFocus = { isFocused in
            // Reported on the next turn: AppKit changes the responder while SwiftUI is updating.
            DispatchQueue.main.async { self.isFocused = isFocused }
        }
    }

    final class StopView: NSView {

        var move   : (MoveCommandDirection) -> Void = { _ in }
        var confirm: (NSWindow?) -> Void            = { _ in }
        var onFocus: (Bool) -> Void                 = { _ in }

        override var acceptsFirstResponder: Bool { true }

        override var canBecomeKeyView: Bool { true }

        /// A click never reaches it: the rooms and the pointer keep their own behaviour.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func becomeFirstResponder() -> Bool {
            onFocus(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onFocus(false)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return super.keyDown(with: event)
            }
            switch event.keyCode {
            case 123: move(.left)
            case 124: move(.right)
            case 125: move(.down)
            case 126: move(.up)
            case 36, 76: confirm(window)
            default: super.keyDown(with: event)
            }
        }
    }
}
