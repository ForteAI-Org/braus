//
//  WorkerAction.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// WorkerAction is what the worker at the top of its conversation does with its body through a turn,
/// in place of its idle loop, so the person sees the message being taken up: reading it, leaning
/// forward and down toward it; thinking, with a small slow sway; working, bobbing toward its screen
/// in a steady rhythm; and the reply arriving, with a small happy hop.
///
/// The companion on the person's screen answers their Yes and No with two more: agreeing, two nods and
/// a small hop, and declining, a shake of the head and a short chuckle. They play once, start and end at
/// rest, and take only poses the others already take, so a room bakes no new frame for them.
///
/// Each action is a loop of the body's poses (`BodyPose`) that repeats while the action lasts. Reading
/// and working hold their lean the whole loop round, so they never fall back to rest; thinking and
/// the reply start and end at rest.
nonisolated enum WorkerAction: CaseIterable, Sendable {
    case reading
    case thinking
    case working
    case replying
    case agreeing
    case declining

    /// How long one loop of the action lasts, in seconds.
    var duration: Double {
        switch self {
        case .reading : 1.4
        case .thinking: 3.2
        case .working : 2.0
        case .replying: 2.0
        case .agreeing : 0.8
        case .declining: 1.32
        }
    }

    /// The body's poses over one loop, from its start to its end at `duration`.
    var keys: [WorkerBehaviourLoop.BodyIntent.Key] {
        typealias Key = WorkerBehaviourLoop.BodyIntent.Key
        let steps: [(time: Double, pose: BodyPose)]
        switch self {
        case .reading:
            steps = [(0, Self.leaningIn), (0.7, Self.leaningCloser), (1.4, Self.leaningIn)]
        case .thinking:
            steps = [
                (0, .rest),
                (0.8, BodyPose(tilt: -0.06)),
                (1.6, .rest),
                (2.4, BodyPose(tilt: 0.06)),
                (3.2, .rest),
            ]
        case .working:
            steps = stride(from: 0.0, to: 2.0, by: 0.5).flatMap { time in
                [(time, Self.bobbedUp), (time + 0.25, Self.bobbedDown)]
            } + [(2.0, Self.bobbedUp)]
        case .replying:
            steps = [
                (0, .rest),
                (0.16, BodyPose(hop: 0.05)),
                (0.34, .rest),
                (0.42, BodyPose(stretch: -0.04)),
                (0.56, .rest),
                (2.0, .rest),
            ]
        case .agreeing:
            // In step with the companion's whole figure (`CompanionReaction.figure`).
            steps = [
                (0, .rest),
                (0.12, Self.leaningIn),
                (0.24, .rest),
                (0.36, Self.leaningIn),
                (0.46, .rest),
                (0.6, Self.hopped),
                (0.72, .rest),
                (0.8, .rest),
            ]
        case .declining:
            // Two quick shakes of the head, then three small bobs of a chuckle.
            steps = [
                (0, .rest),
                (0.12, Self.tiltedRight),
                (0.24, Self.tiltedLeft),
                (0.36, Self.tiltedRight),
                (0.48, Self.tiltedLeft),
                (0.6, .rest),
                (0.72, Self.squatted),
                (0.84, .rest),
                (0.96, Self.squatted),
                (1.08, .rest),
                (1.2, Self.squatted),
                (1.32, .rest),
            ]
        }
        return steps.map {
            Key(
                time: $0.time,
                pose: $0.pose
            )
        }
    }

    /// The loop as one intent of the body, from its start.
    var intent: WorkerBehaviourLoop.BodyIntent {
        WorkerBehaviourLoop.BodyIntent(
            time    : 0,
            duration: duration,
            keys    : keys
        )
    }

    /// The reply's hop and squat, and the thinking sway's tilts, which the companion's two reactions
    /// take as they are.
    private static let hopped      = BodyPose(hop: 0.05)
    private static let squatted    = BodyPose(stretch: -0.04)
    private static let tiltedRight = BodyPose(tilt: 0.06)
    private static let tiltedLeft  = BodyPose(tilt: -0.06)

    /// Leaning forward and down toward the message, a little closer half way.
    private static let leaningIn     = BodyPose(
        lean   : 0.09,
        slide  : 0.015,
        stretch: -0.02
    )
    private static let leaningCloser = BodyPose(
        lean   : 0.12,
        slide  : 0.02,
        stretch: -0.03
    )

    /// Bobbing toward the screen, up and down.
    private static let bobbedUp   = BodyPose(
        tilt: 0.04,
        lean: 0.05
    )
    private static let bobbedDown = BodyPose(
        tilt   : 0.04,
        lean   : 0.09,
        stretch: -0.035
    )
}
