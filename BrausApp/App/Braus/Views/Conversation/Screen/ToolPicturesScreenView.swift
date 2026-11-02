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
/// It draws at its resting size, and its layer's contents are placed proportionally while the
/// host's springs change its size, so the pictures scale without being drawn again per frame.
final class ToolPicturesScreenView: NSView {

    private static let padding: CGFloat = 16
    private static let gap    : CGFloat = 16

    /// How many times its pixel size a picture is drawn at most; the host's room caps it further.
    static let enlargement: CGFloat = 3

    private let images: [NSImage]
    private let sizes : [CGSize]

    /// The size the pictures ask for, which the host fits in the window and never exceeds.
    var nativeSize: CGSize { Self.layout(sizes, in: nil).size }

    init(_ images: [NSImage], pixelSizes: [CGSize]) {
        self.images = images
        self.sizes  = pixelSizes.map {
            CGSize(width: max(1, $0.width) * Self.enlargement, height: max(1, $0.height) * Self.enlargement)
        }
        super.init(frame: .zero)
        wantsLayer                 = true
        layerContentsRedrawPolicy  = .onSetNeedsDisplay
        layerContentsPlacement     = .scaleProportionallyToFit
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ToolPicturesScreenView is code-only") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        TranscriptColors.cardSurface.setFill()
        bounds.fill()
        for (image, frame) in zip(images, Self.layout(sizes, in: bounds.size).frames) {
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
