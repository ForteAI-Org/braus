//
//  LiveScreenView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// LiveScreenView is the worker's real screen as the enlarged screen shows it: the seat's frames
/// (`WorkerScreenView`) with `ScreenHoverControls` over them while the pointer is over the screen or
/// a button has the keyboard. The screen's own window shows it on a stage instead
/// (`ScreenWindowContent`).
///
/// Stop ends the worker's running turn and gives the computer back, which also ends the screen.
/// Take Control pauses the worker and lends it the application; Say Something remains unavailable.
struct LiveScreenView: View {
    let team    : TeamModel
    let workerID: UUID
    var onPictureSize: ((CGSize) -> Void)?

    @State private var isHovering = false

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRuns

    @FocusState private var focusedControl: ScreenHoverControls.Control?

    var body: some View {
        WorkerScreenView(
            team    : team,
            workerID: workerID,
            place   : .window,
            isPaused: false,
            onPictureSize: onPictureSize
        )
        .id(workerID)
        .background(.black)
        .overlay(alignment: .bottom) {
            ScreenHoverControls(
                focus: $focusedControl,
                stop : stop,
                takeControl: { team.beginHumanControl(workerID) },
                namesKey   : ControlToggle.namesKey(
                    ControlShortcut.state(
                        of: workerID,
                        in: team
                    ),
                    voiceOver: voiceOverRuns
                )
            )
            .padding(6)
            .background(
                .regularMaterial,
                in: Capsule()
            )
            .padding(
                .bottom,
                12
            )
            .opacity(isHovering || focusedControl != nil ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.25),
                value: isHovering || focusedControl != nil
            )
        }
        .overlay(alignment: .top) {
            if let control = team.humanControls[workerID] {
                HumanControlBar(control: control)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(team.worker(workerID)?.name ?? "Worker")'s screen")
    }

    private func stop() {
        team.stopAnswering(workerID)
        Task { await team.releaseComputer(workerID) }
    }
}
