//
//  BubbleFlight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// BubbleFlight is the stage the conversation's flights fly on, in Core Animation layers above it,
/// and the timings they share: a sent or queued message's flight (`LiveFlight`) springs with
/// `stiffness` and `damping`, and a quoted bubble lifts into the quote strip and back (`quote`,
/// `unquote`). Under Reduce Motion nothing travels: a flight cross-fades over `crossFade`. Main
/// actor only; the layers take no clicks and are no accessibility element.
@MainActor
final class BubbleFlight {

    /// The coordinate space, the conversation's, in which flights and bubbles give their frames.
    nonisolated static let space = "BubbleFlight"

    /// The spring of a flight and of the transcript making room.
    static let stiffness: Double = 360
    static let damping  : Double = 27

    /// How long a cross-fade takes under Reduce Motion.
    static let crossFade: Double = 0.2

    /// When the field's lines fade out, and then the bubble's in, from the flight's start, for a
    /// text the two lay out differently: one after the other, as two layouts over each other would
    /// read double.
    static let reflow = (
        typedOut  : (start: 0.06, end: 0.17),
        wrappedIn : (start: 0.17, end: 0.32)
    )

    /// When a text gliding into the queue strip fades out, from the flight's start, and when the
    /// strip's own line starts fading in, so the two never read double.
    static let glideFade      = (start: 0.18, end: 0.32)
    static let glideHandover  = 0.26

    /// How long a flight takes to settle: its spring's settling time.
    static var flightDuration: Double {
        let spring = CASpringAnimation()
        spring.mass      = 1
        spring.stiffness = stiffness
        spring.damping   = damping
        return spring.settlingDuration
    }

    /// The corner radius of the composer's field, where a flight's corners start.
    static let fieldRadius: CGFloat = 27

    /// The room between a bubble's edge and its text, where a quote's text starts and ends.
    private static let bubblePadding = EdgeInsets(
        top     : 11,
        leading : 16,
        bottom  : 11,
        trailing: 16
    )

    /// The view that holds the flights, to lay over the conversation.
    var overlay: Overlay { Overlay(stage: stage) }

    /// Built the first time a flight or the overlay needs it, not each time a view makes this.
    private lazy var stage = Stage()

    // MARK: Quotes

