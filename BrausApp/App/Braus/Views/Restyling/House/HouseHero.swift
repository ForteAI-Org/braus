//
//  HouseHero.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseHero is the selected worker at the top of its conversation: its 56 point mascot, its name
/// and what it is doing now. The role shows on hover of the name, so the window says the name once.
struct HouseHero: View {
    let worker: MockWorker

    var body: some View {
        VStack(spacing: 0) {
            MascotFace(
                appearance: worker.appearance,
                status    : worker.status,
                brows     : BrowState(worker.status),
                size      : 56
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
            Text(worker.activity)
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
