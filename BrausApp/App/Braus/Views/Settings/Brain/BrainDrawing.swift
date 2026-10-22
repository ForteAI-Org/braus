//
//  BrainDrawing.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI

/// BrainDrawing is a view AppKit draws through `draw`, in a context whose origin is at the top left,
/// again each time SwiftUI updates it. The Brain's graph draws in it rather than in a `Canvas`: once a
/// process has drawn through SwiftUI's RenderBox, it keeps working at every frame any window animates.
/// It takes no clicks; the view around it does.
struct BrainDrawing: NSViewRepresentable {
    let draw: (CGContext, CGSize) -> Void

    func makeNSView(context: Context) -> DrawingView {
        DrawingView()
    }

    func updateNSView(
        _ view : DrawingView,
        context: Context
    ) {
        view.draw         = draw
        view.needsDisplay = true
    }

    /// DrawingView calls its `draw` for the whole of its bounds.
    final class DrawingView: NSView {
        var draw: ((CGContext, CGSize) -> Void)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            draw?(
                context,
                bounds.size
            )
        }
    }
}
