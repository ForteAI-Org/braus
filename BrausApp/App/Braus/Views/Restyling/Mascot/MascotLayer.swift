//
//  MascotLayer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import QuartzCore

/// MascotLayer draws a worker's mascot: a body of dark graphite metal in the worker's shape, lit by
/// its status light, with two brows that morph from one expression to the next.
///
/// Every body is the same metal and only its outline tells workers apart: the outline
/// RoomLight.metal shades in a room, under the same gradients, so a worker looks the same in and out
/// of rooms. The bounds are the sphere's square; other shapes reach past them by up to their
/// `ShapeOutline.extent`, and the brows sit on the shape's inscribed circle, its face.
///
/// The head never changes colour for an outcome, since the room light tells it; only a worker that
/// is off dims the body and greys the brows. Every motion asks `RestylingMotion` first: under
/// Reduce Motion a morph is a cut, the brows turn without travel and the head does not breathe.
/// Nonisolated like `CALayer`, whose overrides it needs; the methods that read `RestylingMotion`
/// are main-actor isolated, and the layer belongs to the main thread like every tree the app owns.
nonisolated final class MascotLayer: CALayer {

    /// The worker's shape. The brows follow it even when another renderer draws the body.
    var shape = WorkerShape.circle {
        didSet {
            guard shape != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Where a tilted room's camera shows the brows, or nil where they keep their place on the face.
    var projectedFace: RoomCamera.Face? {
        didSet {
            guard projectedFace != oldValue else { return }
            withoutActions { placeBrows() }
        }
    }

    /// How far above the face's centre the brows' line sits, as a share of the face's width.
    static let browLift = 0.5 - 0.36

    /// What the worker is doing: its light colours the bounce at the bottom.
    var status = WorkerStatus.free {
        didSet { applyColors() }
    }

    /// Whether this layer draws the sphere. False when another renderer draws the body underneath
    /// and only the brows belong here.
    var drawsBody = true {
        didSet { withoutActions { body.isHidden = !drawsBody } }
    }

    let leftBrow  = CAShapeLayer()
    let rightBrow = CAShapeLayer()

    /// The copies that keep each brow white below its lit top edge, by brow: one half way down in
    /// the half-lit colour, one a full step down in white, each clipped to the brow by a mask that
    /// morphs with it. Hidden unless the brows catch a room's light.
    private var leftLight : [CAShapeLayer] = []
    private var rightLight: [CAShapeLayer] = []

    private let body       = CALayer()
    private let silhouette = CAShapeLayer()
    private let base       = CAGradientLayer()
    private let shading    = CAGradientLayer()
    private let bounce     = CAGradientLayer()
    private let sheen      = CAGradientLayer()
    private let dimming    = CALayer()

    /// The expression last shown.
    private var state = BrowState.idle

    /// The outline the brows hold: `state`, or `look` while an idle mascot looks to the right.
    private var heldBrows = BrowState.idle

    private var yaw  : Double = 0
    private var pitch: Double = 0

    /// Which brow leads the next calm change; it alternates, as the prototype's random order varies.
    private var leftLeads = true

    override init() {
        super.init()
        for gradient in [base, shading, bounce, sheen] {
            gradient.type = .radial
            body.addSublayer(gradient)
        }
        body.addSublayer(dimming)
        body.mask = silhouette
        addSublayer(body)

        // Graphite, as the room's Metal body paints it before dimming it for its reflections.
        base.colors = [
            Self.color(hex: 0x2D2D32),
            Self.color(hex: 0x222226),
            Self.color(hex: 0x1F1F23),
        ]
        base.locations = [0, 0.44, 1]

        // Darkens the lower half and the sides for volume, lightly, so the edge reads diffuse as the
        // room's Metal body does.
        shading.colors = [
            CGColor(gray: 0, alpha: 0),
            CGColor(gray: 0, alpha: 0.2),
        ]
        shading.locations = [0.55, 1]

        // A crescent of status light on the lowest tenth, inside the outline.
        bounce.locations = [0, 0.2, 0.34]

        // A broad, faint, warm sheen upper left with no hard core, as the lamp's reflection on the
        // room's Metal body, so the mascot keeps its volume and looks like the same object.
        let warm = CGColor(
            srgbRed: 1,
            green  : 0.92,
            blue   : 0.84,
            alpha  : 1
        )
        sheen.colors = [
            warm.copy(alpha: 0.26) as Any,
            warm.copy(alpha: 0.11) as Any,
            warm.copy(alpha: 0) as Any,
        ]
        sheen.locations = [0, 0.45, 1]

        dimming.backgroundColor = CGColor(gray: 0, alpha: 1)

        let sides = [
            (leftBrow, BrowOutlines.bundled.left),
            (rightBrow, BrowOutlines.bundled.right),
        ]
        for (brow, outlines) in sides {
            brow.bounds = CGRect(
                x     : 0,
                y     : 0,
                width : Self.artboard.width,
                height: Self.artboard.height
            )
            brow.path = outlines[.idle].map(Self.path)
            addSublayer(brow)
        }
        leftLight  = Self.lightCopies(over: leftBrow)
        rightLight = Self.lightCopies(over: rightBrow)
        applyColors()
    }

    /// The two copies under `brow`'s lit edge, a half step and a full `litEdge` step down.
    private static func lightCopies(over brow: CAShapeLayer) -> [CAShapeLayer] {
        [0.5, 1].map { share in
            let step = litEdge * share
            let copy = CAShapeLayer()
            copy.frame    = brow.bounds.offsetBy(dx: 0, dy: -step)
            copy.path     = brow.path
            copy.isHidden = true
            let mask = CAShapeLayer()
            mask.frame = copy.bounds.offsetBy(dx: 0, dy: step)
            mask.path  = brow.path
            copy.mask  = mask
            brow.addSublayer(copy)
            return copy
        }
    }

    /// Every layer that holds `brow`'s outline: the brow, its light copies and their masks.
    private func outlineLayers(of brow: CAShapeLayer) -> [CAShapeLayer] {
        let copies = lightCopies(of: brow)
        return [brow] + copies + copies.compactMap { $0.mask as? CAShapeLayer }
    }

    /// Forwards the scale to every sublayer, so the gradients and brows render at the display's
    /// resolution.
    override var contentsScale: CGFloat {
        didSet {
            let lit = (leftLight + rightLight).flatMap { [$0, $0.mask].compactMap { $0 } }
            for layer in [body, silhouette, leftBrow, rightBrow] + (body.sublayers ?? []) + lit {
                layer.contentsScale = contentsScale
            }
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The body's outline in the body layer's coordinates, as it clips the body.
    var bodyOutline: CGPath? {
        silhouette.path
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        withoutActions {
            // A square around the sphere's centre, large enough for the shape.
            let outline = shape.outline
            let radius  = min(bounds.width, bounds.height) / 2
            let reach   = max(1, outline.extent)
            body.frame = CGRect(
                x     : bounds.midX - reach * radius,
                y     : bounds.midY - reach * radius,
                width : 2 * reach * radius,
                height: 2 * reach * radius
            )
            for layer in (body.sublayers ?? []) + [silhouette] {
                layer.frame = body.bounds
            }
            // The outline's y points down, the layer's up.
            silhouette.path = outline.path(transform: CGAffineTransform(
                translationX: reach * radius,
                y           : reach * radius
            ).scaledBy(
                x: radius,
                y: -radius
            ))
            placeGradients(
                reach : reach,
                bottom: outline.bottom
            )
            placeBrows()
        }
    }

    /// Places the gradients where they fall on the sphere's square, in a body `reach` times as
    /// large; the bounce follows the outline's lowest point, `bottom` sphere radii below the centre.
    private func placeGradients(
        reach : Double,
        bottom: Double
    ) {
        typealias Place = (gradient: CAGradientLayer, x: Double, top: Double, radiusX: Double, radiusY: Double)
        let places: [Place] = [
            (base,    0.37, 0.30,                   0.942, 0.942),
            (shading, 0.5,  0.25,                   0.85,  0.85),
            (bounce,  0.5,  1.1 + (bottom - 1) / 2, 1.0,   0.6),
            (sheen,   0.34, 0.26,                   0.42,  0.36),
        ]
        for place in places {
            Self.center(
                place.gradient,
                x      : 0.5 + (place.x - 0.5) / reach,
                top    : 0.5 + (place.top - 0.5) / reach,
                radiusX: place.radiusX / reach,
                radiusY: place.radiusY / reach
            )
        }
    }

    /// Shows `state`. Animated, each brow whose shape group changes morphs as `BrowTransition`
    /// says; under Reduce Motion, or not animated, the brows cut to the new outline.
    @MainActor
    func show(
        _ state : BrowState,
        animated: Bool
    ) {
        guard state != self.state else { return }
        let transition = BrowTransition.between(
            heldBrows,
            state,
            leftFirst: leftLeads
        )
        let animates = animated && !RestylingMotion.reducesMotion
        let now      = convertTime(CACurrentMediaTime(), from: nil)
        self.state = state
        heldBrows  = state
        if transition.movesLeft {
            morph(
                leftBrow,
                to      : BrowOutlines.bundled.left[state],
                duration: transition.duration,
                begin   : now + transition.leftDelay,
                animated: animates
            )
        }
        if transition.movesRight {
            morph(
                rightBrow,
                to      : BrowOutlines.bundled.right[state],
                duration: transition.duration,
                begin   : now + transition.rightDelay,
                animated: animates
            )
        }
        if animates { leftLeads.toggle() }
    }

    /// Turns the brows on the sphere toward the pointer, as the prototype's `side()` does: they
    /// shift and narrow toward the edge, and move up and down with `pitch`. `yaw` is -1...1, positive
    /// with the pointer to the right; `pitch` is -1...1, positive with the pointer below, which lifts
    /// the brows as the prototype does. An idle mascot looks right past a small dead zone, both brows
    /// together in 0.2 s.
    @MainActor
    func look(
        yaw  : Double,
        pitch: Double
    ) {
        self.yaw   = yaw
        self.pitch = pitch
        let animates = !RestylingMotion.reducesMotion
        if state == .idle {
            let wanted = yaw > 0.06 ? BrowState.look : (yaw < -0.06 ? BrowState.idle : heldBrows)
            if wanted != heldBrows {
                heldBrows = wanted
                let now = convertTime(CACurrentMediaTime(), from: nil)
                morph(
                    leftBrow,
                    to      : BrowOutlines.bundled.left[wanted],
                    duration: Self.lookSeconds,
                    begin   : now,
                    animated: animates
                )
                morph(
                    rightBrow,
                    to      : BrowOutlines.bundled.right[wanted],
                    duration: Self.lookSeconds,
                    begin   : now,
                    animated: animates
                )
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animates)
        CATransaction.setAnimationDuration(Self.lookSeconds)
        placeBrows()
        CATransaction.commit()
    }

    /// Starts the head's slow rise and fall, one breath every `RestylingTiming.headBreath`.
    /// Under Reduce Motion the head stays still. Call it once the layer has its size.
    @MainActor
    func startBreathing() {
        guard !RestylingMotion.reducesMotion else {
            removeAnimation(forKey: Self.breatheKey)
            return
        }
        let breathe = CABasicAnimation(keyPath: "transform.translation.y")
        breathe.fromValue      = 0
        breathe.toValue        = bounds.height * 0.0045
        breathe.duration       = RestylingTiming.headBreath / 2
        breathe.autoreverses   = true
        breathe.repeatCount    = .infinity
        breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.4, 1)
        add(breathe, forKey: Self.breatheKey)
    }

    /// The closed outline `points` traces, in the 240 × 170 artboard with its y axis turned up.
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x, y: artboard.height - $0.y) })
        path.closeSubpath()
        return path
    }

    private static let artboard    = CGSize(width: 240, height: 170)
    private static let lookSeconds = 0.2
    private static let breatheKey  = "breathe"
    private static var morphCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    }

    private func morph(
        _ brow   : CAShapeLayer,
        to points: [CGPoint]?,
        duration : Double,
        begin    : CFTimeInterval,
        animated : Bool
    ) {
        guard let points else { return }
        let target = Self.path(points)
        let start  = brow.presentation()?.path ?? brow.path
        let layers = outlineLayers(of: brow)
        withoutActions {
            for layer in layers {
                layer.path = target
            }
        }
        guard animated else {
            for layer in layers {
                layer.removeAnimation(forKey: "path")
            }
            return
        }
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue      = start
        morph.toValue        = target
        morph.duration       = duration
        morph.beginTime      = begin
        morph.fillMode       = .backwards
        morph.timingFunction = Self.morphCurve
        for layer in layers {
            layer.add(morph, forKey: "path")
        }
    }

    /// Places the brows by the ibrows layout on the face, the shape's inscribed circle (the whole
    /// sphere for the circle): together they span 54% of its width, 9% of that is the gap, and their
    /// line sits 36% from its top; then turns them by `yaw` and `pitch`. In a tilted room they centre
    /// on `projectedFace` instead, stretched as the camera shows the face there.
    private func placeBrows() {
        let face      = min(bounds.width, bounds.height) * shape.outline.inradius
        let span      = face * 0.54
        let sideWidth = span * 0.455
        let scale     = sideWidth / Self.artboard.width
        let stretch   = (x: projectedFace?.xScale ?? 1, y: projectedFace?.yScale ?? 1)
        let anchor    = projectedFace.map { CGPoint(x: $0.anchor.dx, y: -$0.anchor.dy) }
            ?? CGPoint(x: 0, y: Self.browLift * face)
        let centerX   = bounds.midX + anchor.x + stretch.x * sin(yaw * 0.62) * 0.025 * face
        let centerY   = bounds.midY + anchor.y + stretch.y * sin(pitch * 0.30) * 0.17 * face
        for (brow, rest, side) in [(leftBrow, -0.42, -1.0), (rightBrow, 0.42, 1.0)] {
            let angle = rest + yaw * 0.62
            let depth = abs(cos(angle))
            let shift = (sin(angle) - sin(rest)) * 0.46 * sideWidth
            brow.position = CGPoint(
                x: centerX + stretch.x * side * (span - sideWidth) / 2 + stretch.x * shift,
                y: centerY
            )
            brow.transform = CATransform3DMakeScale(
                stretch.x * scale * max(0.12, depth),
                stretch.y * scale,
                1
            )
            brow.opacity = Float(0.35 + 0.65 * min(1, depth * 1.6))
        }
    }

    /// Lights the brows' top edge with the status light when `catches` is true, as the room's light
    /// above reaches them: up to `roomLightTint` of the light at the edge, fading to white within the
    /// brow, pulsing with the room's busy flicker or waiting breath in step with `RoomLightView`. A
    /// worker that is off, or not in a room, keeps plain brows; under Reduce Motion the light holds
    /// still. Call it after every change of `status`.
    @MainActor
    func catchRoomLight(_ catches: Bool) {
        let litLayers = [leftBrow, rightBrow] + leftLight + rightLight
        for layer in litLayers {
            layer.removeAnimation(forKey: Self.roomLightKey)
        }
        guard catches, let light = status.light else {
            withoutActions {
                for copy in leftLight + rightLight {
                    copy.isHidden = true
                }
            }
            applyColors()
            return
        }
        let strength = status.lightStrength
        let white    = Self.color(hex: 0xF5F5F7)
        // The edge, and half way to white below it, at a weight of the pulse.
        func fill(
            _ weight: Float,
            share   : Double
        ) -> CGColor {
            let amount = Self.roomLightTint * strength * Double(weight) * share
            return CGColor(
                srgbRed: 0xF5 / 255.0 * (1 - amount) + light.red * amount,
                green  : 0xF5 / 255.0 * (1 - amount) + light.green * amount,
                blue   : 0xF7 / 255.0 * (1 - amount) + light.blue * amount,
                alpha  : 1
            )
        }
        let layers: [(layer: CAShapeLayer, share: Double)] =
            [leftBrow, rightBrow].map { ($0, 1) }
            + [leftLight[0], rightLight[0]].map { ($0, 0.5) }
        withoutActions {
            for (layer, share) in layers {
                layer.fillColor = fill(1, share: share)
            }
            for copy in [leftLight[1], rightLight[1]] {
                copy.fillColor = white
            }
            for copy in leftLight + rightLight {
                copy.isHidden = false
            }
        }
        for (layer, share) in layers {
            guard let pulse = RoomLightView.pulseFollowing(
                "fillColor",
                for  : status,
                in   : layer,
                value: { fill($0, share: share) }
            ) else { return }
            layer.add(
                pulse,
                forKey: Self.roomLightKey
            )
        }
    }

    /// The share of the room's light at the brows' top edge, at full strength.
    static let roomLightTint = 0.4

    static let roomLightKey = "roomLight"

    /// How deep the lit edge reaches into a brow, in the 240 × 170 artboard.
    private static let litEdge: CGFloat = 46

    /// The layers that keep `brow` white below its lit edge, nearest the edge first.
    func lightCopies(of brow: CAShapeLayer) -> [CAShapeLayer] {
        brow === leftBrow ? leftLight : rightLight
    }

    private func applyColors() {
        let isOff    = status == .off
        let strength = status.lightStrength
        // A worker that is off has no light, so the bounce is clear.
        let light = status.light.map {
            CGColor(
                srgbRed: $0.red,
                green  : $0.green,
                blue   : $0.blue,
                alpha  : 1
            )
        } ?? CGColor(gray: 0, alpha: 0)
        withoutActions {
            bounce.colors = [
                light.copy(alpha: strength * 0.6) as Any,
                light.copy(alpha: strength * 0.35) as Any,
                light.copy(alpha: 0) as Any,
            ]
            dimming.opacity = isOff ? 0.55 : 0
            let brow = isOff ? Self.color(hex: 0x6E6E6E) : Self.color(hex: 0xF5F5F7)
            leftBrow.fillColor  = brow
            rightBrow.fillColor = brow
        }
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private static func color(hex: Int) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green  : CGFloat((hex >> 8) & 0xFF) / 255,
            blue   : CGFloat(hex & 0xFF) / 255,
            alpha  : 1
        )
    }

    /// Centres a radial gradient at `x`, `top` (a fraction from the top edge, as CSS measures it)
    /// with the given radii, all in the layer's unit space.
    private static func center(
        _ gradient: CAGradientLayer,
        x         : Double,
        top       : Double,
        radiusX   : Double,
        radiusY   : Double
    ) {
        gradient.startPoint = CGPoint(
            x: x,
            y: 1 - top
        )
        gradient.endPoint = CGPoint(
            x: x + radiusX,
            y: 1 - top + radiusY
        )
    }
}
