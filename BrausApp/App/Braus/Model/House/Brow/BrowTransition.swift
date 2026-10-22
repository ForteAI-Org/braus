//
//  BrowTransition.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// BrowTransition is how the brows move from one state to another. A brow moves only when its
/// shape group changes; decisive states move both at once and faster, calm ones stagger the second.
nonisolated struct BrowTransition: Equatable, Sendable {
    let movesLeft : Bool
    let movesRight: Bool
    let duration  : Double
    let leftDelay : Double
    let rightDelay: Double

    /// The transition from `from` to `to`. `leftFirst` picks which brow leads a calm transition.
    static func between(
        _ from   : BrowState,
        _ to     : BrowState,
        leftFirst: Bool
    ) -> BrowTransition {
        let decisive = to == .working || to == .failed
        let stagger  = decisive ? 0 : HouseTiming.browStagger
        return BrowTransition(
            movesLeft : leftGroup(from) != leftGroup(to),
            movesRight: rightGroup(from) != rightGroup(to),
            duration  : decisive ? HouseTiming.browsDecisive : HouseTiming.browsCalm,
            leftDelay : leftFirst ? 0 : stagger,
            rightDelay: leftFirst ? stagger : 0
        )
    }

    /// States in one group share the left brow's shape. `look` has its own, so it moves both brows.
    private static func leftGroup(_ state: BrowState) -> Character {
        switch state {
        case .idle                          : "z"
        case .listening, .asking, .offline  : "a"
        case .working                       : "b"
        case .failed                        : "c"
        case .done                          : "d"
        case .look                          : "l"
        }
    }

    /// States in one group share the right brow's shape. `look` has its own, so it moves both brows.
    private static func rightGroup(_ state: BrowState) -> Character {
        switch state {
        case .idle              : "y"
        case .listening         : "p"
        case .working, .asking  : "q"
        case .offline, .failed  : "r"
        case .done              : "s"
        case .look              : "l"
        }
    }
}