    /// Lifts a copy of a bubble into the quote strip: `start`, a picture placed at `origin` in
    /// `bubble`'s frame over `fill`, emerges from the bubble and shrinks into a pill around the strip's
    /// `line` as its fill fades, and its text turns into the strip's, `lineText`, never scaled: the
    /// bubble's text fades out and the strip's in as they move, over `HouseTiming.quoteFlight`.
    /// Calls `completion` once there, for the strip to show its line, which the flight's last frame
    /// already matches. The transcript gives a picture of its bubble, fill included, and no fill; the
    /// caller skips it under Reduce Motion.
    func quote(
        _ start   : (image: CGImage, size: CGSize),
        at origin : CGPoint,
        fill      : CGImage?,
        from bubble: CGRect,
        to line   : CGRect,
        lineText  : String,
        completion: @escaping @MainActor () -> Void
    ) {
        let scale   = stage.window?.backingScaleFactor ?? 2
        let padding = Self.bubblePadding
        guard let end = Self.image(
            of   : lineText,
            width: line.width,
            scale: scale
        ) else { return }

        let pill    = line.insetBy(
            dx: -Self.quotePill.width,
            dy: -Self.quotePill.height
        )
        let box     = CALayer()
        let filling = CALayer()
        let from    = CALayer()
        let to      = CALayer()
        box.anchorPoint   = .zero
        box.frame         = bubble
        box.cornerRadius  = 21
        box.cornerCurve   = .continuous
        box.masksToBounds = true
        filling.anchorPoint     = .zero
        filling.frame           = box.bounds
        filling.contentsGravity = .resize
        filling.contents        = fill
        Self.show(
            start,
            in   : from,
            scale: scale,
            at   : origin
        )
        Self.show(
            end,
            in   : to,
            scale: scale,
            at   : CGPoint(
                x: padding.leading,
                y: padding.top
            )
        )
        to.opacity = 0
        box.addSublayer(filling)
        box.addSublayer(from)
        box.addSublayer(to)

        let curve      = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.15, 1)
        let duration   = HouseTiming.quoteFlight
        let textOrigin = CGPoint(
            x: Self.quotePill.width,
            y: Self.quotePill.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.layer?.addSublayer(box)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(curve)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
                // The strip's line is drawn in SwiftUI's next commit; the copy above it leaves after.
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    box.removeFromSuperlayer()
                    CATransaction.commit()
                }
            }
        }
        for (layer, keyPath, value) in [
            (box, "position", NSValue(point: pill.origin)),
            (box, "bounds", NSValue(rect: CGRect(origin: .zero, size: pill.size))),
            (box, "cornerRadius", NSNumber(value: Double(pill.height / 2))),
            (filling, "bounds", NSValue(rect: CGRect(origin: .zero, size: pill.size))),
            (from, "position", NSValue(point: textOrigin)),
            (to, "position", NSValue(point: textOrigin)),
        ] as [(CALayer, String, NSValue)] {
            Self.animate(
                layer,
                keyPath,
                to: value
            )
        }
        // The copy emerges from the bubble, which moves as the strip opens, rather than lying on it.
        for (layer, values, times) in [
            (filling, [0, 1, 1, 0], [0, 0.15, 0.3, 0.8]),
            (from, [0, 1, 1, 0], [0, 0.15, 0.3, 0.55]),
            (to, [0, 0, 1, 1], [0, 0.35, 0.7, 1]),
        ] as [(CALayer, [Float], [NSNumber])] {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values   = values
            fade.keyTimes = times
            fade.duration = duration
            Self.quietly { layer.opacity = values[3] }
            layer.add(
                fade,
                forKey: "opacity"
            )
        }
        CATransaction.commit()
    }

    /// Carries the quote strip's `line`, `lineText`, back into its bubble's text, fading out on the
    /// way. The copy takes the line's place at once, as the caller hides it and closes the strip;
    /// it leaves a turn later for `bubble()`, the bubble's frame once the transcript has given back
    /// the strip's room, or fades where it is when the bubble is gone.
    func unquote(
        from line : CGRect,
        lineText  : String,
        to bubble : @escaping @MainActor () -> CGRect?
    ) {
        guard !HouseMotion.reducesMotion,
              let scale = stage.window?.backingScaleFactor,
              let image = Self.image(
                  of   : lineText,
                  width: line.width,
                  scale: scale
              )
        else { return }

        let text = CALayer()
        Self.show(
            image,
            in   : text,
            scale: scale,
            at   : line.origin
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.layer?.addSublayer(text)
        CATransaction.commit()
        DispatchQueue.main.async {
            let padding = Self.bubblePadding
            let target  = bubble().map { frame in
                CGPoint(
                    x: frame.minX + padding.leading,
                    y: frame.minY + padding.top
                )
            } ?? line.origin
            Self.fade(
                text,
                to: target
            )
        }
    }

    /// Moves `text` to `target` while it fades out, then takes it off the stage.
    private static func fade(
        _ text: CALayer,
        to target: CGPoint
    ) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.unquoteDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { text.removeFromSuperlayer() }
        }
        for (keyPath, value) in [
            ("position", NSValue(point: target)),
            ("opacity", NSNumber(value: 0)),
        ] as [(String, Any)] {
            animate(
                text,
                keyPath,
                to: value
            )
        }
        CATransaction.commit()
    }

    /// Animates `layer`'s `keyPath` from its value to `value`, over the transaction's duration and
    /// curve: the model takes `value` first, with no implicit action, which would replace this one.
    private static func animate(
        _ layer  : CALayer,
        _ keyPath: String,
        to value : Any
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.value(forKeyPath: keyPath)
        animation.toValue   = value
        quietly {
            layer.setValue(
                value,
                forKeyPath: keyPath
            )
        }
        layer.add(
            animation,
            forKey: keyPath
        )
    }

    /// Runs `change` with Core Animation's implicit actions off.
    static func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// How far the quote's pill reaches around the strip's line, across and up and down.
    private static let quotePill = CGSize(
        width : 14,
        height: 6
    )

    /// How long a quote takes back to its bubble.
    private static let unquoteDuration = 0.42

    /// Sets `layer` to show `image` unscaled, its top left corner at `origin`.
    private static func show(
        _ image: (image: CGImage, size: CGSize),
        in layer: CALayer,
        scale  : CGFloat,
        at origin: CGPoint
    ) {
        layer.contents        = image.image
        layer.contentsScale   = scale
        layer.contentsGravity = .topLeft
        layer.anchorPoint     = .zero
        layer.bounds          = CGRect(
            origin: .zero,
            size  : image.size
        )
        layer.position        = origin
    }

    /// The height of one line of the field's and the bubbles' text.
    static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// `text` as the strips draw their line (`QuoteStrip`, `QueueStrip`): in their font and secondary
    /// colour, in the dark appearance, on one line at most `width` wide, cut short with an ellipsis.
    /// Core Text draws it: a SwiftUI renderer would leave RenderBox drawing at every frame from then on.
    static func image(
        of text: String,
        width  : CGFloat,
        scale  : CGFloat
    ) -> (image: CGImage, size: CGSize)? {
        let font   = NSFont.systemFont(ofSize: 12.5)
        let height = ceil(font.ascender - font.descender + font.leading)
        var color  = NSColor.secondaryLabelColor.cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.cgColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font                                                            : font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let whole  = CTLineCreateWithAttributedString(NSAttributedString(
            string    : text,
            attributes: attributes
        ))
        let token  = CTLineCreateWithAttributedString(NSAttributedString(
            string    : "\u{2026}",
            attributes: attributes
        ))
        // Cut where SwiftUI's text cuts: an attributed string's own drawing keeps a glyph more.
        guard let line = CTLineCreateTruncatedLine(
                  whole,
                  Double(width),
                  .end,
                  token
              ),
              case let pixels = ceil(CTLineGetTypographicBounds(line, nil, nil, nil) * scale),
              pixels > 0,
              let context = CGContext(
                  data            : nil,
                  width           : Int(pixels),
                  height          : Int(ceil(height * scale)),
                  bitsPerComponent: 8,
                  bytesPerRow     : 0,
                  space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo      : CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return nil }

        context.scaleBy(
            x: scale,
            y: scale
        )
        // The baseline sits on the descent rounded up, as SwiftUI places it in its line.
        context.textPosition = CGPoint(
            x: 0,
            y: ceil(-font.descender)
        )
        CTLineDraw(
            line,
            context
        )
        return context.makeImage().map { (
            $0,
            CGSize(
                width : pixels / scale,
                height: height
            )
        ) }
    }

    // MARK: Stage

    /// Stage is the layer-hosting view the flights fly in, with its origin at the top left as the
    /// conversation's coordinate space has it.
    final class Stage: NSView {

        override init(frame: NSRect) {
            super.init(frame: frame)
            let root = CALayer()
            root.isGeometryFlipped = true
            layer      = root
            wantsLayer = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    // MARK: Overlay

    /// Overlay puts the stage over the conversation; it takes the conversation's whole size.
    struct Overlay: NSViewRepresentable {
        let stage: Stage

        func makeNSView(context: Context) -> Stage { stage }

        func updateNSView(
            _ view : Stage,
            context: Context
        ) {}
    }
}
