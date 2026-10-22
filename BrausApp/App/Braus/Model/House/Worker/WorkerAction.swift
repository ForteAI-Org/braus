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
/// Each action is a loop of the body's poses (`BodyPose`) that repeats while the action lasts. Reading
/// and working hold their lean the whole loop round, so they never fall back to rest; thinking and
/// the reply start and end at rest.
nonisolated enum WorkerAction: CaseIterable, Sendable {
    case reading
    case thinking
    case working
    case replying

    /// How long one loop of the action lasts, in seconds.
    var duration: Double {
        switch self {
        case .reading : 1.4
        case .thinking: 3.2
        case .working : 2.0
        case .replying: 2.0
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
