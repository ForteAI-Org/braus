//
//  CompanionBehaviour.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation

extension WorkerBehaviour {

    /// A behaviour of `weighted` actions in `status`, resting `rests` seconds between them.
    nonisolated init(
        status  : WorkerStatus,
        weighted: [(BrowAction, Double)],
        rests   : ClosedRange<Double>
    ) {
        self.status     = status
        self.rests      = rests
        self.vocabulary = weighted.map {
            Entry(
                action: $0.0,
                weight: $0.1
            )
        }
    }

    /// The companion watching the person work in the app Braus lent them: free and calm, it looks
    /// around, checks their work now and then, ponders, stretches with a look up, nods, and once in a
    /// while chuckles. It loops as every behaviour does, with the same lengths and repeats.
    nonisolated static let watching = WorkerBehaviour(
        status  : .free,
        weighted: [
            (.lookAround, 2),
            (.lookLeft, 1.5),
            (.lookRight, 1.5),
            (.lookUp, 1),
            (.checkWork, 2.5),
            (.ponder, 1.2),
            (.nod, 0.8),
            (.chuckle, 0.5),
        ],
        rests   : 2.0...5.0
    )

    /// Only pondering and chuckling, with short rests, so the debug check shows both at once.
    nonisolated static let showcase = WorkerBehaviour(
        status  : .free,
        weighted: [
            (.ponder, 1),
            (.chuckle, 1),
        ],
        rests   : 0.6...1.2
    )
}

