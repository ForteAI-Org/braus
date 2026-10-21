//
//  BrowAction.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// BrowAction is one small thing a worker's brows do between rests: a look, a raise, a frown, a
/// flick, a sleeping breath or a deeper one. Each performance varies a little in reach and hold.
///
/// A performance starts and ends at rest, so actions chain in any order. Moves that change an
/// outline take at least the calm morph's time; a frown is decisive and moves both brows at once.
nonisolated enum BrowAction: CaseIterable, Sendable {
    case lookLeft
    case lookRight
    case lookUp
    case lookAtScreen
    case lookAtCamera
    case raise
    case leanIn
    case doubleGlance
    case lookAround
    case frown
    case flick
    case impatient
    case settle
    case sleepBreath
    case deepBreath

    /// Curve is how a move eases into its pose.
    enum Curve: Equatable, Sendable {
        /// The brows' morph curve, slow at both ends.
        case move

        /// The head's breathing curve, softer still.
        case breath

        /// Fast out, as a twitch.
        case snap
    }

    /// Move takes both brows to a pose over `duration` seconds.
    struct Move: Equatable, Sendable {
        let duration: Double
        let left    : BrowPose
        let right   : BrowPose
        let curve   : Curve
    }

    /// Performance is one playing of an action: its moves, whether the second brow follows the first
    /// by the calm stagger, and what the body might do with it.
    struct Performance: Sendable {
        let moves   : [Move]
        let staggers: Bool
        let intent  : WorkerBehaviourLoop.BodyIntent.Kind?

        /// How long the performance lasts, without the stagger.
        var duration: Double {
            moves.reduce(0) { $0 + $1.duration }
        }
    }

    /// One performance for brows whose state shows `base`, varied by `random`.
    func performance(
        base  : BrowState,
        random: inout some RandomNumberGenerator
    ) -> Performance {
        let reach = Double.random(
            in   : 0.8...1.2,
            using: &random
        )
        switch self {
        case .lookLeft, .lookRight:
            let side = self == .lookLeft ? -1.0 : 1.0
            // An idle brow looking right takes the look outline, as the pointer makes it do.
            let outline: BrowState? = side > 0 && base == .idle ? .look : nil
            let pose = BrowPose(
                dx     : side * 0.039 * reach,
                outline: outline
            )
            return Self.glance(
                at    : pose,
                hold  : 0.8...2.0,
                intent: .tilt(side * 0.04),
                random: &random
            )
        case .lookUp:
            return Self.glance(
                at    : BrowPose(dy: 0.032 * reach),
                hold  : 0.6...1.5,
                intent: nil,
                random: &random
            )
        case .lookAtScreen:
            let side = Bool.random(using: &random) ? -1.0 : 1.0
            return Self.glance(
                at    : BrowPose(
                    dx: side * 0.016 * reach,
                    dy: -0.029 * reach
                ),
                hold  : 1.5...4.0,
                intent: .tilt(side * 0.02),
                random: &random
            )
        case .lookAtCamera:
            return Self.glance(
                at    : BrowPose(
                    dy      : 0.016 * reach,
                    rotation: 0.052 * reach
                ),
                hold  : 1.5...3.5,
                intent: nil,
                random: &random
            )
        case .raise:
            return Self.glance(
                at    : BrowPose(
                    dy      : 0.052 * reach,
                    rotation: 0.078 * reach
                ),
                hold  : 0.6...1.4,
                intent: nil,
                random: &random
            )
        case .leanIn:
            // A slower, smaller raise than `raise`, held longer, as if leaning toward the person.
            return Self.glance(
                at    : BrowPose(
                    dy      : 0.03 * reach,
                    rotation: 0.05 * reach
                ),
                hold  : 1.2...2.4,
                intent: nil,
                random: &random
            )
        case .doubleGlance:
            let side = Bool.random(using: &random) ? -1.0 : 1.0
            let first  = BrowPose(
                dx: side * 0.03 * reach,
                dy: -0.012 * reach
            )
            let second = BrowPose(
                dx: -side * 0.026 * reach,
                dy: -0.012 * reach
            )
            return Performance(
                moves   : Self.mirrored([
                    (first, 0.2, .snap),
                    (first, Self.hold(0.25...0.45, &random), .move),
                    (second, 0.2, .snap),
                    (second, Self.hold(0.3...0.6, &random), .move),
                    (.rest, 0.4, .move),
                ]),
                staggers: false,
                intent  : .tilt(side * 0.02)
            )
        case .lookAround:
            let side   = Bool.random(using: &random) ? -1.0 : 1.0
            // As in lookRight, an idle brow looking right takes the look outline.
            let first  = BrowPose(
                dx     : side * 0.036 * reach,
                outline: base == .idle && side > 0 ? .look : nil
            )
            let second = BrowPose(
                dx     : -side * 0.036 * reach,
                outline: base == .idle && side < 0 ? .look : nil
            )
            return Performance(
                moves   : Self.mirrored([
                    (first, 0.7, .move),
                    (first, Self.hold(1.0...1.6, &random), .move),
                    (second, 0.9, .move),
                    (second, Self.hold(1.0...1.6, &random), .move),
                    (.rest, 0.7, .move),
                ]),
                staggers: true,
                intent  : .tilt(side * 0.03)
            )
        case .frown:
            let pose = BrowPose(
                dy      : -0.02 * reach,
                rotation: -0.13 * reach
            )
            return Performance(
                moves   : Self.mirrored([
                    (pose, RestylingTiming.browsDecisive, .move),
                    (pose, Self.hold(0.8...2.0, &random), .move),
                    (.rest, 0.4, .move),
                ]),
                staggers: false,
                intent  : nil
            )
        case .flick:
            let lifted = BrowPose(
                dy      : 0.058 * reach,
                rotation: 0.065
            )
            let isLeft = Bool.random(using: &random)
            let left   = isLeft ? lifted : .rest
            let right  = isLeft ? .rest : Self.mirror(lifted)
            let steps: [(left: BrowPose, right: BrowPose, duration: Double, curve: Curve)] = [
                (left, right, 0.12, .snap),
                (left, right, 0.08, .move),
                (.rest, .rest, 0.3, .move),
            ]
            return Performance(
                moves   : steps.map {
                    Move(
                        duration: $0.duration,
                        left    : $0.left,
                        right   : $0.right,
                        curve   : $0.curve
                    )
                },
                staggers: false,
                intent  : nil
            )
        case .impatient:
            let up = BrowPose(dy: 0.039 * reach)
            return Performance(
                moves   : Self.mirrored([
                    (up, 0.15, .snap),
                    (.rest, 0.18, .move),
                    (up, 0.15, .snap),
                    (.rest, 0.25, .move),
                ]),
                staggers: false,
                intent  : .hop(0.04)
            )
        case .settle:
            let low = BrowPose(
                dy      : -0.013 * reach,
                rotation: -0.026
            )
            return Performance(
                moves   : Self.mirrored([
                    (low, 0.5, .move),
                    (.rest, 0.7, .move),
                ]),
                staggers: true,
                intent  : nil
            )
        case .sleepBreath, .deepBreath:
            let isDeep = self == .deepBreath
            let low    = BrowPose(dy: (isDeep ? -0.0242 : -0.0154) * reach)
            return Performance(
                moves   : Self.mirrored([
                    (low, Self.hold(isDeep ? 3.2...3.8 : 2.2...2.8, &random), .breath),
                    (.rest, Self.hold(isDeep ? 3.6...4.4 : 2.4...3.2, &random), .breath),
                ]),
                staggers: false,
                intent  : nil
            )
        }
    }

    /// Goes to `pose`, holds it for a while in `hold`, and comes back, the second brow staggered.
    private static func glance(
        at pose: BrowPose,
        hold   : ClosedRange<Double>,
        intent : WorkerBehaviourLoop.BodyIntent.Kind?,
        random : inout some RandomNumberGenerator
    ) -> Performance {
        Performance(
            moves   : mirrored([
                (pose, max(0.45, RestylingTiming.browsCalm), .move),
                (pose, Self.hold(hold, &random), .move),
                (.rest, 0.5, .move),
            ]),
            staggers: true,
            intent  : intent
        )
    }

    /// Both brows through `steps`, each a pose, how long it takes to reach it and how. The right
    /// brow is mirrored: a turn lifting the left brow's inner end lifts the right one's too.
    private static func mirrored(_ steps: [(pose: BrowPose, duration: Double, curve: Curve)]) -> [Move] {
        steps.map {
            Move(
                duration: $0.duration,
                left    : $0.pose,
                right   : mirror($0.pose),
                curve   : $0.curve
            )
        }
    }

    private static func mirror(_ pose: BrowPose) -> BrowPose {
        BrowPose(
            dx      : pose.dx,
            dy      : pose.dy,
            rotation: -pose.rotation,
            outline : pose.outline
        )
    }

    private static func hold(
        _ range : ClosedRange<Double>,
        _ random: inout some RandomNumberGenerator
    ) -> Double {
        Double.random(
            in   : range,
            using: &random
        )
    }
}
