//
//  GazeTracker.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// GazeTracker is a view that never takes a click and tells a `WorkerGaze` where the pointer is while
/// it is over the view, grown by `outset` points on every side. It costs nothing at rest: a tracking
/// area reports moves only while the pointer is inside, and a display link runs only between a move
/// and the next frame, so a burst of moves reaches the gaze once per frame.
struct GazeTracker: NSViewRepresentable {
    let gaze     : WorkerGaze
    var isEnabled: Bool    = true
    var outset   : CGFloat = 0

    func makeNSView(context: Context) -> TrackingView {
        TrackingView()
    }

    func updateNSView(
        _ view : TrackingView,
        context: Context
    ) {
        view.gaze      = gaze
        view.outset    = outset
        gaze.isEnabled = isEnabled
    }

    /// TrackingView owns the tracking area and the display link.
    final class TrackingView: NSView {
        var gaze: WorkerGaze?

        /// Points past the view's bounds the pointer is still followed.
        var outset: CGFloat = 0 {
            didSet { if outset != oldValue { updateTrackingAreas() } }
        }

        private var pending: CGPoint?
        private var link   : CADisplayLink?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow]
            if outset == 0 { options.insert(.inVisibleRect) }
            addTrackingArea(NSTrackingArea(
                rect    : bounds.insetBy(
                    dx: -outset,
                    dy: -outset
                ),
                options : options,
                owner   : self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            moved(to: event.locationInWindow)
        }

        override func mouseMoved(with event: NSEvent) {
            moved(to: event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) {
            stop()
            gaze?.pointerLeft()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stop()
                gaze?.pointerLeft(after: 0)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func moved(to point: CGPoint) {
            pending = point
            if link == nil {
                let link = displayLink(
                    target  : self,
                    selector: #selector(frame(_:))
                )
                link.add(
                    to     : .main,
                    forMode: .common
                )
                self.link = link
            }
            link?.isPaused = false
        }

        @objc private func frame(_ link: CADisplayLink) {
            link.isPaused = true
            guard let point = pending else { return }
            pending = nil
            gaze?.pointerMoved(toWindow: point)
        }

        private func stop() {
            link?.invalidate()
            link    = nil
            pending = nil
        }
    }
}
