//
//  HumanControlMotion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import Foundation

/// HumanControlExit is how the overlay leaves: the worker jumps into a hole, or under Reduce Motion
/// the overlay fades.
nonisolated enum HumanControlExit: Equatable {
    case fall, fade

    init(reducesMotion: Bool) {
        self = reducesMotion ? .fade : .fall
    }

    /// How long the exit takes, from the first frame to the panel leaving the screen.
    var duration: Double {
        switch self {
        case .fall: 1.0
        case .fade: 0.25
        }
    }
}

/// HumanControlEntrance is how the overlay arrives: the worker pops up out of a hole, the exit played
/// backwards, or under Reduce Motion the overlay fades in.
nonisolated enum HumanControlEntrance: Equatable {
    case rise, fade

    init(reducesMotion: Bool) {
        self = reducesMotion ? .fade : .rise
    }

    var duration: Double {
        switch self {
        case .rise: 1.0
        case .fade: 0.25
        }
    }
}

/// TakeControlBeats is when each step of taking control from a worker's screen window starts, in
/// seconds after the click, one after the other: the curtain's words come in (`TakeControlCurtain`),
/// the worker on the window's corner dives away, the curtain fades off the picture, and then the
/// real windows take the screen window's place (`LendStill`). Lending waits for the swap, so the
/// move happens only then.
nonisolated enum TakeControlBeats {
    static let diveStart     = 1.2
    static let diveDuration  = HumanControlExit.fall.duration
    static let revealStart   = diveStart + diveDuration
    static let revealDuration = 0.4
    static let swap          = revealStart + revealDuration
}

/// HumanControlBeats is the keyframes of a jump through the hole, on shared beats: the worker's
/// width and height about its foot, its rise in figure heights, and its contact shadow's scale and
/// opacity. `exit` waits for the hole, crouches, rises, rounds at the top, falls in and holds while
/// the hole closes; `entrance` is the same played backwards.
nonisolated struct HumanControlBeats: Equatable {

    /// How the motion eases into the next beat.
    enum Curve: Equatable {
        case linear, easeIn, easeOut, easeInOut

        /// The same ease played backwards.
        var reversed: Curve {
            switch self {
            case .easeIn : .easeOut
            case .easeOut: .easeIn
            default      : self
            }
        }
    }

    let times        : [Double]
    let curves       : [Curve]
    let scaleX       : [Double]
    let scaleY       : [Double]
    let rise         : [Double]
    let shadowScale  : [Double]
    let shadowOpacity: [Double]

    static let exit = HumanControlBeats(
        times        : [0, 0.18, 0.32, 0.5, 0.6, 0.82, 1],
        curves       : [.linear, .easeInOut, .easeOut, .easeInOut, .easeIn, .linear],
        scaleX       : [1, 1, 1.18, 0.88, 1, 0.8, 0.8],
        scaleY       : [1, 1, 0.78, 1.14, 1, 1.22, 1.22],
        rise         : [0, 0, 0, 0.38, 0.42, -1.5, -1.5],
        shadowScale  : [1, 1, 1.12, 0.6, 0.55, 0.2, 0.2],
        shadowOpacity: [1, 1, 1, 0.45, 0.4, 0, 0]
    )

    static let entrance = exit.reversed

    /// The hole's opening over either jump: open, waiting, closed again.
    static let hole = (
        times : [0, 0.2, 0.8, 1.0],
        values: [0, 1, 1, 0.0]
    )

    /// The beats played backwards: the times mirrored, every track reversed, each ease reversed.
    var reversed: HumanControlBeats {
        HumanControlBeats(
            times        : times.reversed().map { 1 - $0 },
            curves       : curves.reversed().map(\.reversed),
            scaleX       : scaleX.reversed(),
            scaleY       : scaleY.reversed(),
            rise         : rise.reversed(),
            shadowScale  : shadowScale.reversed(),
            shadowOpacity: shadowOpacity.reversed()
        )
    }
}

/// BalloonSpring is the spring the speech balloon opens on, from `from` of its size to all of it: a
/// gentle one, damped enough that it barely passes its size before settling.
nonisolated struct BalloonSpring: Equatable {
    let stiffness: Double
    let damping  : Double
    let from     : Double

    static let opening = BalloonSpring(
        stiffness: 260,
        damping  : 26,
        from     : 0.6
    )

    /// The damping as a share of what stops it without passing its size at all.
    var dampingRatio: Double {
        damping / (2 * stiffness.squareRoot())
    }

    /// The largest scale it reaches: the size, plus the share of the way it travelled that an
    /// underdamped spring passes beyond it.
    var peak: Double {
        let ratio = dampingRatio
        guard ratio < 1 else { return 1 }
        return 1 + (1 - from) * exp(-Double.pi * ratio / (1 - ratio * ratio).squareRoot())
    }
}
