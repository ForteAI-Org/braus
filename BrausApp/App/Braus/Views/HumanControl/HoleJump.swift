//
//  HoleJump.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import QuartzCore

/// HoleJump is the Core Animation of a worker jumping through a hole on `HumanControlBeats`, shared
/// by the companion on the person's screen (`HumanControlOverlay`) and the worker on its screen
/// window's corner (`ScreenPresenceView`): the hole opening and closing, the figure scaled about its
/// foot and risen, and the mask that sinks it behind the hole's front rim.
@MainActor
enum HoleJump {

    /// The hole opening, waiting and closing again over `duration`, on its scale.
    static func opening(duration: Double) -> CAAnimation {
        let open = CAKeyframeAnimation(keyPath: "transform.scale")
        open.values   = HumanControlBeats.hole.values
        open.keyTimes = HumanControlBeats.hole.times.map { NSNumber(value: $0) }
        open.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]
        return held(
            open,
            duration: duration
        )
    }

    /// `beats` on `body`: its width and height about its foot, and its rise in its own heights.
    static func figure(
        _ beats : HumanControlBeats,
        of body : CALayer,
        duration: Double
    ) -> CAAnimation {
        // The layer scales about its anchor; the foot stays put when the translation makes up for it.
        let foot   = CGPoint(
            x: (0.5 - body.anchorPoint.x) * body.bounds.width,
            y: -body.anchorPoint.y * body.bounds.height
        )
        let height = Double(body.bounds.height)
        let lifts  = zip(beats.scaleY, beats.rise).map { scale, rise in
            Double(foot.y) * (1 - scale) + rise * height
        }
        return group(
            [
                ("transform.scale.x", beats.scaleX),
                ("transform.scale.y", beats.scaleY),
                ("transform.translation.x", beats.scaleX.map { Double(foot.x) * (1 - $0) }),
                ("transform.translation.y", lifts),
            ],
            beats   : beats,
            duration: duration
        )
    }

    /// What shows of a pit in `bounds`, y up: everything above the ground through the hole's centre,
    /// and the hole's near half below it, so the worker sinks behind the hole's front rim.
    static func groundMask(
        hole ground: CGPoint,
        size       : CGSize,
        in bounds  : CGRect
    ) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: ground.y))
        path.addLine(to: CGPoint(x: ground.x - size.width / 2, y: ground.y))
        path.addArc(
            center    : .zero,
            radius    : 1,
            startAngle: .pi,
            endAngle  : 2 * .pi,
            clockwise : false,
            transform : CGAffineTransform(
                translationX: ground.x,
                y           : ground.y
            ).scaledBy(
                x: size.width / 2,
                y: size.height / 2
            )
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: ground.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: 0, y: bounds.maxY))
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path  = path
        return mask
    }

    /// One keyframe track per key path on `beats`' times and eases, translations added to the float.
    static func group(
        _ tracks: [(String, [Double])],
        beats   : HumanControlBeats,
        duration: Double
    ) -> CAAnimation {
        let group = CAAnimationGroup()
        group.animations = tracks.map { keyPath, values in
            let track = CAKeyframeAnimation(keyPath: keyPath)
            track.values          = values
            track.keyTimes        = beats.times.map { NSNumber(value: $0) }
            track.timingFunctions = beats.curves.map(timing)
            track.isAdditive      = keyPath.hasPrefix("transform.translation")
            return track
        }
        return held(
            group,
            duration: duration
        )
    }

    /// `animation` over `duration`, holding its last frame until it is removed.
    static func held(
        _ animation: CAAnimation,
        duration   : Double
    ) -> CAAnimation {
        animation.duration              = duration
        animation.fillMode              = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func timing(_ curve: HumanControlBeats.Curve) -> CAMediaTimingFunction {
        switch curve {
        case .linear   : CAMediaTimingFunction(name: .linear)
        case .easeIn   : CAMediaTimingFunction(name: .easeIn)
        case .easeOut  : CAMediaTimingFunction(name: .easeOut)
        case .easeInOut: CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}