/// CompanionReaction is how the companion answers the person's Yes or No: the brows' expression, a
/// motion of them, and of the whole figure, over the body's own reaction in its room
/// (`WorkerAction.agreeing` and `.declining`). Yes nods twice, crouches and hops for joy, its brows
/// arched, leading into the exit; No rocks its head side to side with its brows lowered, then laughs in
/// three bounces, its brows up, and hands the loop back. Under Reduce Motion only the expression changes.
nonisolated enum CompanionReaction: CaseIterable, Sendable {
    case yes, no

    /// The body's reaction, which the room bakes when the companion appears.
    var action: WorkerAction {
        self == .yes ? .agreeing : .declining
    }

    /// The expression the brows take.
    var brows: BrowState {
        self == .yes ? .done : .idle
    }

    var duration: Double {
        action.duration
    }

    /// Key is both brows' pose `time` seconds into the reaction.
    struct Key: Equatable, Sendable {
        let time : Double
        let left : BrowPose
        let right: BrowPose
    }

    /// FigureKey is the whole figure's pose `time` seconds into the reaction, eased into on `curve`.
    struct FigureKey: Equatable, Sendable {
        let time : Double
        let pose : FigurePose
        let curve: HumanControlBeats.Curve
    }

    /// The brows' motion over the reaction, from rest back to rest, in step with the body: for Yes a
    /// dip with each nod, a lift between them and, at the top of the hop, both raised with their outer
    /// ends up; for No lowered through the shake, then up with their inner ends raised on each laugh.
    var keys: [Key] {
        let steps: [(Double, BrowPose, BrowPose)]
        switch self {
        case .yes:
            steps = [
                (0, .rest, .rest),
                (0.12, Self.dip, Self.dip),
                (0.24, Self.lift, Self.lift),
                (0.36, Self.dip, Self.dip),
                (0.46, Self.crouch, Self.crouch),
                (0.6, Self.joy.left, Self.joy.right),
                (0.72, Self.landing, Self.landing),
                (0.8, .rest, .rest),
            ]
        case .no:
            steps = [
                (0, .rest, .rest),
                (0.1, Self.lowered, Self.lowered),
                (0.56, Self.lowered, Self.lowered),
                (0.72, Self.laugh.left, Self.laugh.right),
                (0.84, Self.settled, Self.settled),
                (0.96, Self.laugh.left, Self.laugh.right),
                (1.08, Self.settled, Self.settled),
                (1.2, Self.laugh.left, Self.laugh.right),
                (1.32, .rest, .rest),
            ]
        }
        return steps.map {
            Key(
                time : $0.0,
                left : $0.1,
                right: $0.2
            )
        }
    }

    /// The whole figure's motion over the reaction, in step with the body and the brows, from rest
    /// back to rest: for Yes two nods squashing it, a crouch, a stretched hop and a squashed landing;
    /// for No two rocks of its head each way about its foot, then three squashed laughs.
    var figure: [FigureKey] {
        let steps: [(Double, FigurePose, HumanControlBeats.Curve)]
        switch self {
        case .yes:
            steps = [
                (0, .rest, .linear),
                (0.12, FigurePose.nod, .easeOut),
                (0.24, FigurePose.lifted, .easeInOut),
                (0.36, FigurePose.nod, .easeInOut),
                (0.46, FigurePose.crouched, .easeInOut),
                (0.6, FigurePose.hopped, .easeOut),
                (0.72, FigurePose.landed, .easeIn),
                (0.8, .rest, .easeOut),
            ]
        case .no:
            steps = [
                (0, .rest, .linear),
                (0.12, FigurePose.rocked(-1), .easeOut),
                (0.24, FigurePose.rocked(1), .easeInOut),
                (0.36, FigurePose.rocked(-0.8), .easeInOut),
                (0.48, FigurePose.rocked(0.6), .easeInOut),
                (0.6, .rest, .easeInOut),
                (0.72, FigurePose.laughing, .easeOut),
                (0.84, FigurePose.bounced, .easeInOut),
                (0.96, FigurePose.laughing, .easeInOut),
                (1.08, FigurePose.bounced, .easeInOut),
                (1.2, FigurePose.laughing, .easeInOut),
                (1.32, .rest, .easeOut),
            ]
        }
        return steps.map {
            FigureKey(
                time : $0.0,
                pose : $0.1,
                curve: $0.2
            )
        }
    }

    /// Where the brows hold while the pointer is over Yes, both lifted in expectation with their outer
    /// ends up, or over No, one raised and turned as if asking for a bit longer, the other lowered.
    static func hover(yes: Bool) -> (left: BrowPose, right: BrowPose) {
        yes ? eager : doubtful
    }

    /// How the whole figure holds while the pointer is over Yes, leaning toward it and drawn up
    /// eagerly, or over No, its head tilted away and a little sunk, puzzled.
    static func lean(yes: Bool) -> FigurePose {
        yes ? .eager : .puzzled
    }

    /// The brows' poses: a dip with a nod or a crouch, a lift, and a landing; lowered through the
    /// shake and a little up between the laughs.
    private static let dip     = BrowPose(dy: -0.02)
    private static let lift    = BrowPose(dy: 0.03)
    private static let crouch  = BrowPose(dy: -0.01)
    private static let landing = BrowPose(dy: -0.008)
    private static let lowered = BrowPose(dy: -0.018)
    private static let settled = BrowPose(dy: 0.006)

    /// Both brows up at the top of the hop with their outer ends raised, and up on a laugh with their
    /// inner ends raised; a positive turn lifts a brow's right end.
    private static let joy   = (
        left : BrowPose(
            dy      : 0.045,
            rotation: -0.07
        ),
        right: BrowPose(
            dy      : 0.045,
            rotation: 0.07
        )
    )
    private static let laugh = (
        left : BrowPose(
            dy      : 0.035,
            rotation: 0.08
        ),
        right: BrowPose(
            dy      : 0.035,
            rotation: -0.08
        )
    )

    /// The brows held over Yes and over No.
    private static let eager    = (
        left : BrowPose(
            dy      : 0.035,
            rotation: -0.06
        ),
        right: BrowPose(
            dy      : 0.035,
            rotation: 0.06
        )
    )
    private static let doubtful = (
        left : BrowPose(
            dy      : 0.045,
            rotation: 0.11
        ),
        right: BrowPose(dy: -0.015)
    )
}

/// FigurePose is where the companion's whole figure stands against rest on the person's screen, over
/// what its room shows: turned about its foot (`turn`, radians, counterclockwise), wider or taller about
/// it (`width` and `height`, shares added to its size), and moved across and up (`dx` and `dy`, shares
/// of its height). The brows and the shadow behind it move with it, so nothing comes apart.
nonisolated struct FigurePose: Equatable, Sendable {
    var turn  : Double = 0
    var width : Double = 0
    var height: Double = 0
    var dx    : Double = 0
    var dy    : Double = 0

    static let rest = FigurePose()

    /// Yes: squashed by a nod, drawn up between the nods, crouched, stretched at the top of the hop,
    /// and squashed as it lands.
    static let nod      = FigurePose(
        width : 0.06,
        height: -0.08
    )
    static let lifted   = FigurePose(
        width : -0.02,
        height: 0.03
    )
    static let crouched = FigurePose(
        width : 0.1,
        height: -0.13
    )
    static let hopped   = FigurePose(
        width : -0.07,
        height: 0.12,
        dy    : 0.17
    )
    static let landed   = FigurePose(
        width : 0.08,
        height: -0.1
    )

    /// No: squashed by a laugh, and bounced up a little between two.
    static let laughing = FigurePose(
        width : 0.05,
        height: -0.07
    )
    static let bounced  = FigurePose(
        width : -0.02,
        height: 0.03,
        dy    : 0.03
    )

    /// No: the head rocked `share` of the way toward the left, or the right when negative, the whole
    /// figure shifting a little the same way.
    static func rocked(_ share: Double) -> FigurePose {
        FigurePose(
            turn: 0.1 * share,
            dx  : -0.02 * share
        )
    }

    /// Held over Yes, leaning toward it and drawn up; held over No, tilted away and a little sunk.
    static let eager   = FigurePose(
        turn  : 0.07,
        width : -0.03,
        height: 0.05,
        dx    : -0.03
    )
    static let puzzled = FigurePose(
        turn  : -0.09,
        width : 0.02,
        height: -0.03,
        dx    : 0.02
    )

    /// The most the figure turns either way, in radians, changes its size, as a share, and moves, as
    /// a share of its height: lively, and still standing on its ground.
    static let maxTurn  = 0.12
    static let maxScale = 0.15
    static let maxMove  = 0.2

    /// Whether the pose stays within the limits, never below the ground.
    var isAllowed: Bool {
        abs(turn) <= Self.maxTurn && abs(width) <= Self.maxScale && abs(height) <= Self.maxScale
            && abs(dx) <= Self.maxMove && (0...Self.maxMove).contains(dy)
    }
}

