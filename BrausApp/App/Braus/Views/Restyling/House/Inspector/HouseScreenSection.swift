//
//  HouseScreenSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseScreenSection is the worker's live screen in the inspector, as the app's
/// `InspectorScreenSection` and `WorkerScreenCard` show it: the app it drives, then its screen
/// (`HouseMockScreen`). The caller shows it only while there is a screen to watch.
///
/// A click on the card, or its Open Screen button, opens the worker's screen in its own window
/// (`WorkerScreenWindowController`). The button shows while the pointer is over the card or it has
/// the keyboard, and is always there for VoiceOver.
struct HouseScreenSection: View {
    let worker: MockWorker

    @State private var isHovering = false

    @FocusState private var isButtonFocused: Bool

    var body: some View {
        Section("Screen") {
            LabeledContent(
                "App",
                value: HouseMockScreen.appName(of: worker)
            )
            HouseMockScreen(worker: worker)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { Self.openScreen(of: worker) }
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topTrailing) { openButton }
                .onHover { isHovering = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(worker.name)'s screen")
                .accessibilityAction(named: "Open Screen") { Self.openScreen(of: worker) }
        }
    }

    /// Opens `worker`'s screen window, as the card's click and its button do.
    static func openScreen(of worker: MockWorker) {
        WorkerScreenWindowController.open(worker: worker)
    }

    private var openButton: some View {
        Button(
            "Open Screen",
            systemImage: "macwindow"
        ) {
            Self.openScreen(of: worker)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .focused($isButtonFocused)
        .padding(8)
        .opacity(isHovering || isButtonFocused ? 1 : 0)
        .help("Open the worker’s screen in its own window.")
    }
}
