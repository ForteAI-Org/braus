//
//  HouseHero.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseHero is the selected worker at the top of its conversation: its 56 point mascot, its name
/// and what it is doing now. The role shows on hover of the name, so the window says the name once.
///
/// The conversation gives the moment's `status`, `brows` and `activity`, and raises `preparation`
/// when the worker sets about a message, which the head plays once.
struct HouseHero: View {
    let worker     : MockWorker
    let status     : WorkerStatus
    let brows      : BrowState
    let activity   : String
    let preparation: Int

    var body: some View {
        VStack(spacing: 0) {
            MascotFace(
                shape      : worker.shape,
                status     : status,
                brows      : brows,
                size       : 56,
                preparation: preparation
            )
            Text(worker.name)
                .font(.system(
                    size  : 15,
                    weight: .semibold
                ))
                .padding(
                    .top,
                    8
                )
                .help(role)
            Text(activity)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(
                    .top,
                    2
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
