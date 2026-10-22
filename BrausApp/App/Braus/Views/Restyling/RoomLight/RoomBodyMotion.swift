//
//  RoomBodyMotion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore

/// RoomBodyMotion is how a worker's body moves in its tilted room with its brows' loop, or with an
/// action of its own: the body's poses (`BodyPose`) as the room's poses, which the room bakes into
/// frames, and keyframes that play them over the loop in step with the brows.
///
/// The behaviour gives every gesture's poses, half way and whole, and the keyframes cross-fade between
/// their frames; at rest the room's own frames show. A room bakes at most `maxPoses`, the poses its
/// gestures take most; a gesture that needs another is left out, its brows moving alone. Every pose
/// stays within `BodyPose`'s limits. The brows over the body follow the face the camera shows, moving,
/// turning and scaling with it (`browMotion()`), and a room clipped to its worker's outline moves the
/// outline with it (`outline()`).
nonisolated struct RoomBodyMotion: Equatable {

    /// Keyframe is the body's pose `time` seconds into the loop: one of `poses`, or nil at rest.
    struct Keyframe: Equatable {
        let time: Double
        let pose: Int?
    }

    /// FaceMove is how the brows move with a pose, for the layer that holds them, scaled and turned
    /// about the room's centre: shifted by `shift` points, y up, turned by `turn` radians and scaled by
    /// `scale`.
    struct FaceMove: Equatable {
        let shift: CGPoint
        let turn : Double
        let scale: Double
    }

    let duration : Double
    let poses    : [RoomLightUniforms.Pose]
    let keyframes: [Keyframe]
    let faceMoves: [FaceMove]

    /// The worker and the room the motion is for, which give the body's outlines when a room clipped
    /// to them asks (`outline()`).
    let shape: WorkerShape
    let size : CGSize
    let lean : Float

    /// The most poses a room bakes for its body's motion: two frames each for a light that pulses.
    static let maxPoses = 10

    /// The motion of `loop`'s intents for a worker of `shape` in a tilted room of `size` leaning
    /// `lean`, or nil when it has none or its worker is off.
    init?(
        loop : WorkerBehaviourLoop,
        shape: WorkerShape,
        size : CGSize,
        lean : Float
    ) {
        guard loop.status != .off else { return nil }
        self.init(
            intents : loop.intents,
            duration: loop.duration,
            shape   : shape,
            size    : size,
            lean    : lean
        )
    }

    /// The motion of `intents` over a loop of `duration` seconds, or nil when none of them moves. A
    /// loop that `opensAtRest` starts and ends at rest; otherwise its intents' keys run from its start
    /// to its end, as an action's do (`WorkerAction`).
    init?(
        intents    : [WorkerBehaviourLoop.BodyIntent],
        duration   : Double,
        shape      : WorkerShape,
        size       : CGSize,
        lean       : Float,
        opensAtRest: Bool = true
    ) {
        guard duration > 0 else { return nil }
        let side = Float(min(size.width, size.height))
        // A body pose as the room's, within the limits; nil at rest.
        func room(_ body: BodyPose) -> RoomLightUniforms.Pose? {
            guard body != .rest else { return nil }
            func clamp(_ value: Double, _ limit: Double) -> Float {
                Float(max(-limit, min(limit, value)))
            }
            return RoomLightUniforms.Pose(
                tilt   : clamp(body.tilt, BodyPose.maxTurn),
                hop    : clamp(max(0, body.hop), BodyPose.maxHop) * side,
                slide  : clamp(body.slide, BodyPose.maxMove) * side,
                shift  : clamp(body.shift, BodyPose.maxMove) * side,
                stretch: 1 + clamp(body.stretch, BodyPose.maxStretch),
                lean   : clamp(body.lean, BodyPose.maxTurn)
            )
        }
        // The poses the gestures take most, up to the limit, in the order they first come.
        var counts: [RoomLightUniforms.Pose: Int] = [:]
        var order : [RoomLightUniforms.Pose] = []
        for intent in intents {
            for key in intent.keys {
                guard let pose = room(key.pose) else { continue }
                if counts[pose] == nil { order.append(pose) }
                counts[pose, default: 0] += 1
            }
        }
        let ranked = order.enumerated().sorted {
            (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset)
        }
        let kept  = Set(ranked.prefix(Self.maxPoses).map(\.element))
        let poses = order.filter { kept.contains($0) }
        guard !poses.isEmpty else { return nil }
        var keyframes = opensAtRest ? [Keyframe(
            time: 0,
            pose: nil
        )] : []
        for intent in intents {
            let steps = intent.keys.map { key in (time: intent.time + key.time, pose: room(key.pose)) }
            guard steps.allSatisfy({ $0.pose.map(kept.contains) ?? true }) else { continue }
            keyframes += steps.map { step in
                Keyframe(
                    time: step.time,
                    pose: step.pose.flatMap { poses.firstIndex(of: $0) }
                )
            }
        }
        if opensAtRest {
            keyframes.append(Keyframe(
                time: duration,
                pose: nil
            ))
        }
        self.duration  = duration
        self.poses     = poses
        self.keyframes = keyframes
        let camera = RoomCamera.Perspective(
            size: size,
            lean: lean
        )
        faceMoves = poses.map {
            Self.faceMove(
                of    : shape,
                camera: camera,
                pose  : $0
            )
        }
        self.shape = shape
        self.size  = size
        self.lean  = lean
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

    /// The brows' additive shift, turn and change of scale with the body, for the layer that holds
    /// them, by the key each takes on it.
    func browMotion() -> [String: CAKeyframeAnimation] {
        let moves  = keyframes.map { $0.pose.map { faceMoves[$0] } }
        let parts: [(key: String, keyPath: String, values: [Any])] = [
            (Self.browKeys[0], "position", moves.map { NSValue(point: $0?.shift ?? .zero) }),
            (Self.browKeys[1], "transform.rotation.z", moves.map { $0?.turn ?? 0 }),
            (Self.browKeys[2], "transform.scale", moves.map { ($0?.scale ?? 1) - 1 }),
        ]
        var result: [String: CAKeyframeAnimation] = [:]
        for part in parts {
            let motion = animation(
                part.keyPath,
                values: part.values
            )
            motion.isAdditive = true
            result[part.key]  = motion
        }
        return result
    }

    /// The keys of `browMotion()`'s animations.
    static let browKeys = ["body.shift", "body.turn", "body.scale"]

    /// The path of an outline that clips the room to its worker, moving with the body: the body's
    /// outline at rest and in each pose, in a layer of the room's size, y up, each the same points in
    /// the same order (`RoomCamera.Perspective.silhouette(of:pose:samples:)`).
    @MainActor
    func outline() -> CAKeyframeAnimation {
        let outlines = ([RoomLightUniforms.Pose.rest] + poses).map(outline)
        return animation(
            "path",
            values: keyframes.map { keyframe in
                outlines[keyframe.pose.map { $0 + 1 } ?? 0]
            }
        )
    }

    /// The body's outline in `pose`, in a layer of the room's size, y up, built once.
    @MainActor
    func outline(_ pose: RoomLightUniforms.Pose) -> CGPath {
        let key = OutlineKey(
            shape : shape,
            width : size.width,
            height: size.height,
            lean  : lean,
            pose  : pose
        )
        if let known = Self.outlines[key] { return known }
        var flip = CGAffineTransform(
            a : 1,
            b : 0,
            c : 0,
            d : -1,
            tx: 0,
            ty: size.height
        )
        let path = RoomCamera.Perspective(
            size: size,
            lean: lean
        ).silhouette(
            of  : shape,
            pose: pose
        )
        let outline = path.copy(using: &flip) ?? path
        // ponytail: an unbounded cache, a few hundred paths for a house; bound it if rooms grow many sizes.
        Self.outlines[key] = outline
        return outline
    }

    /// OutlineKey names an outline already built: the worker, the room and the pose.
    private struct OutlineKey: Hashable {
        let shape : WorkerShape
        let width : CGFloat
        let height: CGFloat
        let lean  : Float
        let pose  : RoomLightUniforms.Pose
    }

    @MainActor
    private static var outlines: [OutlineKey: CGPath] = [:]

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

    /// How the brows of `shape` move when the body takes `pose`, as `camera` shows them: the layer that
    /// holds them turns and scales about the room's centre, so the shift is what brings the brows from
    /// there onto the face.
    private static func faceMove(
        of shape: WorkerShape,
        camera  : RoomCamera.Perspective,
        pose    : RoomLightUniforms.Pose
    ) -> FaceMove {
        let rest  = camera.face(of: shape)
        let moved = camera.face(
            of  : shape,
            pose: pose
        )
        let turn  = moved.turn - rest.turn
        let scale = moved.xScale / rest.xScale * Double(pose.scale) / Double(pose.stretch).squareRoot()
        // The anchors with y up.
        let from  = (x: rest.anchor.dx, y: -rest.anchor.dy)
        let to    = (x: moved.anchor.dx, y: -moved.anchor.dy)
        return FaceMove(
            shift: CGPoint(
                x: to.x - scale * (from.x * cos(turn) - from.y * sin(turn)),
                y: to.y - scale * (from.x * sin(turn) + from.y * cos(turn))
            ),
            turn : turn,
            scale: scale
        )
    }

    /// The flat transform that carries three points of the body at rest, its foot, a point above it and
    /// one beside it, to where `pose` shows them through `camera`, in the room's layer, y up.
    static func outlineTransform(
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
