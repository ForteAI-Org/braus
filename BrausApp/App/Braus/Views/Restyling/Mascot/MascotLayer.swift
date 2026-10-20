//
//  MascotLayer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import QuartzCore

/// MascotLayer draws a worker's mascot: a dark sphere tinted with the worker's colour and lit by
/// its status light, with two brows that morph from one expression to the next.
///
/// The head never changes colour for an outcome, since the room light tells it; only a worker that
/// is off dims the body and greys the brows. Every motion asks `RestylingMotion` first: under
/// Reduce Motion a morph is a cut, the brows turn without travel and the head does not breathe.
/// Nonisolated like `CALayer`, whose overrides it needs; the methods that read `RestylingMotion`
/// are main-actor isolated, and the layer belongs to the main thread like every tree the app owns.
nonisolated final class MascotLayer: CALayer {

    /// The worker's colour, blended into the sphere.
    var tint = NSColor.gray {
        didSet { applyColors() }
    }

    /// What the worker is doing: its light colours the highlight and the bounce at the bottom.
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

    private let body      = CALayer()
    private let base      = CAGradientLayer()
    private let tintLight = CAGradientLayer()
    private let bounce    = CAGradientLayer()
    private let highlight = CAGradientLayer()
    private let dimming   = CALayer()

    /// The expression last shown.
    private var state = BrowState.idle

    /// The outline the brows hold: `state`, or `look` while an idle mascot looks to the right.
    private var shape = BrowState.idle

    private var yaw  : Double = 0
    private var pitch: Double = 0

    /// Which brow leads the next calm change; it alternates, as the prototype's random order varies.
    private var leftLeads = true

    override init() {
        super.init()
        for gradient in [base, tintLight, bounce, highlight] {
            gradient.type = .radial
            body.addSublayer(gradient)
        }
        body.addSublayer(dimming)
        body.masksToBounds = true
        addSublayer(body)

        base.colors = [
            Self.color(hex: 0x343230),
            Self.color(hex: 0x262423),
            Self.color(hex: 0x141313),
        ]
        base.locations = [0, 0.44, 1]
        Self.center(
            base,
            x      : 0.37,
            top    : 0.30,
            radiusX: 0.942,
            radiusY: 0.942
        )

        tintLight.compositingFilter = "colorBlendMode"
        tintLight.locations         = [0, 0.5, 1]
        Self.center(
            tintLight,
            x      : 0.37,
            top    : 0.30,
            radiusX: 0.942,
            radiusY: 0.942
        )

        bounce.locations = [0, 0.38, 0.46]
        Self.center(
            bounce,
            x      : 0.5,
            top    : 1.25,
            radiusX: 1.2,
            radiusY: 0.6
        )

        highlight.locations = [0, 0.025, 0.05, 0.11]
        Self.center(
            highlight,
            x      : 0.36,
            top    : 0.24,
            radiusX: 0.994,
            radiusY: 0.994
        )

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
        applyColors()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        withoutActions {
            body.frame        = bounds
            body.cornerRadius = min(bounds.width, bounds.height) / 2
            for layer in body.sublayers ?? [] {
                layer.frame = body.bounds
            }
            placeBrows()
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
            shape,
            state,
            leftFirst: leftLeads
        )
        let animates = animated && !RestylingMotion.reducesMotion
        let now      = convertTime(CACurrentMediaTime(), from: nil)
        self.state = state
        shape      = state
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
            let wanted = yaw > 0.06 ? BrowState.look : (yaw < -0.06 ? BrowState.idle : shape)
            if wanted != shape {
                shape = wanted
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
        withoutActions { brow.path = target }
        guard animated else {
            brow.removeAnimation(forKey: "path")
            return
        }
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue      = start
        morph.toValue        = target
        morph.duration       = duration
        morph.beginTime      = begin
        morph.fillMode       = .backwards
        morph.timingFunction = Self.morphCurve
        brow.add(morph, forKey: "path")
    }

    /// Places the brows by the ibrows layout: together they span 54% of the width, 9% of that is
    /// the gap, and their line sits 36% from the top; then turns them by `yaw` and `pitch`.
    private func placeBrows() {
        let width     = bounds.width
        let span      = width * 0.54
        let sideWidth = span * 0.455
        let scale     = sideWidth / Self.artboard.width
        let centerX   = bounds.midX + sin(yaw * 0.62) * 0.025 * width
        let centerY   = bounds.height * (1 - 0.36) + sin(pitch * 0.30) * 0.17 * width
        for (brow, rest, side) in [(leftBrow, -0.42, -1.0), (rightBrow, 0.42, 1.0)] {
            let angle = rest + yaw * 0.62
            let depth = abs(cos(angle))
            let shift = (sin(angle) - sin(rest)) * 0.46 * sideWidth
            brow.position = CGPoint(
                x: centerX + side * (span - sideWidth) / 2 + shift,
                y: centerY
            )
            brow.transform = CATransform3DMakeScale(
                scale * max(0.12, depth),
                scale,
                1
            )
            brow.opacity = Float(0.35 + 0.65 * min(1, depth * 1.6))
        }
    }

    private func applyColors() {
        let isOff = status == .off
        // A worker that is off has no light; its highlight takes the prototype's grey.
        let rgb   = status.light ?? (red: 120.0 / 255, green: 120.0 / 255, blue: 124.0 / 255)
        let light = CGColor(
            srgbRed: rgb.red,
            green  : rgb.green,
            blue   : rgb.blue,
            alpha  : 1
        )
        let strength = status.lightStrength
        let tint     = self.tint.cgColor
        withoutActions {
            tintLight.colors = [0.55, 0.28, 0.10].map { tint.copy(alpha: $0) as Any }
            bounce.colors = [
                light.copy(alpha: strength * 0.9) as Any,
                light.copy(alpha: strength * 0.35) as Any,
                light.copy(alpha: 0) as Any,
            ]
            highlight.colors = [
                CGColor(gray: 1, alpha: 0.9),
                CGColor(gray: 1, alpha: 0.5),
                light.copy(alpha: 0.45) as Any,
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
