//
//  LiveFlight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit

/// LiveFlight is one message in the air over the new look's conversation (`HouseLiveFlights`): the
/// text as it was drawn where it left, on a box that takes the person's bubble colour and corners
/// as it travels, and once it lands, a picture of the bubble as the transcript draws it, so the last
/// frame is the bubble. It springs as the mockup's flights do (`BubbleFlight`); only frames animate,
/// no text is scaled. Under Reduce Motion nothing travels: the text fades where it was while the
/// bubble fades in at its place. Main actor only, in a stage's layer.
@MainActor
final class LiveFlight {

    /// Landing is where a flight comes down, in the stage's coordinates: the bubble's surface, the
    /// frame its picture covers, where its text starts, and the picture.
    struct Landing {
        let surface   : CGRect
        let frame     : CGRect
        let textOrigin: CGPoint
        let image     : CGImage
    }

    /// Whether the text left the composer's field, rather than the queue strip.
    let fromField: Bool

    /// Set once the flight lands, glides or fades: it waits no more.
    private(set) var isLeaving = false

    /// The flight's origin moves; the fill under the text grows into the bubble.
    let root = CALayer()

    private let fill      = CALayer()
    private let typed     = CALayer()
    private let textInset : CGPoint
    private let scale     : CGFloat

    /// The text fading where it was, under Reduce Motion.
    private var ghost: CALayer?

    /// Puts `picture`, drawn at `frame` in `stage`'s coordinates with its first line `textInset`
    /// into it, on `stage`, where it waits. Nil when the stage has no layer.
    init?(
        typed picture: (image: CGImage, size: CGSize),
        at frame     : CGRect,
        textInset    : CGPoint,
        fromField    : Bool,
        on stage     : NSView
    ) {
        guard let layer = stage.layer else { return nil }

        let padding    = RowGeometry.bubblePadding
        self.fromField = fromField
        self.textInset = textInset
        scale          = stage.window?.backingScaleFactor ?? 2
        root.anchorPoint  = .zero
        root.position     = CGPoint(
            x: frame.minX + textInset.x - padding.width,
            y: frame.minY + textInset.y - padding.height
        )
        fill.anchorPoint  = .zero
        fill.bounds       = CGRect(
            x     : 0,
            y     : 0,
            width : frame.width - textInset.x + 2 * padding.width,
            height: frame.height - 2 * textInset.y + 2 * padding.height
        )
        fill.cornerRadius = min(BubbleFlight.fieldRadius, fill.bounds.height / 2)
        fill.opacity      = 0
        Self.show(
            picture,
            in   : typed,
            scale: scale,
            at   : CGPoint(
                x: padding.width - textInset.x,
                y: padding.height - textInset.y
            )
        )
        root.addSublayer(fill)
        root.addSublayer(typed)
        BubbleFlight.quietly { layer.addSublayer(root) }
    }

