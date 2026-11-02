//
//  ConversationFloatingScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// The worker's live screen at the top right, below the title bar, while the
/// toolbar's screen toggle is on, there is a window to watch and the screen is
/// not in its own window.
///
/// It fades in and out as the conversations do when another worker is chosen,
/// and when the toggle or the seat changes. Its shadow belongs to the card's
/// background alone: cast by the whole card, it was worked out again on every
/// frame of the live screen, which stalled the conversation's own fade.
struct ConversationFloatingScreen: View {

    let team          : TeamModel
    let worker        : WorkerSnapshot
    let titleBarHeight: CGFloat

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if shown != nil {
                card
                    .id(worker.id)
                    .transition(
                        reducesMotion ? .opacity : .opacity.combined(with: .scale(
                            scale : 0.94,
                            anchor: .topTrailing
                        ))
                    )
            }
        }
        .ignoresSafeArea(
            .container,
            edges: .top
        )
        .animation(
            reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25),
            value: shown
        )
    }

    /// The worker whose screen floats, nil while none does; its changes are what animate.
    private var shown: UUID? {
        team.screenPlace(of: worker.id) == .conversation && team.hasScreen(worker.id) ? worker.id : nil
    }

    private var card: some View {
        WorkerScreenCard(
            team  : team,
            worker: worker,
            place : .conversation
        )
        .padding(6)
        .background {
            RoundedRectangle(
                cornerRadius: 12,
                style       : .continuous
            )
            .fill(.regularMaterial)
            .shadow(
                color : .black.opacity(0.18),
                radius: 10,
                y     : 4
            )
        }
        // The whole card steps aside while its screen is enlarged; its frame stays measurable.
        .opacity(team.enlargedScreen?.workerID == worker.id ? 0 : 1)
        .frame(width: 280)
        .padding(
            .top,
            titleBarHeight + 8
        )
        .padding(
            .trailing,
            16
        )
    }
}
