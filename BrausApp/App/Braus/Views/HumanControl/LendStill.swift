//
//  LendStill.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import CoreImage
import IOSurface
import os
import QuartzCore

/// LendStill holds the worker's screen still where its window was while the lent application's
/// window takes that place: the screen window is the application's window at its real size, so the
/// real window lands on it exactly (`HumanPreviewControl.lendingAnchor`). Just before the windows
/// move, the still covers the screen window, which steps aside at once, so no Braus window is on the
/// stage Stage Manager sweeps aside as the application comes forward and the window leaving the
/// seat's display never shows in the live picture. Once the real window stands still under it, the
/// still fades into it (`land()`), or on its own a little later.
///
/// The still is the live view's frame copied once, off the main thread and ahead of the swap
/// (`prepare()`): the stream draws into a pool of surfaces, and one held by reference was drawn again
/// as the window moved off the seat's display. It shows in a
/// click-through panel above ordinary windows, on every Space and outside Stage Manager's stages, as
/// the border's (`HumanControlPanel`).
@MainActor
final class LendStill {

    /// The pause and fade into the real window, which happens on its own past `failsafe` if the lend
    /// never reports, in seconds.
    static let timing = (
        landFade: 0.15,
        failsafe: 3.0
    )

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    /// Copies stills off the GPU; made once, used off the main thread.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    private let panel = HumanControlPanel.make(ignoresMouse: true)
    private let card  = CALayer()
    /// Where the still covers the screen window, in AppKit's screen space.
    let frame: CGRect
    private var landed = false

    /// The live surface the still was copied from and its seed then, to log whether the stream drew
    /// into it again before the still went.
    private let surface: IOSurface?
    private let seed   : UInt32

    /// The part of the surface the picture shows, and the copy once made.
    private let contentsRect: CGRect
    private var copied      = false

    /// A still of `picture`'s current frame where it is on screen; nil while it shows nothing or is
    /// in no window.
    init?(picture: NSView) {
        guard let window = picture.window, let layer = picture.layer, let contents = layer.contents else {
            return nil
        }
        frame   = window.convertToScreen(picture.convert(
            picture.bounds,
            to: nil
        ))
        surface      = (contents as AnyObject) as? IOSurface
        seed         = surface?.seed ?? 0
        // A flipped view such as the live one counts the part shown from the top; the card's view,
        // from the bottom.
        let shown    = layer.contentsRect
        contentsRect = picture.isFlipped ? shown : Self.flipped(shown)
        // The surface itself until the copy is made.
        card.contents        = contents
        card.contentsRect    = Self.flipped(contentsRect)
        card.contentsGravity = .resize
        // A window's shadow, as the screen window cast it.
        card.shadowColor     = .black
        card.shadowOpacity   = 0.45
        card.shadowRadius    = 18
        card.shadowOffset    = CGSize(
            width : 0,
            height: -8
        )
    }

    /// Copies the picture off the main thread, once; the still shows the copy from then on.
    func prepare() async {
        guard !copied, let surface else { return }
        copied = true
        let started = ContinuousClock.now
        nonisolated(unsafe) let source = surface
        let rect  = contentsRect
        let image = await Task.detached(priority: .userInitiated) {
            Self.still(
                of     : source,
                cropped: rect
            )
        }.value
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.contents     = image
        card.contentsRect = CGRect(
            x     : 0,
            y     : 0,
            width : 1,
            height: 1
        )
        CATransaction.commit()
        Self.log.notice("take control: the still was copied in \(ContinuousClock.now - started, privacy: .public)")
    }

    /// Puts the still on screen where the picture is.
    func show() {
        let room = frame.insetBy(
            dx: -48,
            dy: -48
        )
        let view = NSView(frame: CGRect(
            origin: .zero,
            size  : room.size
        ))
        view.wantsLayer = true
        view.layer?.addSublayer(card)
        panel.contentView = view
        panel.setFrame(
            room,
            display: false
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = frame.offsetBy(
            dx: -room.minX,
            dy: -room.minY
        )
        CATransaction.commit()
        panel.orderFrontRegardless()
        Self.log.notice("take control: the still covers \(String(describing: self.frame), privacy: .public), its panel at \(String(describing: self.panel.frame), privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timing.failsafe))
            self?.land()
        }
    }

    /// Fades the still into the real window under it and takes the panel away; once.
    func land() {
        guard !landed else { return }
        landed = true
        if let surface {
            Self.log.notice("take control: the live surface was drawn again while the still showed: \(surface.seed != self.seed, privacy: .public)")
        }
        let timing = Self.timing
        Self.log.notice("take control: the still fades into the lent window")
        Task { [panel, card] in
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    panel.contentView = nil
                }
            }
            let fade            = CABasicAnimation(keyPath: "opacity")
            fade.fromValue      = card.presentation()?.opacity ?? 1
            fade.toValue        = 0
            fade.duration       = timing.landFade
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.opacity        = 0
            card.add(
                fade,
                forKey: "land"
            )
            CATransaction.commit()
        }
    }

    /// `rect` in unit coordinates counted from the other edge, top for bottom.
    nonisolated private static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x     : rect.minX,
            y     : 1 - rect.maxY,
            width : rect.width,
            height: rect.height
        )
    }

    /// The part `rect` of `surface`, in unit coordinates from its top left as `contentsRect` has
    /// them, as an image of its own.
    nonisolated private static func still(
        of surface  : IOSurface,
        cropped rect: CGRect
    ) -> CGImage? {
        let width  = CGFloat(surface.width)
        let height = CGFloat(surface.height)
        // Core Image counts y up from the bottom.
        let crop   = CGRect(
            x     : rect.minX * width,
            y     : (1 - rect.maxY) * height,
            width : rect.width * width,
            height: rect.height * height
        ).integral
        return context.createCGImage(
            CIImage(ioSurface: surface),
            from: crop
        )
    }
}
