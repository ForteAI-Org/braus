//
//  RoomPassage.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore

/// RoomPassage is a worker stepping out of its tilted room toward the camera as it leaves for the
/// chat, or back in as it returns, over `RestylingTiming.roomExit`: the poses the room bakes into
/// frames, and keyframes that play them over the empty room.
///
/// Leaving, the body holds still while the brows look toward the camera (`look`), then hops toward
/// the room's open front, shrinking a little, and fades into the empty room on its way, its shadow
/// going with it in every frame. Coming back plays the same backwards. The brows follow the face the
/// camera shows (`browShift()`, `browScale()`) and fade with the body. Under Reduce Motion the body
/// only fades out or in, at rest.
nonisolated struct RoomPassage: Equatable {

    /// Keyframe is the passage `time` seconds in: the frame of `poses[pose]`, shown at `opacity` over
    /// the empty room.
    struct Keyframe: Equatable {
        let time   : Double
        let pose   : Int
        let opacity: Double
    }

    let isLeaving: Bool

    /// The poses the room bakes, rest first.
    let poses    : [RoomLightUniforms.Pose]
    let keyframes: [Keyframe]

    /// How far the brows move with each pose, in points in the room's layer, y up, once the layer
    /// holding them is scaled by `faceScales` about the room's centre.
    let faceShifts: [CGPoint]
    let faceScales: [Double]

    var duration: Double {
        RestylingTiming.roomExit
    }

    /// The share of the passage the brows look toward the camera, the body still, before it moves.
    static let lookShare = 0.22

    /// The brows' look toward the camera: raised, their inner ends lifted.
    static let look = BrowPose(
        dy      : 0.025,
        rotation: 0.05
    )

    /// The poses on the way out after rest, how far the body slides toward the camera and how high it
    /// hops at the top of its arc, in sphere radii, how much smaller it is by the end, and the share
    /// of the way after which it fades.
    static let steps    = 8
    static let slide    = 2.4
    static let hop      = 0.3
    static let shrink   = 0.4
    static let fadeFrom = 0.5

    /// The passage of a worker of `shape` out of a tilted room of `size` leaning `lean`, or back in.
    init(
        isLeaving    : Bool,
        shape        : WorkerShape,
        size         : CGSize,
        lean         : Float,
        reducesMotion: Bool
    ) {
        self.isLeaving = isLeaving
        let radius = Double(RoomLightUniforms.Shape(
            size: size,
            lean: lean
        ).sphereRadius)
        let ways = reducesMotion ? [0] : (0...Self.steps).map { Double($0) / Double(Self.steps) }
        poses = ways.map { way in
            way == 0 ? .rest : RoomLightUniforms.Pose(
                hop  : Float(Self.hop * radius * sin(Double.pi * way)),
                slide: Float(Self.slide * radius * way),
                scale: Float(1 - Self.shrink * way)
            )
        }
        // Leaving, as shares of the passage: still while the brows look, then out, fading on the way.
        let out: [(share: Double, pose: Int, opacity: Double)] = reducesMotion
            ? [(0, 0, 1), (1, 0, 0)]
            : [(0, 0, 1), (Self.lookShare, 0, 1)] + ways.indices.dropFirst().map { index in
                let way = ways[index]
                return (
                    Self.lookShare + (1 - Self.lookShare) * way,
                    index,
                    way <= Self.fadeFrom ? 1 : 1 - (way - Self.fadeFrom) / (1 - Self.fadeFrom)
                )
            }
        let steps = isLeaving ? out : out.reversed().map { (1 - $0.share, $0.pose, $0.opacity) }
        let duration = RestylingTiming.roomExit
        keyframes = steps.map {
            Keyframe(
                time   : $0.share * duration,
                pose   : $0.pose,
                opacity: $0.opacity
            )
        }
        let camera = RoomCamera.Perspective(
            size: size,
            lean: lean
        )
        let rest = camera.face(of: shape)
        let faces = poses.map {
            camera.face(
                of  : shape,
                pose: $0
            )
        }
        faceScales = zip(poses, faces).map { Double($0.scale) * $1.xScale / rest.xScale }
        faceShifts = zip(faces, faceScales).map { face, scale in
            CGPoint(
                x: face.anchor.dx - scale * rest.anchor.dx,
                y: scale * rest.anchor.dy - face.anchor.dy
            )
        }
    }

    /// The frames to show, `frames` holding one per pose in the order of `poses`.
    func frames(_ frames: [CGImage]) -> CAKeyframeAnimation {
        animation(
            "contents",
            values: keyframes.map { frames[$0.pose] }
        )
    }

    /// How much of the worker shows over the empty room.
    func envelope() -> CAKeyframeAnimation {
        animation(
            "opacity",
            values: keyframes.map(\.opacity)
        )
    }

    /// The brows' additive shift with the body, for the layer that holds them.
    func browShift() -> CAKeyframeAnimation {
        let shift = animation(
            "position",
            values: keyframes.map { NSValue(point: faceShifts[$0.pose]) }
        )
        shift.isAdditive = true
        return shift
    }

    /// The brows' additive change of scale with the body, for the layer that holds them.
    func browScale() -> CAKeyframeAnimation {
        let scale = animation(
            "transform.scale",
            values: keyframes.map { faceScales[$0.pose] - 1 }
        )
        scale.isAdditive = true
        return scale
    }

    /// An animation of `keyPath` through `values`, one per keyframe, played once; before it begins it
    /// holds its first value, as a passage starting after a delay must.
    private func animation(
        _ keyPath: String,
        values   : [Any]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values          = values
        animation.keyTimes        = keyframes.map { NSNumber(value: $0.time / duration) }
        animation.calculationMode = .linear
        animation.duration        = duration
        animation.fillMode        = .backwards
        return animation
    }
}
