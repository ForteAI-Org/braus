//
//  WorkerBehaviourLoop.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore

/// WorkerBehaviourLoop is one worker's long, seamless loop of brow motion in one status: a track of
/// keyframes per brow, both starting and ending at rest, and the body's intents along the way.
///
/// Core Animation plays it as keyframe animations that repeat forever, so a worker stays alive with
/// no timer and no work at rest. The body's intents are poses a room bakes (`RoomBodyMotion`).
nonisolated struct WorkerBehaviourLoop: Equatable, Sendable {

    /// Keyframe is a brow's pose at `time` seconds into the loop, reached along `curve`.
    struct Keyframe: Equatable, Sendable {
        let time : Double
        let pose : BrowPose
        let curve: BrowAction.Curve
    }

    /// BodyIntent is what the body does with an action, `time` seconds into the loop: its poses over
    /// the action's `duration`, from rest back to rest, in step with the brows.
    struct BodyIntent: Equatable, Sendable {

        /// Key is the body's pose `time` seconds into the action.
        struct Key: Equatable, Sendable {
            let time: Double
            let pose: BodyPose
        }

        let time    : Double
        let duration: Double
        let keys    : [Key]
    }

    /// Side names one of the two brows, as the person sees them.
    enum Side: CaseIterable, Sendable {
        case left, right
    }

    let status   : WorkerStatus
    let seed     : UInt64
    let duration : Double
    let left     : [Keyframe]
    let right    : [Keyframe]
    let intents  : [BodyIntent]

    /// The actions in the order they play, for checking how the loop varies.
    let actions  : [BrowAction]

    /// The outline the brows hold at rest in this status.
    var base: BrowState {
        BrowState(status)
    }

    /// The loop as keyframe animations for one brow, keyed by the key each takes on the layer:
    /// an additive shift of the position in points for a face `face` points wide, an additive turn,
    /// and the outline's path when the loop changes it. In a tilted room `stretch` is how much wider
    /// and taller the camera shows the face (`RoomCamera.Face`), so the shifts follow the body. Empty
    /// under Reduce Motion, where the brows hold the status's outline still.
    @MainActor
    func animations(
        for side: Side,
        face    : CGFloat,
        stretch : CGSize = CGSize(
            width : 1,
            height: 1
        )
    ) -> [String: CAKeyframeAnimation] {
        guard !HouseMotion.reducesMotion else { return [:] }
        let track    = side == .left ? left : right
        let outlines = side == .left ? BrowOutlines.bundled.left : BrowOutlines.bundled.right
        var result = [
            Self.positionKey: animation(
                "position",
                track : track,
                values: track.map {
                    NSValue(point: CGPoint(
                        x: $0.pose.dx * face * stretch.width,
                        y: $0.pose.dy * face * stretch.height
                    ))
                }
            ),
            Self.rotationKey: animation(
                "transform.rotation.z",
                track : track,
                values: track.map { $0.pose.rotation }
            ),
        ]
        result[Self.positionKey]?.isAdditive = true
        result[Self.rotationKey]?.isAdditive = true
        if track.contains(where: { $0.pose.outline != nil }) {
            let paths = track.compactMap { keyframe in
                outlines[keyframe.pose.outline ?? base].map(MascotLayer.path)
            }
            if paths.count == track.count {
                result[Self.pathKey] = animation(
                    "path",
                    track : track,
                    values: paths
                )
            }
        }
        return result
    }

    static let positionKey = "behaviour.position"
    static let rotationKey = "behaviour.rotation"
    static let pathKey     = "behaviour.path"

    private func animation(
        _ keyPath: String,
        track    : [Keyframe],
        values   : [Any]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values          = values
        animation.keyTimes        = track.map { NSNumber(value: $0.time / duration) }
        animation.timingFunctions = track.dropFirst().map { Self.timing($0.curve) }
        animation.calculationMode = .linear
        animation.duration        = duration
        animation.repeatCount     = .infinity
        return animation
    }

    private static func timing(_ curve: BrowAction.Curve) -> CAMediaTimingFunction {
        switch curve {
        case .move  : CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        case .breath: CAMediaTimingFunction(controlPoints: 0.45, 0, 0.4, 1)
        case .snap  : CAMediaTimingFunction(controlPoints: 0.2, 0, 0.2, 1)
        }
    }
}
