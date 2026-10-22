//
//  TransparentTitleBar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// TransparentTitleBar makes its window's title bar transparent once it joins the window, so the
/// house's ground runs up under the toolbar (`HouseSplit`). It takes no clicks and draws nothing.
struct TransparentTitleBar: NSViewRepresentable {

    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(
        _ view : BridgeView,
        context: Context
    ) {}

    /// The AppKit end: it sets its window's title bar as it joins it.
    final class BridgeView: NSView {

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
        }
    }
}
