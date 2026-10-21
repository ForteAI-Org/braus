//
//  BubbleFlight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// BubbleFlight flies a message's text across the conversation, in Core Animation layers above it:
/// a sent message from the composer's field, or from the queue strip, into its bubble at the foot
/// of the transcript (`launch` then `land`); a message sent during a turn into the queue strip
/// (`launch` then `glide`); and a quoted bubble into the quote strip and back (`quote`, `unquote`).
/// What follows describes a send; the other flights share its rules.
///
/// A flight starts where the text was typed, in the same font and white, as the field clears, and
/// holds there until the transcript has laid out the bubble it lands in, which stays hidden until
/// then. It then springs to the bubble's frame while its fill grows in over the field's glass and
/// its corners turn from the field's to the bubble's; the transcript makes room with the same
/// spring (`transcriptAnimation`). The text only moves: the frame animates, never a scale. A text
/// the field laid out on several lines leaves as the field showed it, scrolled to its end when
/// taller, and turns into the bubble's lines as it lifts. The fill is SwiftUI's own, drawn at the
/// bubble's size, so the flight that lands is the bubble pixel for pixel; the caller then shows the
/// real bubble and the flight leaves a turn later, so no frame shows neither.
///
/// Under Reduce Motion nothing travels: the text fades out of the field while the bubble fades in
/// at its place. Main actor only; the layers take no clicks and are no accessibility element.
@MainActor
final class BubbleFlight {

    /// The coordinate space, the conversation's, in which flights and bubbles give their frames.
    nonisolated static let space = "BubbleFlight"

    /// The spring of a flight and of the transcript making room, settling in `sendFlight`.
    static let stiffness: Double = 360
    static let damping  : Double = 27

    /// How long a cross-fade takes under Reduce Motion.
    static let crossFade: Double = 0.2

    /// How long a text the field had scrolled takes to slide back to its start.
    static let slide: Double = 0.16

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

    /// The transcript's animation as it makes room for a landing bubble: the flight's spring, or
    /// none under Reduce Motion.
    static var transcriptAnimation: Animation? {
        RestylingMotion.reducesMotion ? nil : .interpolatingSpring(
            mass     : 1,
            stiffness: stiffness,
            damping  : damping
        )
    }

    /// The view that holds the flights, to lay over the conversation.
    var overlay: Overlay { Overlay(stage: stage) }

    /// Built the first time a flight or the overlay needs it, not each time a view makes this.
    private lazy var stage = Stage()

    private var flights: [UUID: Flight] = [:]

    /// Origin is where a flight's text starts, as each draws it: the composer's field, the frame its
    /// lines fill, with how far it had scrolled them up when known; or the queue strip's line.
    enum Origin {
        case field(CGRect, scroll: CGFloat?)
        case strip(CGRect)
    }

    /// Starts the flight of `id`'s `text` from `origin`, breaking the text as a bubble in a column
    /// `column` points wide breaks it, below the `quote` it carries; it waits there for
    /// `land(_:in:completion:)`, or for `glide(_:to:completion:)` into the queue strip.
    func launch(
        _ id  : UUID,
        text  : String,
        quote : String?,
        from origin: Origin,
        column: CGFloat
    ) {
        let scale = stage.window?.backingScaleFactor ?? 2
        let frame   : CGRect
        let shown   : Text
        let style   : (opacity: Float, scrolls: Bool, oneLine: Bool)
        let scrolled: CGFloat?
        switch origin {
        case .field(let field, let scroll):
            frame    = field
            shown    = Text(text).font(.system(size: 14))
            style    = (1, true, false)
            scrolled = scroll
        case .strip(let line):
            frame    = line
            shown    = Text(text).font(QueueStrip.font)
            style    = (Self.secondaryOpacity, false, true)
            scrolled = 0
        }
        guard let lines = Self.image(
            of     : ChatTranscriptView.personContent(
                text,
                quote: quote
            ),
            width  : ChatTranscriptView.maximumTextWidth(column: column),
            scale  : scale,
            isWhite: false
        ), let typed = Self.image(
            of     : shown
                .lineLimit(style.oneLine ? 1 : nil)
                .truncationMode(.tail),
            width  : frame.width,
            scale  : scale
        ) else { return }

        let padding = ChatTranscriptView.bubblePadding
        // One line in the field and in the bubble is the same line; otherwise the lines differ.
        let differs = !style.scrolls
            || quote != nil
            || max(typed.size.height, lines.size.height) > Self.lineHeight + 1
        let start   = CGRect(
            x     : frame.minX - padding.leading,
            y     : frame.minY - padding.top,
            width : min(typed.size.width, frame.width) + padding.leading + padding.trailing,
            height: min(typed.size.height, frame.height) + padding.top + padding.bottom
        )
        let flight  = Flight(
            typed  : (
                image  : typed.image,
                size   : typed.size,
                // Unknown, a text taller than the field shows its end, where the caret is, a point clear.
                scroll : -((scrolled ?? (style.scrolls && typed.size.height > frame.height
                    ? typed.size.height + Self.fieldScrollMargin - frame.height
                    : 0)) * scale).rounded() / scale,
                field  : frame.size,
                opacity: style.opacity
            ),
            wrapped: differs ? lines : nil,
            scale  : scale,
            start  : start
        )
        flights[id]?.remove()
        flights[id] = flight
        stage.add(flight)
    }

