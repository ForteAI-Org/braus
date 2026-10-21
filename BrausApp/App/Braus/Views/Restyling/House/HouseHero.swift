//
//  HouseHero.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseHero is the selected worker at the top of its conversation, standing in three quarters as its
/// room shows it (`HouseWorkerPortrait`), just over a small glass capsule that holds its name and its
/// subtitle (what it is doing or needs, or what it does while free or off). The capsule lights the
/// worker: a soft presentation light rises from it onto the worker's front face, warm white taking a
/// share of the status's colour (`HeroLight`), and leaves a faint glow along the capsule's top edge;
/// nothing lights the worker from behind. The kind of work shows on hover of the name, so the window
/// says the name once.
///
/// The conversation gives the moment's `status`, `brows` and `activity`, and raises `preparation`
/// when the worker sets about a message, which the worker plays once.
///
/// A change of worker brings the hero in and out on `HouseSwitch`'s beats. The hero's frame is the
/// same for every shape and every subtitle, so the transcript under it never moves.
struct HouseHero: View {
    let worker     : MockWorker
    let status     : WorkerStatus
    let brows      : BrowState
    let activity   : String
    let preparation: Int

    /// Where the hero is in a change of worker.
    var stage = HouseSwitch.Stage.present

    /// The side of the worker's sphere, in points.
    static let workerSize: CGFloat = 60

    /// The height the worker stands in: the tallest shape's, so every worker takes the same room.
    static let portraitHeight = WorkerShape.allCases.map { shape in
        HouseWorkerPortrait.silhouette(
            of  : shape,
            side: HouseWorkerPortrait.sceneSide(for: workerSize)
        ).boundingRect.height
    }.max() ?? workerSize

    /// The seed that makes the hero's brows live by `status`, or nil while `brows` is the conversation's
    /// own expression (listening, at work) rather than the status's, which the loop would override.
    static func behaviourSeed(
        of worker: MockWorker,
        status   : WorkerStatus,
        brows    : BrowState
    ) -> UInt64? {
        brows == BrowState(status) ? WorkerBehaviour.seed(for: worker.id) : nil
    }

    var body: some View {
        let pose = HouseSwitch.pose(
            stage,
            reducesMotion: RestylingMotion.reducesMotion
        )
        VStack(spacing: 4) {
            HouseWorkerPortrait(
                shape       : worker.shape,
                status      : status,
                size        : Self.workerSize,
                brows       : brows,
                seed        : Self.behaviourSeed(
                    of    : worker,
                    status: status,
                    brows : brows
                ),
                capsuleLight: HeroLight.capsuleLight(for: status),
                changeFade  : HeroLight.fade,
                preparation : preparation,
                switchStage : stage
            )
            .frame(
                height   : Self.portraitHeight,
                alignment: .bottom
            )
            .accessibilityHidden(true)
            VStack(spacing: 1) {
                Text(worker.name)
                    .font(.system(
                        size  : 13,
                        weight: .semibold
                    ))
                    .lineLimit(1)
                    .help(role)
                Text(activity)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(
                .horizontal,
                12
            )
            .padding(
                .vertical,
                4
            )
            .modifier(GlassCapsule(cornerRadius: 40))
            .overlay(alignment: .top) {
                // The light the capsule gives the worker, where it leaves the glass.
                HeroLight(status: status)
                    .frame(height: 10)
                    .padding(
                        .horizontal,
                        14
                    )
                    .offset(y: -4)
                    .allowsHitTesting(false)
            }
            .scaleEffect(
                pose.scale,
                anchor: .bottom
            )
            .offset(y: pose.drop)
            .opacity(pose.opacity)
            .animation(
                HouseSwitch.capsuleAnimation(
                    to           : stage,
                    reducesMotion: RestylingMotion.reducesMotion
                ),
                value: stage
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(role)
    }

    /// The mock worker's role, after the kind of app it drives.
    private var role: String {
        switch worker.category {
        case .audio  : "Audio engineer"
        case .video  : "Video editor"
        case .design : "Designer"
        case .web    : "Web researcher"
        case .files  : "File organizer"
        case .general: "Assistant"
        }
    }
}
