//
//  HouseSwitch.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseSwitch is how the conversation column changes worker. The name's glass capsule never leaves:
/// it stays in place, its words change as a reply's do (`HouseHeroCaption`) and its width follows
/// them. The shown worker drops into the capsule over `exit`, shrinking and fading; after
/// `entryDelay` the next worker hops out of it, small at first, up past its place and back down with
/// a squash on landing, over `hop`. The transcripts cross-fade over `crossFade`. The composer and the
/// toolbar stay where they are: the leaving composer and capsule hide at once, in the very places of
/// the arriving ones, and the hero keeps one frame for every shape.
///
/// The worker moves in Core Animation (`HouseWorkerPortrait.HostView`). Under Reduce Motion the
/// worker only fades and the capsule's words cross-fade.
enum HouseSwitch {

    /// How long the leaving worker takes to drop into the capsule.
    static let exit = 0.15

    /// How long the arriving worker's hop takes, from inside the capsule to rest.
    static let hop = 0.3

    /// How long the next worker waits before it hops: it lands as it finishes stepping out of its
    /// room (`RestylingTiming.roomExit`), and starts as the leaving worker is gone.
    static let entryDelay = max(
        0,
        RestylingTiming.roomExit - hop
    )

    /// How long the transcripts cross-fade, which is also how long the leaving conversation stays.
    static let crossFade = 0.3

    /// How long the capsule's old words take to fade before the new ones come in.
    static let captionFade = 0.08

    /// The capsule's spring as its width follows its words.
    static let captionResize = Animation.spring(
        duration: 0.3,
        bounce  : 0.12
    )

    /// Stage is where the hero is in a change of worker.
    enum Stage: Hashable {
        case arriving
        case present
        case leaving
    }

    /// Pose is the worker's look at a moment of a change: how far below its place it sits, in points,
    /// and its scale across and up about its foot.
    struct Pose: Equatable {
        let drop  : CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat

        static let rest = Pose(
            drop  : 0,
            scaleX: 1,
            scaleY: 1
        )
    }

    /// Where the leaving worker ends: down in the capsule, small.
    static let sunk = Pose(
        drop  : 16,
        scaleX: 0.45,
        scaleY: 0.45
    )

    /// The arriving worker's hop, as moments of `hop` (0 to 1) and poses: small in the capsule,
    /// stretched up past its place, squashed as it lands, then at rest.
    static let hopKeys: [(time: Double, pose: Pose)] = [
        (0, Pose(
            drop  : 14,
            scaleX: 0.36,
            scaleY: 0.44
        )),
        (0.45, Pose(
            drop  : -7,
            scaleX: 0.94,
            scaleY: 1.08
        )),
        (0.7, Pose(
            drop  : 0,
            scaleX: 1.09,
            scaleY: 0.9
        )),
        (0.86, Pose(
            drop  : 0,
            scaleX: 0.98,
            scaleY: 1.03
        )),
        (1, .rest),
    ]

    /// How much of the hop the worker takes to show, from inside the capsule.
    static let hopFade = 0.25
}

extension EnvironmentValues {

    /// Whether the conversation is leaving the column for another worker's (`HouseSwitch`).
    @Entry var houseSwitchLeaving = false

    /// The worker shown before this conversation's, whose capsule this one's takes over, or nil.
    @Entry var houseSwitchPrevious: MockWorker?
}
