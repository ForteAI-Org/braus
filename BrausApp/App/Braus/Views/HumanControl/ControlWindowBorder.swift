//
//  ControlWindowBorder.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import QuartzCore

/// ControlWindowBorder marks the lent window, which is another application's, as the person's: the
/// neon (`NeonTube`) in the waiting blue, in a click-through panel that covers the window's screen.
/// Every click passes through it, and nothing is drawn over the window itself.
///
/// A move or a resize only moves or stretches the neon's layer: nothing is drawn again, and the panel
/// keeps its frame, since setting a window's frame waits for the window server's next turn. Nothing
/// moves at rest.
///
/// Over a window redrawing at 60 or 120 Hz the border cost the window server no CPU and the GPU 2 to 3
/// points of use, within the noise; four strips that left the window bare measured the same. A panel
/// the window's size, or four along its edges, moved by their frames, took 7 % of a core instead of
/// 2 % to follow a drag, and the window server 7 points more during a resize.
///
/// It tracks nothing: the caller gives the window's frame and each new one, in AppKit's screen space
/// (y up from the bottom of the main screen, as `NSWindow.frame`).
final class ControlWindowBorder {

    private let panel = HumanControlPanel.make(ignoresMouse: true)
    private let tube  = NeonTube(holder: .person)

    private var neon: CALayer { tube.layer }

    init() {
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        neon.opacity = 0
        view.layer?.addSublayer(neon)
    }

    /// How long the border fades as its window leaves the stage or comes back, and as the worker leaves.
    static let quick  : CFTimeInterval = 0.15
    static let leaving: CFTimeInterval = 0.4

    /// The number of the last show or hide: a fade that ends after a later show leaves the border on.
    private var changes = 0

    /// Whether the border is on screen, a fade out included.
    var isShown: Bool { panel.isVisible }

    /// Draws the border around `frame` and puts it on screen, fading in when it was off.
    func show(frame: CGRect) {
        update(frame: frame)
        changes += 1
        guard !panel.isVisible || neon.opacity < 1 else { return }
        fade(
            to  : 1,
            over: Self.quick
        )
        panel.orderFrontRegardless()
    }

    /// Moves the border to `frame`, shown or not.
    func update(frame: CGRect) {
        let screen = Self.screen(holding: frame)
        if panel.frame != screen {
            panel.setFrame(
                screen,
                display: false
            )
        }
        tube.place(around: frame.offsetBy(
            dx: -screen.minX,
            dy: -screen.minY
        ))
    }

    /// Takes the border off screen, fading over `fade` seconds first.
    func hide(fade duration: CFTimeInterval = 0) {
        changes += 1
        guard panel.isVisible else { return }
        guard duration > 0 else {
            neon.removeAnimation(forKey: Self.fadeKey)
            neon.opacity = 0
            takeOff()
            return
        }
        let change = changes
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.faded(change) }
        }
        fade(
            to  : 0,
            over: duration
        )
        CATransaction.commit()
    }

    /// The fade out of `change` ended: off the screen, unless it was shown again meanwhile.
    private func faded(_ change: Int) {
        guard change == changes else { return }
        takeOff()
    }

    private func takeOff() {
        panel.orderOut(nil)
    }

    private static let fadeKey = "fade"

    /// Fades the neon from where it is now to `opacity`.
    private func fade(
        to opacity   : Float,
        over duration: CFTimeInterval
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = neon.presentation()?.opacity ?? neon.opacity
        fade.toValue   = opacity
        fade.duration  = duration
        neon.opacity   = opacity
        neon.add(
            fade,
            forKey: Self.fadeKey
        )
    }

    /// The frame of the screen that holds most of `frame`.
    private static func screen(holding frame: CGRect) -> CGRect {
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return NSScreen.screens.map(\.frame).max { overlap($0) < overlap($1) } ?? frame
    }
}
