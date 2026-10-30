//
//  ScreenStageView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import CoreImage
import os
import SeatBroker

/// ScreenStageView shows the held application's window as it is on the seat's display: at its real
/// size, one point of the display to one point here, centred, and scaled down only when it does not
/// fit. Behind it the same picture fills the stage blurred and dimmed, so the window reads as lifted
/// and the stage never takes the window's shape: a window that grows or shrinks changes only the
/// picture's frame here, never the stage's.
///
/// Both pictures are layers the stream hands its surfaces to (`LivePreviewView`), so the blur is a
/// Core Animation filter drawn on the GPU and no frame is copied or read. The live view reports the
/// size of what it draws in screen points as frames arrive; any other view, the window check's still,
/// is taken at its intrinsic size.
///
/// The stream captures the held window, with the sheets attached to it, and nothing of the display
/// around it: the blur is that same window filling the stage, not the desktop it sits on.
final class ScreenStageView: NSView {

    /// The sharp picture of the held window.
    let picture: NSView

    /// The same picture, blurred and dimmed behind it; nil when no second view could be made.
    let backdrop: NSView?

    /// The held window's size in points, which the picture keeps while it fits.
    var pictureSize: CGSize = .zero {
        didSet {
            guard pictureSize != oldValue else { return }
            needsLayout = true
            reportSize()
        }
    }

    /// Told `pictureSize` once known and as it changes, after the current update: the window follows
    /// it. Set again, as each SwiftUI update does, it is not told again: the size it would hear could
    /// be older than the window's, as right after the person resized the lent application.
    var onPictureSize: ((CGSize) -> Void)? {
        didSet { if oldValue == nil { reportSize() } }
    }

    private func reportSize() {
        guard pictureSize != .zero, let onPictureSize else { return }
        let size = pictureSize
        DispatchQueue.main.async { onPictureSize(size) }
    }

    /// Whether a press on the picture moves the window: only while the worker holds the application.
    /// While the person has it, from Take Control to the hand-back, a press does nothing, even before
    /// the application has reached them.
    var movesWindow: () -> Bool = { true }

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "ScreenWindow"
    )

    /// The blur's radius, in points of the backdrop.
    static let blurRadius: CGFloat = 40

    /// How much of the backdrop shows over the stage's black: the rest dims it.
    static let backdropOpacity: CGFloat = 0.55

    /// The room kept clear around a picture that is scaled down: none, as the window fits the
    /// picture.
    static let margins = NSEdgeInsets()

    override var isFlipped: Bool { true }

    init(
        picture : NSView,
        backdrop: NSView?
    ) {
        self.picture  = picture
        self.backdrop = backdrop
        super.init(frame: .zero)
        wantsLayer           = true
        layer?.masksToBounds = true

        if let backdrop {
            backdrop.wantsLayer                = true
            backdrop.layerUsesCoreImageFilters = true
            backdrop.layer?.contentsGravity    = .resizeAspectFill
            backdrop.layer?.filters            = CIFilter(
                name      : "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: Self.blurRadius]
            ).map { [$0] }
            backdrop.alphaValue = Self.backdropOpacity
            addSubview(backdrop)
        }
        // Nothing behind the picture: wherever the capture is clear, the backdrop shows through.
        picture.layer?.backgroundColor = nil
        addSubview(picture)

        if let live = picture as? LivePreviewView {
            live.onPictureSize = { [weak self] in self?.pictureSize = $0 }
        } else if picture.intrinsicContentSize.width > 0, picture.intrinsicContentSize.height > 0 {
            pictureSize = picture.intrinsicContentSize
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The pictures never take the pointer: a press anywhere on the stage is the stage's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The window has no title bar: the picture is where it is held to be moved, from the first press.
    /// Moved here rather than by the window server, which keeps the whole window, the neon's margin
    /// with it, under the menu bar: the picture's own top reaches it (`windowTop(under:)`).
    override func mouseDown(with event: NSEvent) {
        guard movesWindow() else {
            Self.log.notice("A press on the picture moves nothing: the person has control")
            return
        }
        guard let window else { return }
        let start = window.frame
        let grab  = NSEvent.mouseLocation
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout : NSEvent.foreverDuration,
            mode    : .eventTracking
        ) { event, stop in
            guard let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let pointer = NSEvent.mouseLocation
            let screen  = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen
            let frame   = start.carried(
                from : grab,
                to   : pointer,
                under: screen.map { WorkerScreenWindowController.windowTop(under: $0.visibleFrame) } ?? .infinity
            )
            if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
        }
    }

    override func layout() {
        super.layout()
        // Larger than the stage, so the blur's soft edges fall outside it.
        backdrop?.frame = bounds.insetBy(
            dx: -2 * Self.blurRadius,
            dy: -2 * Self.blurRadius
        )
        picture.frame = Self.pictureFrame(
            of: pictureSize,
            in: bounds
        )
    }

    /// Where a picture of `size` points sits in `bounds`: centred at its own size, or scaled down
    /// with its proportions to fit inside `margins` when it is larger. Never scaled up; a picture
    /// with no size yet takes the whole area inside the margins.
    static func pictureFrame(
        of size  : CGSize,
        in bounds: CGRect
    ) -> CGRect {
        let area = CGRect(
            x     : bounds.minX + margins.left,
            y     : bounds.minY + margins.top,
            width : max(0, bounds.width - margins.left - margins.right),
            height: max(0, bounds.height - margins.top - margins.bottom)
        )
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }

        let scale  = min(1, area.width / size.width, area.height / size.height)
        let width  = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return CGRect(
            x     : (bounds.midX - width / 2).rounded(),
            y     : (min(max(bounds.midY - height / 2, area.minY), area.maxY - height)).rounded(),
            width : width,
            height: height
        )
    }
}
