//
//  WorkerScreenCard.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// WorkerScreenCard is the worker's live screen, in the inspector or at the top
/// right of the conversation; the toolbar's screen toggle moves it.
///
/// It keeps the window's proportions, 16 by 10 until a window is measured.
/// While there is no window to watch it draws nothing; the inspector says why.
///
/// A click on the card, or its button, enlarges the screen over the conversation.
/// The button shows while the pointer is over the card or it has the keyboard,
/// and is always there for VoiceOver.
struct WorkerScreenCard: View {

    let team  : TeamModel
    let worker: WorkerSnapshot
    let place : ScreenPlace

    @State private var isHovering = false

    @FocusState private var isButtonFocused: Bool

    var body: some View {
        if team.hasScreen(worker.id) {
            let frame = team.screenFrame(of: worker.id)
            let ratio = frame.width > 0 && frame.height > 0 ? frame.width / frame.height : 16.0 / 10.0
            // The enlarged screen stands in for it; hidden, it still has the frame the shrink lands in.
            let isEnlarged = team.enlargedScreen?.workerID == worker.id
            WorkerScreenView(
                team    : team,
                workerID: worker.id,
                place   : place,
                isPaused: isEnlarged
            )
            .opacity(isEnlarged ? 0 : 1)
            .id(worker.id)
            .aspectRatio(
                ratio,
                contentMode: .fit
            )
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: enlarge)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) { enlargeButton }
            .onHover { isHovering = $0 }
            .clipShape(RoundedRectangle(
                cornerRadius: 8,
                style       : .continuous
            ))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(worker.name)'s screen")
            .accessibilityAction(
                named: "Enlarge Screen",
                enlarge
            )
        }
    }

    private var enlargeButton: some View {
        Button(
            "Enlarge Screen",
            systemImage: "arrow.up.left.and.arrow.down.right",
            action     : enlarge
        )
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .focused($isButtonFocused)
        .font(.system(
            size  : 11,
            weight: .semibold
        ))
        .foregroundStyle(.white)
        .frame(
            width : 22,
            height: 22
        )
        .background(
            .black.opacity(0.55),
            in: Circle()
        )
        .padding(6)
        .opacity(isHovering || isButtonFocused ? 1 : 0)
        .help("Enlarge the worker’s screen.")
    }

    private func enlarge() {
        team.enlargeScreen(
            of  : worker.id,
            from: place
        )
    }
}
