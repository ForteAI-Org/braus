//
//  ToolPicturesScreenView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit

/// ToolPicturesScreenView is a tool line's pictures enlarged, the screen an `EnlargedScreenHostView`
/// grows from the small pictures and shrinks back into: side by side on the tool card's surface,
/// in the order the tool gave them (a canvas's before, then its after).
///
/// It renders the card once at its resting size into its layer's contents, which the layer scales
/// proportionally while the host's springs change its size: the shrink into the transcript sets the
/// small frame at once, and a card drawn again at that size would sit in the corner of the layer
/// still animating. Only a frame larger than the rendering renders it again.
final class ToolPicturesScreenView: NSView {

    private static let padding: CGFloat = 16
    private static let gap    : CGFloat = 16

    /// How many times its pixel size a picture is drawn at most; the host's room caps it further.
    static let enlargement: CGFloat = 3

    private let images: [NSImage]
    private let sizes : [CGSize]

    /// The size the card was last rendered at.
    private var renderedSize = CGSize.zero

    /// The size the pictures ask for, which the host fits in the window and never exceeds.
    var nativeSize: CGSize { Self.layout(sizes, in: nil).size }

    /// The frame that puts the pictures on `small`, the small pictures' frame, with the card's margin
    /// around it at the same scale: the shrink lands the pictures, not the card, on the small ones.
    func frame(showingPicturesOn small: CGRect) -> CGRect {
        let pictures = nativeSize.width - 2 * Self.padding
        guard pictures > 0, small.width > 0 else { return small }

        let margin = Self.padding * small.width / pictures
        return small.insetBy(
            dx: -margin,
            dy: -margin
        )
    }

    init(_ images: [NSImage], pixelSizes: [CGSize]) {
        self.images = images
        self.sizes  = pixelSizes.map {
            CGSize(width: max(1, $0.width) * Self.enlargement, height: max(1, $0.height) * Self.enlargement)
        }
        super.init(frame: .zero)
        wantsLayer                = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ToolPicturesScreenView is code-only") }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > renderedSize.width || newSize.height > renderedSize.height { needsDisplay = true }
    }

    override func updateLayer() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }

        let size  = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let card  = NSImage(
            size   : size,
            flipped: true
        ) { [self] _ in
            drawCard(in: size)
            return true
        }
        layer.contents        = card.layerContents(forContentsScale: scale)
        layer.contentsScale   = scale
        layer.contentsGravity = .resizeAspect
        renderedSize          = size
    }

    /// An offscreen drawing of the view (`cacheDisplay`) takes the card from here.
    override func draw(_ dirtyRect: NSRect) {
        drawCard(in: bounds.size)
    }

    private func drawCard(in size: CGSize) {
        TranscriptColors.cardSurface.setFill()
        CGRect(origin: .zero, size: size).fill()
        for (image, frame) in zip(images, Self.layout(sizes, in: size).frames) {
            let path = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The pictures side by side at `sizes`, aligned at their middles inside the padding, reduced
    /// as a whole and centred to fit `room` when there is one; and the size they take.
    private static func layout(
        _ sizes: [CGSize],
        in room: CGSize?
    ) -> (frames: [CGRect], size: CGSize) {
        let gaps    = gap * CGFloat(max(0, sizes.count - 1))
        let content = CGSize(
            width : sizes.map(\.width).reduce(0, +) + gaps,
            height: sizes.map(\.height).max() ?? 0
        )
        let natural = CGSize(width: content.width + 2 * padding, height: content.height + 2 * padding)
        guard let room, content.width > gaps, content.height > 0 else { return ([], natural) }

        let scale  = min(
            1,
            (room.width - 2 * padding - gaps) / (content.width - gaps),
            (room.height - 2 * padding) / content.height
        )
        let width  = (content.width - gaps) * scale + gaps
        var x      = (room.width - width) / 2
        let middle = room.height / 2
        let frames = sizes.map { size in
            let frame = CGRect(
                x     : x,
                y     : middle - size.height * scale / 2,
                width : size.width * scale,
                height: size.height * scale
            )
            x = frame.maxX + gap
            return frame
        }
        return (frames, natural)
    }
}
