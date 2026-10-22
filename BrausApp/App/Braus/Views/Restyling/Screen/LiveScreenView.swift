//
//  LiveScreenView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// LiveScreenView is the worker's real screen as its own window shows it: the seat's frames
/// (`WorkerScreenView`) with `ScreenHoverControls` over them while the pointer is over the screen or
/// a button has the keyboard.
///
/// Stop ends the worker's running turn and gives the computer back, which also ends the screen.
/// Take Control and Say Something stay disabled until they exist.
struct LiveScreenView: View {
    let team    : TeamModel
    let workerID: UUID

    @State private var isHovering = false

    @FocusState private var focusedControl: ScreenHoverControls.Control?

    var body: some View {
        WorkerScreenView(
            team    : team,
            workerID: workerID,
            place   : .window,
            isPaused: false
        )
        .id(workerID)
        .background(.black)
        .overlay(alignment: .bottom) {
            ScreenHoverControls(
                focus: $focusedControl,
                stop : stop
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
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(team.worker(workerID)?.name ?? "Worker")'s screen")
    }

    private func stop() {
        team.stopAnswering(workerID)
        Task { await team.releaseComputer(workerID) }
    }
}
