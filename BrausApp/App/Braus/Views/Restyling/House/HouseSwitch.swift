//
//  HouseSwitch.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseSwitch is how the conversation column changes worker. The shown worker steps down and fades
/// over `exit` while the transcripts cross-fade over `crossFade`; after `entryDelay` the next worker
/// rises in from a little below on a soft spring, and its capsule follows a `capsuleBeat` later. The
/// composer and the toolbar stay where they are: the leaving composer hides at once, in the very
/// place of the arriving one, and the hero keeps one frame for every shape.
///
/// The worker's portrait moves in Core Animation (`HouseWorkerPortrait.HostView`) and its capsule in
/// SwiftUI, both from `pose(_:reducesMotion:)`. Under Reduce Motion every pose keeps its place and its
/// size, so only opacity changes.
enum HouseSwitch {

    /// How long the next worker waits before it comes in: the time it takes to step out of its room,
    /// so that the room letting it go and the conversation taking it read as one movement.
    static let entryDelay = RestylingTiming.roomExit

    /// How much later than the worker its capsule comes in.
    static let capsuleBeat = 0.08

    /// How long the leaving worker takes to step down and fade.
    static let exit = 0.2

    /// The perceptual duration and the bounce of the arriving worker's spring.
    static let arrival = 0.45
    static let bounce  = 0.15

    /// How long the transcripts cross-fade, which is also how long the leaving conversation stays.
    static let crossFade = 0.35

    /// Stage is where the hero is in a change of worker.
    enum Stage: Hashable {
        case arriving
        case present
        case leaving
    }

    /// Pose is the hero's look at a stage: its opacity, how far below its place it sits, in points,
    /// and its scale about its foot.
    struct Pose: Equatable {
        let opacity: Double
        let drop   : CGFloat
        let scale  : CGFloat
    }

    /// The hero's pose at `stage`: rising from below while it arrives, stepped down while it leaves.
    static func pose(
        _ stage      : Stage,
        reducesMotion: Bool
    ) -> Pose {
        switch (stage, reducesMotion) {
        case (.present, _),
             (_, true)      : Pose(
                opacity: stage == .present ? 1 : 0,
                drop   : 0,
                scale  : 1
            )
        case (.arriving, _): Pose(
                opacity: 0,
                drop   : 10,
                scale  : 0.94
            )
        case (.leaving, _) : Pose(
                opacity: 0,
                drop   : 6,
                scale  : 0.92
            )
        }
    }

    /// How the capsule reaches `stage`: on the arriving spring after the worker, or stepping down
    /// with it; under Reduce Motion, a fade on the same beats.
    static func capsuleAnimation(
        to stage     : Stage,
        reducesMotion: Bool
    ) -> Animation? {
        switch stage {
        case .arriving:
            nil
        case .present:
            (reducesMotion ? Animation.easeOut(duration: arrival) : .spring(
                duration: arrival,
                bounce  : bounce
            )).delay(entryDelay + capsuleBeat)
        case .leaving:
            .easeIn(duration: exit)
        }
    }
}

extension EnvironmentValues {

    /// Whether the conversation is leaving the column for another worker's (`HouseSwitch`).
    @Entry var houseSwitchLeaving = false
}