    /// Springs onto `landing`: the fill takes the bubble's frame, corners and `color` while the text
    /// moves onto the bubble's and fades out, and the bubble's picture fades in over them. Calls
    /// `completion` once there, for the bubble itself to show; the flight leaves a turn later.
    func land(
        on landing: Landing,
        color     : CGColor,
        completion: @escaping @MainActor () -> Void
    ) {
        isLeaving = true
        let bubble = CALayer()
        Self.show(
            (landing.image, landing.frame.size),
            in   : bubble,
            scale: scale,
            at   : CGPoint(
                x: landing.frame.minX - landing.surface.minX,
                y: landing.frame.minY - landing.surface.minY
            )
        )
        let from = (root: root.position, fill: fill.bounds, radius: fill.cornerRadius, typed: typed.position)
        // Every final value at once and with no implicit action: what travels is animated below.
        BubbleFlight.quietly {
            root.addSublayer(bubble)
            root.position        = landing.surface.origin
            fill.bounds          = CGRect(
                origin: .zero,
                size  : landing.surface.size
            )
            fill.cornerRadius    = BubblePath.cornerRadius
            fill.backgroundColor = color
            fill.opacity         = 0
            typed.position       = CGPoint(
                x: landing.textOrigin.x - landing.surface.minX - textInset.x,
                y: landing.textOrigin.y - landing.surface.minY - textInset.y
            )
            typed.opacity        = 0
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
                // The row is drawn in AppKit's next pass; the flight above it leaves after.
                DispatchQueue.main.async { self.remove() }
            }
        }
        if RestylingMotion.reducesMotion {
            crossFade(typedFrom: CGPoint(
                x: from.root.x + from.typed.x,
                y: from.root.y + from.typed.y
            ))
        } else {
            let reflow = BubbleFlight.reflow
            let end    = BubbleFlight.flightDuration
            spring(root, "position", from: from.root)
            spring(fill, "bounds", from: from.fill)
            spring(fill, "cornerRadius", from: from.radius)
            spring(typed, "position", from: from.typed)
            fade(typed, [1, 1, 0, 0], at: [0, reflow.typedOut.start, reflow.typedOut.end, end])
            fade(fill, [0, 1, 1, 0, 0], at: [0, reflow.typedOut.end, reflow.wrappedIn.end, reflow.wrappedIn.end + 0.02, end])
            fade(bubble, [0, 0, 1, 1], at: [0, reflow.wrappedIn.start, reflow.wrappedIn.end, end])
        }
        CATransaction.commit()
    }

    /// Carries the text to the queue strip's `line`, its first line on the line, fading out as it
    /// arrives, and calls `completion` when the strip should fade its own line in. Under Reduce
    /// Motion it fades where it is while the strip's comes at once.
    func glide(
        to line   : CGRect,
        completion: @escaping @MainActor () -> Void
    ) {
        guard !RestylingMotion.reducesMotion else {
            vanish()
            completion()
            return
        }

        isLeaving = true
        let padding = RowGeometry.bubblePadding
        let from    = root.position
        BubbleFlight.quietly {
            root.position = CGPoint(
                x: line.minX - padding.width,
                y: line.midY - BubbleFlight.lineHeight / 2 - padding.height
            )
            typed.opacity = 0
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { self.remove() }
        }
        let glide = BubbleFlight.glideFade
        spring(root, "position", from: from)
        fade(typed, [1, 1, 0, 0], at: [0, glide.start, glide.end, BubbleFlight.flightDuration])
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + BubbleFlight.glideHandover) { completion() }
    }

    /// Fades the whole flight out where it is, in a cross-fade's time.
    func vanish() {
        isLeaving = true
        BubbleFlight.quietly { root.opacity = 0 }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { self.remove() }
        }
        fade(root, from: 1, to: 0)
        CATransaction.commit()
    }

    /// Under Reduce Motion, with every layer already at the bubble: the text fades out at
    /// `typedFrom`, where it was, while the flight fades in.
    private func crossFade(typedFrom origin: CGPoint) {
        let ghost = CALayer()
        ghost.contents        = typed.contents
        ghost.contentsScale   = typed.contentsScale
        ghost.contentsGravity = .topLeft
        ghost.anchorPoint     = .zero
        ghost.bounds          = typed.bounds
        ghost.position        = origin
        BubbleFlight.quietly {
            root.superlayer?.addSublayer(ghost)
            ghost.opacity = 0
        }
        self.ghost = ghost
        fade(ghost, from: 1, to: 0)
        fade(root, from: 0, to: 1)
    }

    private func remove() {
        BubbleFlight.quietly {
            root.removeFromSuperlayer()
            ghost?.removeFromSuperlayer()
        }
    }

    /// Springs `layer`'s `keyPath` from `value` to the value the model already holds.
    private func spring(
        _ layer   : CALayer,
        _ keyPath : String,
        from value: Any
    ) {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = value
        spring.toValue   = layer.value(forKeyPath: keyPath)
        spring.mass      = 1
        spring.stiffness = BubbleFlight.stiffness
        spring.damping   = BubbleFlight.damping
        spring.duration  = spring.settlingDuration
        layer.add(
            spring,
            forKey: keyPath
        )
    }

    /// Fades `layer` through `values` at `seconds` from the flight's start, the last at its end.
    private func fade(
        _ layer   : CALayer,
        _ values  : [Float],
        at seconds: [Double]
    ) {
        let duration = BubbleFlight.flightDuration
        let fade     = CAKeyframeAnimation(keyPath: "opacity")
        fade.values   = values
        fade.keyTimes = seconds.map { NSNumber(value: min(1, $0 / duration)) }
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

    /// Sets `layer` to show `picture` unscaled, its top left corner at `origin`.
    private static func show(
        _ picture: (image: CGImage, size: CGSize),
        in layer : CALayer,
        scale    : CGFloat,
        at origin: CGPoint
    ) {
        layer.contents        = picture.image
        layer.contentsScale   = scale
        layer.contentsGravity = .topLeft
        layer.anchorPoint     = .zero
        layer.bounds          = CGRect(
            origin: .zero,
            size  : picture.size
        )
        layer.position        = origin
    }
}
