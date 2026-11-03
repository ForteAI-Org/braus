//
//  ToolPicturesView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit

/// ToolPicturesView shows the pictures of one pictures block of a tool line, small, at the frames
/// the row's geometry gave them, and asks for them enlarged on a click.
///
/// It draws in `draw(_:)`, so an offscreen drawing of the window holds it too; its layer only
/// animates. Pictures that arrive on a line already shown fade in and settle from a little smaller
/// (`appear`), in Core Animation; Reduce Motion keeps the fade alone. The row's actions speak for
/// it and its keyboard focus is drawn here, so it is no accessibility element of its own.
@MainActor
final class ToolPicturesView: NSView {

    private static let cornerRadius: CGFloat = 6

    /// Called on a click: the row enlarges these pictures.
    var onOpen: (() -> Void)?

    /// True while the keyboard has reached the row's action that opens these pictures.
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }

    private(set) var pictures: ToolPictures?
    private var images: [NSImage] = []
    private var frames: [CGRect] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ToolPicturesView is code-only") }

    /// Shows `pictures` at `frames`, in this view's coordinates. The same pictures again keep
    /// their decoded images.
    func show(
        _ pictures: ToolPictures,
        at frames : [CGRect]
    ) {
        if pictures != self.pictures {
            self.pictures = pictures
            images        = pictures.pictures.map { NSImage(data: $0.data) ?? NSImage() }
        }
        self.frames  = frames
        needsDisplay = true
    }

    /// The pictures as drawn, decoded once, in the order the tool gave them.
    var shownImages: [NSImage] { images }

    /// Fades the pictures in, settling from 96 percent of their size unless `reducesMotion`.
    func appear(reducesMotion: Bool) {
        guard let layer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = 0
        fade.toValue        = 1
        fade.duration       = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(
            fade,
            forKey: "appear"
        )
        guard !reducesMotion else { return }

        // A layer-backed view's anchor is its origin: scale about the middle, as a translate and a scale.
        let middle = CGPoint(
            x: layer.bounds.midX,
            y: layer.bounds.midY
        )
        var start  = CATransform3DMakeTranslation(middle.x * 0.04, middle.y * 0.04, 0)
        start      = CATransform3DScale(start, 0.96, 0.96, 1)
        let settle = CASpringAnimation(keyPath: "transform")
        settle.fromValue = start
        settle.toValue   = CATransform3DIdentity
        settle.stiffness = 320
        settle.damping   = 30
        settle.duration  = settle.settlingDuration
        layer.add(
            settle,
            forKey: "settle"
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        for (image, frame) in zip(images, frames) {
            let path = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            // The worker bubble's hairline edge, so a dark picture keeps its outline on the background.
            NSColor.white.withAlphaComponent(0.07).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        guard isFocused, let first = frames.first, let last = frames.last else { return }

        // Focus is an outline, so it reads without colour (§3.3).
        let around = first.union(last).insetBy(dx: -3, dy: -3)
        let ring   = NSBezierPath(roundedRect: around, xRadius: Self.cornerRadius + 2, yRadius: Self.cornerRadius + 2)
        NSColor.keyboardFocusIndicatorColor.setStroke()
        ring.lineWidth = 2
        ring.stroke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A snapshot of the enlarged pictures opens them as soon as they are in the window.
        if WindowSnapshots.opensToolPictures, window != nil { DispatchQueue.main.async { self.onOpen?() } }
    }

    /// A click opens the pictures even when the conversation's window is not the key one, as when the
    /// person was just in a worker's screen window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(
            event.locationInWindow,
            from: nil
        )
        guard frames.contains(where: { $0.contains(point) }) else { return super.mouseDown(with: event) }
        onOpen?()
    }

    override func resetCursorRects() {
        for frame in frames { addCursorRect(frame, cursor: .pointingHand) }
    }
}
