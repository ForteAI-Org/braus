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
/// A click on the card, or its Enlarge Screen button, shows the screen larger in a popover beside
/// the inspector, which stands in for the app's enlarged screen over the conversation. The button
/// shows while the pointer is over the card or it has the keyboard, and is always there for
/// VoiceOver.
struct HouseScreenSection: View {
    let worker: MockWorker

    @Binding var isExpanded: Bool

    /// The enlarged screen's width.
    static let enlargedWidth: CGFloat = 560

    @State private var isHovering = false

    @State private var isEnlarged = false

    @FocusState private var isButtonFocused: Bool

    var body: some View {
        HouseFoldableSection(
            title     : "Screen",
            isExpanded: $isExpanded
        ) {
            LabeledContent(
                "App",
                value: HouseMockScreen.appName(of: worker)
            )
            HouseMockScreen(worker: worker)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isEnlarged = true }
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topTrailing) { enlargeButton }
                .onHover { isHovering = $0 }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(worker.name)'s screen")
                .accessibilityAction(named: "Enlarge Screen") { isEnlarged = true }
                .popover(
                    isPresented: $isEnlarged,
                    arrowEdge  : .leading
                ) {
                    HouseMockScreen(worker: worker)
                        .frame(width: Self.enlargedWidth)
                        .padding(16)
                }
        }
    }

    private var enlargeButton: some View {
        Button(
            "Enlarge Screen",
            systemImage: "arrow.up.left.and.arrow.down.right"
        ) {
            isEnlarged = true
        }
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
        .padding(8)
        .opacity(isHovering || isButtonFocused ? 1 : 0)
        .help("Enlarge the worker’s screen.")
    }
}
