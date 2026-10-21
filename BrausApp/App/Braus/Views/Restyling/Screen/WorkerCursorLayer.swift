//
//  WorkerCursorLayer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore

/// WorkerCursorLayer draws the worker's own pointer over its screen, never the person's: an arrow
/// with the worker's face attached, travelling in 0.7 s between the points it is sent to, and an
/// amber ring that grows and fades in 0.5 s where it clicks.
///
/// Points are fractions of the bounds from the top left. Under Reduce Motion the pointer jumps and
/// clicks leave no ring. Nonisolated like `CALayer`; the methods that read `RestylingMotion` are
/// main-actor isolated.
nonisolated final class WorkerCursorLayer: CALayer {

    /// Where the pointer's tip rests, as fractions of the bounds from the top left.
    private(set) var target = CGPoint(
        x: 0.5,
        y: 0.5
    )

    /// The worker's face beside the arrow.
    let face = MascotLayer()

    private let pointer = CALayer()
    private let arrow   = CAShapeLayer()
    private let ring    = CAShapeLayer()

    /// The arrow's side; its tip sits 3 points in and 2 down, after the prototype's drawing.
    private static let arrowSide: CGFloat = 22
    private static let tip = CGPoint(
        x: 3,
        y: 2
    )
    private static let faceSide: CGFloat = 18

    private static let travelKey = "travel"
    private static let ringKey   = "ring"

    override init() {
        super.init()
        let side = Self.arrowSide
        pointer.bounds      = CGRect(
            x     : 0,
            y     : 0,
            width : side,
            height: side
        )
        pointer.anchorPoint = CGPoint(
            x: Self.tip.x / side,
            y: 1 - Self.tip.y / side
        )
        pointer.shadowOpacity = 0.5
        pointer.shadowRadius  = 2
        pointer.shadowOffset  = CGSize(
            width : 0,
            height: -2
        )

        // The prototype's arrow, drawn top down, turned into the layer's bottom-up space.
        let outline: [(CGFloat, CGFloat)] = [(3, 2), (3, 18), (7.5, 13.8), (10.5, 20), (13, 19), (10, 12.8), (16, 12.8)]
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: $0.0, y: side - $0.1) })
        path.closeSubpath()
        arrow.path        = path
        arrow.fillColor   = CGColor(gray: 1, alpha: 1)
        arrow.strokeColor = CGColor(gray: 0, alpha: 1)
        arrow.lineWidth   = 1.2
        arrow.frame       = pointer.bounds
        pointer.addSublayer(arrow)

        face.frame = CGRect(
            x     : 16,
            y     : side - 16 - Self.faceSide,
            width : Self.faceSide,
            height: Self.faceSide
        )
        pointer.addSublayer(face)

        ring.path        = CGPath(
            ellipseIn: CGRect(x: -15, y: -15, width: 30, height: 30),
            transform: nil
        )
        ring.fillColor   = nil
        ring.strokeColor = CGColor(
            srgbRed: 1,
            green  : 176.0 / 255,
            blue   : 72.0 / 255,
            alpha  : 1
        )
        ring.lineWidth   = 2
        ring.opacity     = 0
        addSublayer(ring)
        addSublayer(pointer)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var contentsScale: CGFloat {
        didSet {
            for layer in [pointer, arrow, ring, face] {
                layer.contentsScale = contentsScale
            }
        }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = point(of: target)
        CATransaction.commit()
    }

    /// Sends the pointer's tip to `target`: a 0.7 s ease-in-out travel from wherever it shows now,
    /// or a jump under Reduce Motion.
    @MainActor
    func move(to target: CGPoint) {
        self.target = target
        let start = pointer.presentation()?.position ?? pointer.position
        let end   = point(of: target)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = end
        CATransaction.commit()
        guard !RestylingMotion.reducesMotion else {
            pointer.removeAnimation(forKey: Self.travelKey)
            return
        }
        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue      = NSValue(point: start)
        travel.toValue        = NSValue(point: end)
        travel.duration       = 0.7
        travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
        pointer.add(
            travel,
            forKey: Self.travelKey
        )
    }

    /// Clicks where the pointer rests: a ring grows from 0.3 to 1.6 times its size and fades over
    /// 0.5 s. Nothing under Reduce Motion.
    @MainActor
    func click() {
        guard !RestylingMotion.reducesMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = point(of: target)
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue   = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue   = 0
        let ripple = CAAnimationGroup()
        ripple.animations     = [grow, fade]
        ripple.duration       = 0.5
        ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(
            ripple,
            forKey: Self.ringKey
        )
    }

    private func point(of target: CGPoint) -> CGPoint {
        CGPoint(
            x: target.x * bounds.width,
            y: (1 - target.y) * bounds.height
        )
    }
}