    /// Carries `id`'s text, as the field showed it, to the queue strip's `line`, fading it out as
    /// it arrives, and calls `completion` when the strip should fade its own line in, as this one
    /// goes. Under Reduce Motion it fades out where it was typed while the strip's fades in.
    func glide(
        _ id      : UUID,
        to line   : CGRect,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let flight = flights[id], !flight.isLanding else { return }

        flight.isLanding = true
        let reduces = RestylingMotion.reducesMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                flight.remove()
                if self?.flights[id] === flight { self?.flights[id] = nil }
            }
        }
        if reduces {
            flight.vanish()
        } else {
            flight.glide(toLine: line)
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduces ? 0 : Self.glideHandover)) {
            completion()
        }
    }

    // MARK: Quotes

    /// Lifts a copy of a bubble into the quote strip: the copy, `bubble`'s frame with `content` on
    /// `fill`, emerges from the bubble and shrinks into a pill around the strip's `line` as its
    /// fill fades, and its text turns into the strip's, `lineText`, never scaled: the bubble's text
    /// fades out and the strip's in as they move, over `RestylingTiming.quoteFlight`. Calls
    /// `completion` once there, for the strip to show its line, which the flight's last frame
    /// already matches. The caller skips it under Reduce Motion.
    func quote(
        _ content : some View,
        fill      : some View,
        from bubble: CGRect,
        to line   : CGRect,
        lineText  : String,
        completion: @escaping @MainActor () -> Void
    ) {
        let scale   = stage.window?.backingScaleFactor ?? 2
        let padding = ChatTranscriptView.bubblePadding
        guard let start = Self.image(
            of     : content,
            width  : bubble.width - padding.leading - padding.trailing,
            scale  : scale,
            isWhite: false
        ) else { return }

        quote(
            start,
            at        : CGPoint(
                x: padding.leading,
                y: padding.top
            ),
            fill      : ImageRenderer(content: fill.frame(
                width : bubble.width,
                height: bubble.height
            )).cgImage,
            from      : bubble,
            to        : line,
            lineText  : lineText,
            completion: completion
        )
    }

    /// Lifts `start`, a picture placed at `origin` in `bubble`'s frame over `fill`, into the quote
    /// strip as `quote(_:fill:from:to:lineText:completion:)` does; the app's transcript gives a
    /// picture of its bubble, fill included, and no fill.
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
        let padding = ChatTranscriptView.bubblePadding
        guard let end = Self.image(
            of     : Self.stripLine(lineText),
            width  : line.width,
            scale  : scale,
            isWhite: false
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
        let duration   = RestylingTiming.quoteFlight
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
        guard !RestylingMotion.reducesMotion,
              let scale = stage.window?.backingScaleFactor,
              let image = Self.image(
                  of     : Self.stripLine(lineText),
                  width  : line.width,
                  scale  : scale,
                  isWhite: false
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
            let padding = ChatTranscriptView.bubblePadding
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

    /// The strips' line as `QuoteStrip` draws it.
    static func stripLine(_ text: String) -> some View {
        Text(text)
            .font(QueueStrip.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

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

    /// Flies `id` to `bubble`, its bubble's frame, and calls `completion` once it is there; a frame
    /// that arrives while the flight is in the air is ignored.
    func land(
        _ id      : UUID,
        in bubble : CGRect,
        completion: @escaping () -> Void
    ) {
        guard let flight = flights[id], !flight.isLanding else { return }

        flight.isLanding = true
        let target = stage.pixelAligned(bubble)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                completion()
                // The bubble is drawn in SwiftUI's next commit; the flight above it leaves after.
                DispatchQueue.main.async {
                    flight.remove()
                    if self?.flights[id] === flight { self?.flights[id] = nil }
                }
            }
        }
        if RestylingMotion.reducesMotion {
            flight.crossFade(to: target)
        } else {
            flight.spring(to: target)
        }
        CATransaction.commit()
    }

    /// The height of one line of the field's and the bubbles' text.
    static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// `text` drawn white, as the field draws it, broken into lines at most `width` wide; in its own
    /// colours, in the dark appearance, unless `isWhite`.
    static func image(
        of text: some View,
        width  : CGFloat,
        scale  : CGFloat,
        isWhite: Bool = true
    ) -> (image: CGImage, size: CGSize)? {
        let renderer = ImageRenderer(content: Group {
            if isWhite {
                text.foregroundStyle(.white)
            } else {
                text.environment(
                    \.colorScheme,
                    .dark
                )
            }
        })
        renderer.proposedSize = ProposedViewSize(
            width : width,
            height: nil
        )
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }

        return (
            image,
            CGSize(
                width : CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
        )
    }

    /// The opacity of the strips' secondary text: SwiftUI's secondary colour in the dark appearance.
    private static let secondaryOpacity: Float = {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        return Color.secondary.resolve(in: environment).opacity
    }()

    /// How far a glyph may reach past the field's frame, which the field still shows.
    private static let fieldOverhang: CGFloat = 2

    /// How far below its last line the field scrolls a text taller than itself. Measured on the
    /// vertical `TextField` of macOS 27.
    private static let fieldScrollMargin: CGFloat = 1

    // MARK: Flight

    /// Flight is one message in the air: a box clipped to a shape that morphs from the field's to
    /// the bubble's, holding the bubble's fill, which SwiftUI draws at the bubble's size, and the
    /// text. The text starts as the field laid it out, `typed`, clipped to the field and scrolled
    /// to its end when taller; it slides back to its start as it leaves. When the bubble lays the
    /// text out otherwise, it then fades out, and `wrapped`, the bubble's lines, fades in after it.
    final class Flight {
        let box = CALayer()

        var isLanding = false

        private let shape     = CAShapeLayer()
        private let fill      = CALayer()
        private let typedClip = CALayer()
        private let typed     = CALayer()
        private let wrapped   : CALayer?
        private let start     : CGRect
        private let scroll    : CGFloat

        /// The field's text fading out where it was typed, under Reduce Motion.
        private var ghost: CALayer?

        init(
            typed  : (image: CGImage, size: CGSize, scroll: CGFloat, field: CGSize, opacity: Float),
            wrapped: (image: CGImage, size: CGSize)?,
            scale  : CGFloat,
            start  : CGRect
        ) {
            self.start  = start
            self.scroll = typed.scroll
            let padding = ChatTranscriptView.bubblePadding
            let reach   = BubbleFlight.fieldOverhang
            box.anchorPoint = .zero
            box.position    = start.origin
            box.bounds      = CGRect(
                origin: .zero,
                size  : start.size
            )
            shape.path      = Self.path(
                in    : box.bounds,
                radius: BubbleFlight.fieldRadius
            )
            box.mask        = shape
            fill.anchorPoint     = .zero
            fill.bounds          = box.bounds
            fill.contentsGravity = .resize
            fill.opacity         = 0
            typedClip.anchorPoint   = .zero
            typedClip.position      = CGPoint(
                x: padding.leading - reach,
                y: padding.top
            )
            typedClip.bounds        = CGRect(
                x     : 0,
                y     : 0,
                width : reach + typed.field.width + reach,
                height: min(typed.size.height, typed.field.height)
            )
            typedClip.masksToBounds = true
            typedClip.opacity       = typed.opacity
            BubbleFlight.show(
                (typed.image, typed.size),
                in   : self.typed,
                scale: scale,
                at   : CGPoint(
                    x: reach,
                    y: typed.scroll
                )
            )
            typedClip.addSublayer(self.typed)
            box.addSublayer(fill)
            box.addSublayer(typedClip)
            if let wrapped {
                let layer = CALayer()
                BubbleFlight.show(
                    wrapped,
                    in   : layer,
                    scale: scale,
                    at   : CGPoint(
                        x: padding.leading,
                        y: padding.top
                    )
                )
                layer.opacity  = 0
                box.addSublayer(layer)
                self.wrapped = layer
            } else {
                self.wrapped = nil
            }
        }

        /// Springs the box to `target` with the bubble's corners, while its fill grows in and its
        /// text takes the bubble's lines and colour.
        func spring(to target: CGRect) {
            let from     = CGRect(
                origin: .zero,
                size  : start.size
            )
            let typedFrom = typed.position
            let clipFrom  = typedClip.bounds
            let shownFrom = typedClip.opacity
            let bounds    = land(at: target)
            add(
                "position",
                from: start.origin,
                to  : target.origin,
                on  : box
            )
            for layer in [box, fill] {
                add(
                    "bounds",
                    from: from,
                    to  : bounds,
                    on  : layer
                )
            }
            add(
                "path",
                from: Self.path(
                    in    : from,
                    radius: BubbleFlight.fieldRadius
                ),
                to  : shape.path,
                on  : shape
            )
            add(
                "opacity",
                from: 0,
                to  : 1,
                on  : fill
            )
            if scroll < 0 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.fromValue      = typedFrom
                slide.toValue        = typed.position
                slide.duration       = BubbleFlight.slide
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                typed.add(
                    slide,
                    forKey: "position"
                )
            }
            if let wrapped {
                let reflow = BubbleFlight.reflow
                add(
                    "bounds",
                    from: clipFrom,
                    to  : typedClip.bounds,
                    on  : typedClip
                )
                fade(
                    typedClip,
                    from   : shownFrom,
                    to     : 0,
                    between: reflow.typedOut
                )
                fade(
                    wrapped,
                    from   : 0,
                    to     : wrapped.opacity,
                    between: reflow.wrappedIn
                )
            } else {
                add(
                    "opacity",
                    from: shownFrom,
                    to  : typedClip.opacity,
                    on  : typedClip
                )
            }
        }

        /// Moves the box to `target` unseen and fades it in there, while the field's text fades
        /// out where it was typed.
        func crossFade(to target: CGRect) {
            let ghost = CALayer()
            ghost.contents        = typed.contents
            ghost.contentsScale   = typed.contentsScale
            ghost.contentsGravity = .topLeft
            ghost.anchorPoint     = .zero
            ghost.bounds          = typed.bounds
            ghost.position        = typed.position
            let clip = CALayer()
            clip.anchorPoint   = .zero
            clip.bounds        = typedClip.bounds
            clip.masksToBounds = true
            clip.position      = CGPoint(
                x: start.minX + typedClip.position.x,
                y: start.minY + typedClip.position.y
            )
            clip.opacity       = 0
            clip.addSublayer(ghost)
            BubbleFlight.quietly { box.superlayer?.addSublayer(clip) }
            self.ghost = clip
            fade(
                clip,
                from: 1,
                to  : 0
            )
            // Nothing travels: the box is at the bubble before it shows.
            _ = land(at: target)
            fade(
                box,
                from: 0,
                to  : 1
            )
        }

        /// Moves the box so the first line of its text lies on `line`'s, centre on centre, its text
        /// fading out on the way (`BubbleFlight.glideFade`).
        func glide(toLine line: CGRect) {
            let padding = ChatTranscriptView.bubblePadding
            let target  = CGPoint(
                x: line.minX - padding.leading,
                y: line.midY - BubbleFlight.lineHeight / 2 - padding.top
            )
            let from    = box.position
            let shown   = typedClip.opacity
            BubbleFlight.quietly {
                box.position      = target
                typedClip.opacity = 0
            }
            add(
                "position",
                from: from,
                to  : target,
                on  : box
            )
            fade(
                typedClip,
                from   : shown,
                to     : 0,
                between: BubbleFlight.glideFade
            )
        }

        /// Fades the whole flight out where it is, in a cross-fade's time.
        func vanish() {
            BubbleFlight.quietly { box.opacity = 0 }
            fade(
                box,
                from: 1,
                to  : 0
            )
        }

        /// Takes the flight off the stage.
        func remove() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            box.removeFromSuperlayer()
            ghost?.removeFromSuperlayer()
            CATransaction.commit()
        }

        /// Sets every layer's final state at `target`: the fill SwiftUI draws for a bubble of its
        /// size, the typed text slid back to its start, and the bubble's text in the bubbles' label
        /// colour. Returns the box's bounds there.
        private func land(at target: CGRect) -> CGRect {
            let bounds   = CGRect(
                origin: .zero,
                size  : target.size
            )
            let renderer = ImageRenderer(content: Rectangle()
                .fill(LinearGradient(
                    colors    : ChatTranscriptView.personFill.colors,
                    startPoint: ChatTranscriptView.personFill.start,
                    endPoint  : ChatTranscriptView.personFill.end
                ))
                .frame(
                    width : target.width,
                    height: target.height
                ))
            renderer.scale = typed.contentsScale
            // Every value at once and with no implicit action: the caller animates what travels.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            fill.contents  = renderer.cgImage
            box.position   = target.origin
            box.bounds     = bounds
            fill.bounds    = bounds
            fill.opacity   = 1
            shape.path     = Self.bubblePath(in: bounds)
            typed.position = CGPoint(
                x: BubbleFlight.fieldOverhang,
                y: 0
            )
            if let wrapped {
                typedClip.opacity = 0
                typedClip.bounds.size.height = typed.bounds.height
                wrapped.opacity   = 1
            } else {
                typedClip.opacity = Self.labelOpacity
            }
            return bounds
        }

        private func add(
            _ keyPath: String,
            from     : Any?,
            to       : Any?,
            on layer : CALayer
        ) {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.fromValue = from
            spring.toValue   = to
            spring.mass      = 1
            spring.stiffness = BubbleFlight.stiffness
            spring.damping   = BubbleFlight.damping
            spring.duration  = spring.settlingDuration
            layer.add(
                spring,
                forKey: keyPath
            )
        }

        /// Fades `layer` from `from` to `to` between two moments of the flight, in seconds from
        /// its start, holding each value outside them.
        private func fade(
            _ layer: CALayer,
            from   : Float,
            to     : Float,
            between: (start: Double, end: Double)
        ) {
            let duration = BubbleFlight.flightDuration
            let fade     = CAKeyframeAnimation(keyPath: "opacity")
            fade.values   = [from, from, to, to]
            fade.keyTimes = [
                0,
                NSNumber(value: between.start / duration),
                NSNumber(value: between.end / duration),
                1,
            ]
            fade.duration = duration
            layer.add(
                fade,
                forKey: "opacity"
            )
        }

        private func fade(
            _ layer: CALayer,
            from   : Float,
            to     : Float
        ) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue   = to
            fade.duration  = BubbleFlight.crossFade
            layer.add(
                fade,
                forKey: "opacity"
            )
        }

        /// The opacity of the bubbles' white text: SwiftUI's primary colour in the dark appearance.
        private static let labelOpacity: Float = {
            var environment = EnvironmentValues()
            environment.colorScheme = .dark
            return Color.primary.resolve(in: environment).opacity
        }()

        /// The person's bubble in `rect`, its bottom trailing corner tight.
        private static func bubblePath(in rect: CGRect) -> CGPath {
            ChatTranscriptView.bubbleShape(tailing: .trailing)
                .path(in: rect)
                .cgPath
        }

        /// A rounded rectangle in `rect` whose corners are all `radius`, with the elements of a
        /// bubble's path, so Core Animation can morph one into the other.
        static func path(
            in rect: CGRect,
            radius : CGFloat
        ) -> CGPath {
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading    : radius,
                    bottomLeading : radius,
                    bottomTrailing: radius,
                    topTrailing   : radius
                ),
                style      : .continuous
            )
            .path(in: rect)
            .cgPath
        }
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

        func add(_ flight: Flight) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.addSublayer(flight.box)
            CATransaction.commit()
        }

        /// `rect` with its origin on the backing's pixel grid, where SwiftUI draws the bubble.
        func pixelAligned(_ rect: CGRect) -> CGRect {
            let scale = window?.backingScaleFactor ?? 2
            return CGRect(
                x     : (rect.minX * scale).rounded() / scale,
                y     : (rect.minY * scale).rounded() / scale,
                width : rect.width,
                height: rect.height
            )
        }
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
