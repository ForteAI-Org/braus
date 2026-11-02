//
//  MascotLayer+Companion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import QuartzCore

extension MascotLayer {

    /// Moves the brows from `from` to `to` and holds them there, over the loop and the gaze: a shift
    /// and turn added to whatever else moves them, eased over a moment, carrying each brow's contact
    /// shadow so it stays set in the metal.
    @MainActor
    func holdBrows(
        from: (left: BrowPose, right: BrowPose),
        to  : (left: BrowPose, right: BrowPose)
    ) {
        for (brow, start, end) in [(leftBrow, from.left, to.left), (rightBrow, from.right, to.right)] {
            for (key, keyPath, values) in tracks([start, end]) {
                let hold = CABasicAnimation(keyPath: keyPath)
                hold.fromValue             = values[0]
                hold.toValue               = values[1]
                hold.duration              = 0.25
                hold.timingFunction        = CAMediaTimingFunction(name: .easeInEaseOut)
                hold.isAdditive            = true
                hold.fillMode              = .forwards
                hold.isRemovedOnCompletion = false
                for layer in movingLayers(of: brow) {
                    layer.add(hold, forKey: Self.holdKey + key)
                }
            }
        }
    }

    /// Plays `keys` once on the brows and their contact shadows over `duration` seconds, added to
    /// everything else that moves them, ending where it started, at rest.
    @MainActor
    func playBrows(
        _ keys  : [CompanionReaction.Key],
        duration: Double
    ) {
        guard duration > 0 else { return }
        for (brow, isLeft) in [(leftBrow, true), (rightBrow, false)] {
            let poses = keys.map { isLeft ? $0.left : $0.right }
            for (key, keyPath, values) in tracks(poses) {
                let play = CAKeyframeAnimation(keyPath: keyPath)
                play.values     = values
                play.keyTimes   = keys.map { NSNumber(value: $0.time / duration) }
                play.duration   = duration
                play.isAdditive = true
                for layer in movingLayers(of: brow) {
                    layer.add(play, forKey: Self.reactionKey + key)
                }
            }
        }
    }

    /// The additive position and turn of a brow through `poses`, on a face of this layer's size.
    @MainActor
    private func tracks(_ poses: [BrowPose]) -> [(String, String, [Any])] {
        let side = faceSide
        return [
            ("position", "position", poses.map { pose in
                NSValue(point: CGPoint(
                    x: pose.dx * side,
                    y: pose.dy * side
                ))
            }),
            ("rotation", "transform.rotation.z", poses.map { $0.rotation }),
        ]
    }

    private static let holdKey     = "companion.hold."
    private static let reactionKey = "companion.reaction."
}