/// ThoughtBubble is the companion thinking while it ponders: three small circles rising one after
/// another toward a small cloud that puffs in, three dots pulsing in turn inside it, then all of it
/// fading. It follows the loop's own data, as keyframes over the loop that repeat with it, so no
/// timer runs; the stage hides it while a question is open.
nonisolated enum ThoughtBubble {

    /// Whether the bubble shows: never over an open question, nor while the worker looks at something
    /// or leaves.
    static func shows(
        isAsking : Bool,
        isGazing : Bool,
        isLeaving: Bool
    ) -> Bool {
        !isAsking && !isGazing && !isLeaving
    }

    /// The dots' pulse: each brightens from `dim` to full over `rise` seconds and back, `lead`
    /// seconds after the one before, once every `period`.
    static let pulse = (
        lead  : 0.3,
        rise  : 0.15,
        period: 0.9,
        dim   : 0.45
    )

    /// When the loop ponders: the spans of its ponder actions.
    static func windows(in loop: WorkerBehaviourLoop) -> [WorkerBehaviourLoop.Span] {
        zip(loop.actions, loop.spans).compactMap { $0 == .ponder ? $1 : nil }
    }

    /// Part is one layer of the bubble: one of the three rising circles, the cloud, or one of its dots.
    enum Part: Equatable, Sendable {
        case circle(Int)
        case cloud
        case dot(Int)
    }

    /// Key is a part's opacity and rise in points `time` seconds into the loop.
    struct Key: Equatable, Sendable {
        let time   : Double
        let opacity: Double
        let rise   : Double
    }

    /// The keys of `part` over a loop of `duration` seconds pondering in `windows`: hidden outside
    /// them; inside, the circles rise in one after another, the cloud puffs in, the dots pulse in turn,
    /// and all fades before the window ends. Without `rises` (Reduce Motion) nothing rises or pulses.
    static func keys(
        of part : Part,
        windows : [WorkerBehaviourLoop.Span],
        duration: Double,
        rises   : Bool
    ) -> [Key] {
        // Each step is a time, an opacity and a rise.
        var steps: [(Double, Double, Double)] = [(0, 0, 0)]
        for window in windows {
            let start = window.start
            let end   = window.start + window.duration
            let shown: Double
            switch part {
            case let .circle(index): shown = start + 0.25 + 0.2 * Double(index)
            case .cloud            : shown = start + 0.85
            case .dot              : shown = start + 1.05
            }
            let fade = end - 0.35
            guard fade > shown + 0.2 else { continue }
            let low   = rises ? -3.0 : 0
            steps += [(shown, 0, low), (shown + 0.2, 1, 0)]
            if case let .dot(index) = part, rises {
                // Each dot brightens in its turn, a beat after the one before, until the fade.
                var beat = shown + pulse.lead + pulse.lead * Double(index)
                while beat + 2 * pulse.rise < fade {
                    steps += [(beat, pulse.dim, 0), (beat + pulse.rise, 1, 0), (beat + 2 * pulse.rise, pulse.dim, 0)]
                    beat += pulse.period
                }
            }
            steps += [(fade, 1, 0), (fade + 0.3, 0, 0)]
        }
        steps.append((duration, 0, 0))
        return steps.map {
            Key(
                time   : $0.0,
                opacity: $0.1,
                rise   : $0.2
            )
        }
    }
}
