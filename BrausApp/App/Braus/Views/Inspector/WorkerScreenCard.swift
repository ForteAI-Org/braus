//
//  WorkerScreenCard.swift
//  Braus
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

    /// Set by the house's shell: opens the worker's screen in its own window.
    @Environment(\.openWorkerScreen) private var openWorkerScreen

    @State private var isHovering = false

    /// The shape of the picture drawn inside the card, nil until the first frame.
    @State private var pictureAspect: CGFloat?

    @FocusState private var isButtonFocused: Bool

    var body: some View {
        if team.hasScreen(worker.id) {
            let frame = team.screenFrame(of: worker.id)
            let ratio = frame.width > 0 && frame.height > 0 ? frame.width / frame.height : 16.0 / 10.0
            // The enlarged screen stands in for it; hidden, it still has the frame the shrink lands in.
            let isEnlarged = team.enlargedScreen?.workerID == worker.id
            WorkerScreenView(
                team           : team,
                workerID       : worker.id,
                place          : place,
                isPaused       : isEnlarged || team.windowedScreens.contains(worker.id),
                onPictureAspect: { aspect in Task { @MainActor in pictureAspect = aspect } }
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
            // The picture can be narrower than the card, with bars inside it; the button sits on the picture.
            .overlay {
                Color.clear
                    .aspectRatio(
                        pictureAspect ?? ratio,
                        contentMode: .fit
                    )
                    .overlay(alignment: .topTrailing) { enlargeButton }
                    .overlay(alignment: .topLeading) { windowButton }
            }
            .onHover { isHovering = $0 }
            .onChange(of: worker.id) { pictureAspect = nil }
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
            .accessibilityAction(named: "Open Screen in Window") { openWorkerScreen?(worker.id) }
        }
    }

    @ViewBuilder
    private var windowButton: some View {
        if let open = openWorkerScreen {
            Button(
                "Open Screen in Window",
                systemImage: "macwindow"
            ) {
                open(worker.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
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
            .opacity(isHovering ? 1 : 0)
            .help("Open the worker’s screen in its own window.")
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
