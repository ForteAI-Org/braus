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
///
/// The body goes with the brows (`Performance.body`): it turns where they look, leans toward the
/// screen or the person, stretches, squats, shuffles aside, bobs and hops, in fixed poses so a room
/// bakes few of them; a large gesture passes through half of itself on a slow move.
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
    case shuffle
    case shiftWeight
    case work
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
    /// by the calm stagger, and the body's poses with it, from rest back to rest, or none.
    struct Performance: Sendable {
        let moves   : [Move]
        let staggers: Bool
        let body    : [WorkerBehaviourLoop.BodyIntent.Key]

        /// The moves, and the body taking `poses`, one at the end of each move; none without them.
        init(
            moves   : [Move],
            staggers: Bool,
            poses   : [BodyPose]? = nil
        ) {
            self.moves    = moves
            self.staggers = staggers
            body          = poses.map {
                BrowAction.body(
                    moves,
                    poses: $0
                )
            } ?? []
        }

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
                body  : Self.turned(side),
                random: &random
            )
        case .lookUp:
            return Self.glance(
                at    : BrowPose(dy: 0.032 * reach),
                hold  : 0.6...1.5,
                body  : Self.stretched,
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
                body  : Self.towardScreen(side),
                random: &random
            )
        case .lookAtCamera:
            return Self.glance(
                at    : BrowPose(
                    dy      : 0.016 * reach,
                    rotation: 0.052 * reach
                ),
                hold  : 1.5...3.5,
                body  : Self.leaning,
                random: &random
            )
        case .raise:
            return Self.glance(
                at    : BrowPose(
                    dy      : 0.052 * reach,
                    rotation: 0.078 * reach
                ),
                hold  : 0.6...1.4,
                body  : Self.raised,
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
                body  : Self.leaning,
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
                poses   : [Self.towardScreen(side), Self.towardScreen(side), Self.towardScreen(-side), Self.towardScreen(-side), .rest]
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
                poses   : [Self.turned(side), Self.turned(side), Self.turned(-side), Self.turned(-side), .rest]
            )
        case .frown:
            let pose = BrowPose(
                dy      : -0.02 * reach,
                rotation: -0.13 * reach
            )
            return Performance(
                moves   : Self.mirrored([
                    (pose, HouseTiming.browsDecisive, .move),
                    (pose, Self.hold(0.8...2.0, &random), .move),
                    (.rest, 0.4, .move),
                ]),
                staggers: false,
                poses   : [Self.bobbedDown, Self.bobbedDown, .rest]
            )
        case .flick:
            let lifted = BrowPose(
                dy      : 0.058 * reach,
                rotation: 0.065
            )
            let isLeft = Bool.random(using: &random)
            let left   = isLeft ? lifted : .rest
            let right  = isLeft ? .rest : Self.mirror(lifted)
            // A bounce: up with the brows, down, and a squat as it lands.
            let steps: [(left: BrowPose, right: BrowPose, duration: Double, curve: Curve, body: BodyPose)] = [
                (left, right, 0.14, .snap, Self.bounced),
                (left, right, 0.06, .move, Self.bounced),
                (.rest, .rest, 0.16, .move, .rest),
                (.rest, .rest, 0.08, .move, Self.squatted),
                (.rest, .rest, 0.16, .move, .rest),
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
                poses   : steps.map(\.body)
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
                poses   : [Self.hopped, .rest, Self.hopped, .rest]
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
                poses   : [Self.squatted, .rest]
            )
        case .shuffle:
            let side = Bool.random(using: &random) ? -1.0 : 1.0
            return Self.glance(
                at    : BrowPose(dx: side * 0.03 * reach),
                hold  : 0.6...1.2,
                body  : BodyPose(
                    tilt : -side * 0.03,
                    shift: side * 0.035
                ),
                random: &random
            )
        case .shiftWeight:
            let side = Bool.random(using: &random) ? -1.0 : 1.0
            let pose = BrowPose(dx: side * 0.02 * reach)
            return Performance(
                moves   : Self.mirrored([
                    (pose, 0.7, .move),
                    (pose, Self.hold(1.0...2.0, &random), .move),
                    (.rest, 0.7, .move),
                ]),
                staggers: true,
                poses   : [BodyPose(tilt: side * 0.05, shift: side * 0.02), BodyPose(tilt: side * 0.05, shift: side * 0.02), .rest]
            )
        case .work:
            // Focused on the screen, bobbing toward it in a steady rhythm, the brows dipping with it.
            let focus = BrowPose(dy: -0.02 * reach)
            let dip   = BrowPose(dy: -0.03 * reach)
            let bobs  = Int.random(
                in   : 3...6,
                using: &random
            )
            var steps: [(pose: BrowPose, duration: Double, curve: Curve)] = [(focus, 0.3, .move)]
            var poses = [Self.bobbedUp]
            for _ in 0..<bobs {
                steps += [(dip, 0.21, .move), (focus, 0.21, .move)]
                poses += [Self.bobbedDown, Self.bobbedUp]
            }
            steps.append((.rest, 0.4, .move))
            poses.append(.rest)
            return Performance(
                moves   : Self.mirrored(steps),
                staggers: false,
                poses   : poses
            )
        case .sleepBreath, .deepBreath:
            let isDeep = self == .deepBreath
            let low    = BrowPose(dy: (isDeep ? -0.0242 : -0.0154) * reach)
            return Performance(
                moves   : Self.mirrored([
                    (low, Self.hold(isDeep ? 3.2...3.8 : 2.2...2.8, &random), .breath),
                    (.rest, Self.hold(isDeep ? 3.6...4.4 : 2.4...3.2, &random), .breath),
                ]),
                staggers: false
            )
        }
    }

    /// Goes to `pose`, holds it for a while in `hold`, and comes back, the second brow staggered, the
    /// body going to `body` and back with them.
    private static func glance(
        at pose: BrowPose,
        hold   : ClosedRange<Double>,
        body   : BodyPose,
        random : inout some RandomNumberGenerator
    ) -> Performance {
        Performance(
            moves   : mirrored([
                (pose, max(0.45, HouseTiming.browsCalm), .move),
                (pose, Self.hold(hold, &random), .move),
                (.rest, 0.5, .move),
            ]),
            staggers: true,
            poses   : [body, body, .rest]
        )
    }

    /// The body's poses: turned toward a side the brows look at; turned toward its screen and leaning
    /// over it, a little squat; leaning toward the person; stretched tall and leaning back a little;
    /// a little taller; off the floor, as a bounce or an impatient hop; squatting; and bobbing toward
    /// the screen, up and down.
    private static func turned(_ side: Double) -> BodyPose {
        BodyPose(tilt: side * 0.1)
    }

    private static func towardScreen(_ side: Double) -> BodyPose {
        BodyPose(
            tilt   : side * 0.06,
            lean   : 0.06,
            stretch: -0.02
        )
    }

    private static let leaning   = BodyPose(
        lean : 0.08,
        slide: 0.02
    )
    private static let stretched = BodyPose(
        lean   : -0.03,
        stretch: 0.06
    )
    private static let raised    = BodyPose(stretch: 0.04)
    private static let bounced   = BodyPose(hop: 0.035)
    private static let hopped    = BodyPose(hop: 0.045)
    private static let squatted  = BodyPose(stretch: -0.04)
    private static let bobbedUp  = BodyPose(lean: 0.04)
    private static let bobbedDown = BodyPose(
        lean   : 0.07,
        stretch: -0.03
    )

    /// The body's keys over `moves`: rest at the start, then the pose `poses` gives at the end of each
    /// move, and on a slow move of a large gesture also the pose half way, so it travels through it.
    static func body(
        _ moves: [Move],
        poses  : [BodyPose]
    ) -> [WorkerBehaviourLoop.BodyIntent.Key] {
        typealias Key = WorkerBehaviourLoop.BodyIntent.Key
        var keys = [Key(
            time: 0,
            pose: .rest
        )]
        var time = 0.0
        var last = BodyPose.rest
        for (move, pose) in zip(moves, poses) {
            let isLarge = abs(pose.tilt - last.tilt) >= 0.08 || abs(pose.lean - last.lean) >= 0.07
                || abs(pose.stretch - last.stretch) >= 0.05
            if move.duration >= 0.35, isLarge {
                keys.append(Key(
                    time: time + move.duration / 2,
                    pose: BodyPose(
                        tilt   : (last.tilt + pose.tilt) / 2,
                        lean   : (last.lean + pose.lean) / 2,
                        hop    : (last.hop + pose.hop) / 2,
                        shift  : (last.shift + pose.shift) / 2,
                        slide  : (last.slide + pose.slide) / 2,
                        stretch: (last.stretch + pose.stretch) / 2
                    )
                ))
            }
            time += move.duration
            keys.append(Key(
                time: time,
                pose: pose
            ))
            last = pose
        }
        return keys
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
