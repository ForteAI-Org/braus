//
//  RoomBodyMotion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore

/// RoomBodyMotion is how a worker's body moves in its tilted room with its brows' loop: the loop's body
/// intents, a tiny tilt to one side or a small hop, as poses the room bakes into frames, and keyframes
/// that play them over the loop in step with the brows.
///
/// A gesture goes from rest through half its pose to all of it and back, and Core Animation
/// cross-fades between their frames; at rest the room's own frames show. Each direction, a tilt left,
/// one right and a hop, bakes its widest gesture and half of it, and a gesture under three quarters of
/// that stops at the half, so a room bakes at most six poses.
///
/// A tilt leans over the brows' glance and holds; a hop rises and falls as thrown, quick off the floor
/// and slow at the top. A tilt stays within `maxTilt`, a hop within `maxHop` of the room's short side.
/// The brows over the body follow the face's projected shift (`browShift()`), and a room clipped to its
/// worker's outline moves the outline with it (`outline()`).
nonisolated struct RoomBodyMotion: Equatable {

    /// Keyframe is the body's pose `time` seconds into the loop: one of `poses`, or nil at rest.
    struct Keyframe: Equatable {
        let time: Double
        let pose: Int?
    }

    let duration : Double
    let poses    : [RoomLightUniforms.Pose]
    let keyframes: [Keyframe]

    /// How far the brows move with each pose, in points in the room's layer, y up.
    let faceShifts: [CGPoint]

    /// What carries the body's outline at rest to where each pose shows it, in a layer of the room's
    /// size, y up, about its origin.
    let outlineTransforms: [CGAffineTransform]

    /// The most a body tilts, in radians, and hops, as a share of the room's short side.
    static let maxTilt = 4 * Double.pi / 180
    static let maxHop  = 0.03

    /// How long a tilt takes to lean over and to come back, as the brows' glance moves.
    static let tiltRise = 0.45
    static let tiltFall = 0.5

    /// When a thrown hop reaches half its height and its top, as shares of its time.
    static let hopHalf = 0.146
    static let hopTop  = 0.5

    /// The motion of `loop`'s intents for a worker of `shape` in a tilted room of `size` leaning
    /// `lean`, or nil when it has none or its worker is off.
    init?(
        loop : WorkerBehaviourLoop,
        shape: WorkerShape,
        size : CGSize,
        lean : Float
    ) {
        guard loop.status != .off, loop.duration > 0 else { return nil }
        // A hop is a share of the face's width, the shape's inscribed circle.
        let radius = Double(RoomLightUniforms.Shape(
            size: size,
            lean: lean
        ).sphereRadius)
        let face = 2 * radius * shape.outline.inradius
        let side = Double(min(size.width, size.height))
        // A gesture's whole pose: a turn in radians or a hop in points, within the limits.
        func reach(_ kind: WorkerBehaviourLoop.BodyIntent.Kind) -> RoomLightUniforms.Pose {
            switch kind {
            case .tilt(let angle): RoomLightUniforms.Pose(tilt: Float(max(-Self.maxTilt, min(Self.maxTilt, angle))))
            case .hop(let share) : RoomLightUniforms.Pose(hop: Float(min(share * face, Self.maxHop * side)))
            }
        }
        // Left, right or up, and how far along it.
        func direction(_ pose: RoomLightUniforms.Pose) -> Int {
            pose.hop > 0 ? 2 : (pose.tilt > 0 ? 1 : 0)
        }
        func extent(_ pose: RoomLightUniforms.Pose) -> Float {
            abs(pose.tilt) + pose.hop
        }
        // Each direction bakes its widest gesture and half of it; a narrower gesture stops at the half.
        var widest: [Int: RoomLightUniforms.Pose] = [:]
        for intent in loop.intents {
            let pose = reach(intent.kind)
            guard pose != .rest else { continue }
            if extent(pose) > widest[direction(pose)].map(extent) ?? 0 { widest[direction(pose)] = pose }
        }
        var poses    : [RoomLightUniforms.Pose] = []
        var keyframes = [Keyframe(
            time: 0,
            pose: nil
        )]
        for intent in loop.intents {
            let target = reach(intent.kind)
            guard target != .rest, let full = widest[direction(target)] else { continue }
            let isWhole  = extent(target) > 0.75 * extent(full)
            let duration = intent.duration
            let steps: [(time: Double, share: Double)]
            switch (intent.kind, isWhole) {
            case (.tilt, true):
                let rise = min(Self.tiltRise, duration / 3)
                let fall = min(Self.tiltFall, duration / 3)
                steps = [
                    (0, 0),
                    (rise / 2, 0.5),
                    (rise, 1),
                    (duration - fall, 1),
                    (duration - fall / 2, 0.5),
                    (duration, 0),
                ]
            case (.tilt, false):
                let rise = min(Self.tiltRise, duration / 3)
                let fall = min(Self.tiltFall, duration / 3)
                steps = [
                    (0, 0),
                    (rise, 0.5),
                    (duration - fall, 0.5),
                    (duration, 0),
                ]
            case (.hop, true):
                steps = [
                    (0, 0),
                    (Self.hopHalf * duration, 0.5),
                    (Self.hopTop * duration, 1),
                    ((1 - Self.hopHalf) * duration, 0.5),
                    (duration, 0),
                ]
            case (.hop, false):
                steps = [
                    (0, 0),
                    (Self.hopTop * duration, 0.5),
                    (duration, 0),
                ]
            }
            let half = RoomLightUniforms.Pose(
                tilt: full.tilt / 2,
                hop : full.hop / 2
            )
            for step in steps {
                var index: Int?
                if step.share > 0 {
                    let pose = step.share < 1 ? half : full
                    index = poses.firstIndex(of: pose) ?? poses.count
                    if index == poses.count { poses.append(pose) }
                }
                keyframes.append(Keyframe(
                    time: intent.time + step.time,
                    pose: index
                ))
            }
        }
        guard !poses.isEmpty else { return nil }
        keyframes.append(Keyframe(
            time: loop.duration,
            pose: nil
        ))
        duration       = loop.duration
        self.poses     = poses
        self.keyframes = keyframes
        let camera = RoomCamera.Perspective(
            size: size,
            lean: lean
        )
        faceShifts = poses.map {
            Self.faceShift(
                of    : shape,
                camera: camera,
                pose  : $0
            )
        }
        outlineTransforms = poses.map {
            Self.outlineTransform(
                camera: camera,
                radius: radius,
                pose  : $0
            )
        }
    }

    /// How much of the baked frames shows over the room's own: all of it in a gesture, none at rest.
    func envelope() -> CAKeyframeAnimation {
        animation(
            "opacity",
            values: keyframes.map { $0.pose == nil ? 0.0 : 1.0 }
        )
    }

    /// The frames to show, `frames` holding one per pose in the order of `poses`: at rest the pose next
    /// to it in its gesture, from which the envelope fades in or to which it fades out.
    func frames(_ frames: [CGImage]) -> CAKeyframeAnimation {
        animation(
            "contents",
            values: keyframes.indices.map { frames[shownPose(at: $0)] }
        )
    }

    /// The brows' additive shift with the body, for the layer that holds them.
    func browShift() -> CAKeyframeAnimation {
        let shift = animation(
            "position",
            values: keyframes.map { NSValue(point: $0.pose.map { faceShifts[$0] } ?? .zero) }
        )
        shift.isAdditive = true
        return shift
    }

    /// The transform of an outline that clips the room to its worker, moving with the body.
    func outline() -> CAKeyframeAnimation {
        animation(
            "transform",
            values: keyframes.map { keyframe in
                NSValue(caTransform3D: CATransform3DMakeAffineTransform(
                    keyframe.pose.map { outlineTransforms[$0] } ?? .identity
                ))
            }
        )
    }

    /// The pose a frame shows at keyframe `index`: its own, or at rest its gesture's next or last.
    private func shownPose(at index: Int) -> Int {
        let next     = keyframes.indices.contains(index + 1) ? keyframes[index + 1].pose : nil
        let previous = index > 0 ? keyframes[index - 1].pose : nil
        return keyframes[index].pose ?? next ?? previous ?? 0
    }

    /// An animation of `keyPath` through `values`, one per keyframe, over the loop, repeating; its
    /// `beginTime` is the brows' loop's, which the caller sets.
    private func animation(
        _ keyPath: String,
        values   : [Any]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values          = values
        animation.keyTimes        = keyframes.map { NSNumber(value: $0.time / duration) }
        animation.calculationMode = .linear
        animation.duration        = duration
        animation.repeatCount     = .infinity
        return animation
    }

    /// How far the brows of `shape` move when the body takes `pose`, as `camera` shows them, y up.
    private static func faceShift(
        of shape: WorkerShape,
        camera  : RoomCamera.Perspective,
        pose    : RoomLightUniforms.Pose
    ) -> CGPoint {
        let rest  = camera.face(of: shape).anchor
        let moved = camera.face(
            of  : shape,
            pose: pose
        ).anchor
        return CGPoint(
            x: moved.dx - rest.dx,
            y: rest.dy - moved.dy
        )
    }

    /// The flat transform that carries three points of the body at rest, its foot, a point above it and
    /// one beside it, to where `pose` shows them through `camera`, in the room's layer, y up.
    private static func outlineTransform(
        camera: RoomCamera.Perspective,
        radius: Double,
        pose  : RoomLightUniforms.Pose
    ) -> CGAffineTransform {
        let foot   = SIMD3(camera.bodyX, camera.bodyDepth, 0)
        let points = [foot, foot + SIMD3(0, 0, radius), foot + SIMD3(radius, 0, 0)]
        func shown(_ point: SIMD3<Double>) -> CGPoint {
            let projected = camera.project(point)
            return CGPoint(
                x: projected.x,
                y: camera.size.height - projected.y
            )
        }
        let from = points.map(shown)
        let to   = points.map {
            shown(pose.moved(
                $0,
                foot: foot
            ))
        }
        // The linear part takes the rest's two arms from the foot to the pose's, then the foot follows.
        let up        = (x: from[1].x - from[0].x, y: from[1].y - from[0].y)
        let side      = (x: from[2].x - from[0].x, y: from[2].y - from[0].y)
        let movedUp   = (x: to[1].x - to[0].x, y: to[1].y - to[0].y)
        let movedSide = (x: to[2].x - to[0].x, y: to[2].y - to[0].y)
        let det       = up.x * side.y - side.x * up.y
        guard abs(det) > 1e-9 else { return .identity }
        let a = (movedUp.x * side.y - movedSide.x * up.y) / det
        let c = (movedSide.x * up.x - movedUp.x * side.x) / det
        let b = (movedUp.y * side.y - movedSide.y * up.y) / det
        let d = (movedSide.y * up.x - movedUp.y * side.x) / det
        return CGAffineTransform(
            a : a,
            b : b,
            c : c,
            d : d,
            tx: to[0].x - (a * from[0].x + c * from[0].y),
            ty: to[0].y - (b * from[0].x + d * from[0].y)
        )
    }
}
