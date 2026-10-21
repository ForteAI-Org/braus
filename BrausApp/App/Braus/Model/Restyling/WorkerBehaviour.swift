//
//  WorkerBehaviour.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// WorkerBehaviour is how a worker's brows behave in one status, so the worker never looks still:
/// busy is focused, with small looks toward its screen and an occasional slight frown; waiting
/// raises its brows and looks toward the person, with an occasional impatient gesture; free is
/// relaxed and slowly looks around, with an occasional flick; off sleeps, brows low, breathing slowly.
///
/// Each status has a vocabulary of actions with weights and a range of rests between them. A seed
/// turns it into a loop of 45 to 90 seconds that does not look repetitive: actions and their reach,
/// holds and rests vary, and no action plays more than `maxRepeats` times in a row.
nonisolated struct WorkerBehaviour: Sendable {

    /// Entry is an action of the vocabulary and how often it is chosen against the others.
    struct Entry: Sendable {
        let action: BrowAction
        let weight: Double
    }

    let status    : WorkerStatus
    let vocabulary: [Entry]

    /// How long the brows rest between two actions, in seconds.
    let rests     : ClosedRange<Double>

    /// How long one loop lasts before it repeats, in seconds.
    static let loopLength = 45.0...90.0

    /// The most times one action plays back to back.
    static let maxRepeats = 3

    init(_ status: WorkerStatus) {
        self.status = status
        let weighted: [(BrowAction, Double)]
        switch status {
        case .busy:
            weighted = [(.lookAtScreen, 5), (.lookLeft, 1.5), (.lookRight, 1.5), (.frown, 2), (.doubleGlance, 1.5), (.settle, 1)]
            rests    = 1.9...5.3
        case .waiting:
            weighted = [(.lookAtCamera, 4), (.raise, 3), (.impatient, 2), (.lookLeft, 1), (.lookRight, 1), (.leanIn, 1.5)]
            rests    = 1.5...4.5
        case .free:
            weighted = [(.lookLeft, 3), (.lookRight, 3), (.lookUp, 2), (.flick, 2), (.lookAround, 1.2), (.settle, 1)]
            rests    = 2.2...6.8
        case .off:
            weighted = [(.sleepBreath, 6), (.deepBreath, 3), (.settle, 1)]
            rests    = 0.3...1.2
        }
        vocabulary = weighted.map {
            Entry(
                action: $0.0,
                weight: $0.1
            )
        }
    }

    /// The loop `seed` gives in this status: the same seed always gives the same loop.
    func loop(seed: UInt64) -> WorkerBehaviourLoop {
        typealias Keyframe = WorkerBehaviourLoop.Keyframe
        let statusIndex = WorkerStatus.allCases.firstIndex(of: status) ?? 0
        var random = SplitMix(state: seed &+ UInt64(statusIndex) &* 0x9e37_79b9_7f4a_7c15)
        let length = Double.random(
            in   : Self.loopLength,
            using: &random
        )
        let start = Keyframe(
            time : 0,
            pose : .rest,
            curve: .move
        )
        var left      = [start]
        var right     = [start]
        var intents   : [WorkerBehaviourLoop.BodyIntent] = []
        var actions   : [BrowAction] = []
        var leftLeads = true
        var time = Double.random(
            in   : rests,
            using: &random
        )
        while true {
            let action      = pick(
                after : actions,
                random: &random
            )
            let performance = action.performance(
                base  : BrowState(status),
                random: &random
            )
            let stagger = performance.staggers ? RestylingTiming.browStagger : 0
            guard time + performance.duration + stagger + rests.lowerBound <= length else { break }

            for (side, offset) in [(0, leftLeads ? 0 : stagger), (1, leftLeads ? stagger : 0)] {
                var elapsed = time + offset
                var track   = [Keyframe(
                    time : elapsed,
                    pose : .rest,
                    curve: .move
                )]
                for move in performance.moves {
                    elapsed += move.duration
                    track.append(Keyframe(
                        time : elapsed,
                        pose : side == 0 ? move.left : move.right,
                        curve: move.curve
                    ))
                }
                if side == 0 { left += track } else { right += track }
            }
            if let kind = performance.intent {
                intents.append(WorkerBehaviourLoop.BodyIntent(
                    time    : time,
                    duration: performance.duration,
                    kind    : kind
                ))
            }
            actions.append(action)
            if performance.staggers { leftLeads.toggle() }
            time += performance.duration + stagger + Double.random(
                in   : rests,
                using: &random
            )
        }
        let end = Keyframe(
            time : length,
            pose : .rest,
            curve: .move
        )
        return WorkerBehaviourLoop(
            status  : status,
            seed    : seed,
            duration: length,
            left    : left + [end],
            right   : right + [end],
            intents : intents,
            actions : actions
        )
    }

    /// The seed of the worker `id`, the same on every launch.
    static func seed(for id: UUID) -> UInt64 {
        // FNV-1a, since Swift's own hashing changes from one launch to the next.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// An action by weight, leaving out the one that has just played `maxRepeats` times in a row.
    private func pick(
        after played: [BrowAction],
        random      : inout SplitMix
    ) -> BrowAction {
        let recent    = played.suffix(Self.maxRepeats)
        let exhausted = recent.count == Self.maxRepeats && Set(recent).count == 1 ? recent.first : nil
        let choices   = vocabulary.filter { $0.action != exhausted }
        var roll = Double.random(
            in   : 0..<choices.reduce(0) { $0 + $1.weight },
            using: &random
        )
        for choice in choices {
            roll -= choice.weight
            if roll < 0 { return choice.action }
        }
        return choices.last?.action ?? .settle
    }

    /// SplitMix64: small, fast, and the same sequence for the same seed.
    private struct SplitMix: RandomNumberGenerator {

        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            return value ^ (value >> 31)
        }
    }
}
