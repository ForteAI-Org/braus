//
//  HouseHero.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseHero is the selected worker at the top of its conversation: its 56 point mascot, raised a
/// little over a glass capsule that holds its name and its subtitle (what it is doing or needs, or
/// what it does while free or off), lit from below by a soft `HeroLight` that follows the status.
/// The kind of work shows on hover of the name, so the window says the name once.
///
/// The conversation gives the moment's `status`, `brows` and `activity`, and raises `preparation`
/// when the worker sets about a message, which the head plays once.
struct HouseHero: View {
    let worker     : MockWorker
    let status     : WorkerStatus
    let brows      : BrowState
    let activity   : String
    let preparation: Int

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
        VStack(spacing: 0) {
            MascotFace(
                shape        : worker.shape,
                status       : status,
                brows        : brows,
                size         : 56,
                preparation  : preparation,
                behaviourSeed: Self.behaviourSeed(
                    of    : worker,
                    status: status,
                    brows : brows
                )
            )
            .offset(y: -4)
            VStack(spacing: 2) {
                Text(worker.name)
                    .font(.system(
                        size  : 15,
                        weight: .semibold
                    ))
                    .help(role)
                Text(activity)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(
                .horizontal,
                18
            )
            .padding(
                .vertical,
                7
            )
            .modifier(GlassCapsule(cornerRadius: 40))
            .padding(
                .top,
                6
            )
        }
        .background(alignment: .top) {
            // Centred a little below the mascot's middle; it fades to nothing before its frame's edge.
            HeroLight(status: status)
                .frame(
                    width : 300,
                    height: 140
                )
                .offset(y: -22)
                .allowsHitTesting(false)
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
