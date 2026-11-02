//
//  ScreenControlBar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import SeatBroker
import SwiftUI

/// ScreenControlBar is the glass bar at the foot of a worker's screen window, over the picture as
/// on iPadOS: the screen's buttons (`ScreenHoverControls`), Open in Braus and Close. The worker and what it
/// says, how the person's control of its application stands included, sit on the window's top-right
/// corner instead (`ScreenWorkerPresence`).
struct ScreenControlBar: View {
    let worker : HouseWorker
    let lending: HumanPreviewControl?

    /// Whether the help names ⌃⌥Tab (`ScreenHoverControls.namesKey`).
    var namesKey = false

    /// Which button has the keyboard; the window keeps the bar shown while one has it.
    let focus      : FocusState<ScreenHoverControls.Control?>.Binding
    let opensFocus : FocusState<Bool>.Binding

    let stop       : () -> Void
    let takeControl: () -> Void
    let openInBraus: () -> Void
    let close      : () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ScreenHoverControls(
                focus      : focus,
                stop       : stop,
                takeControl: takeControl,
                lending    : lending,
                namesKey   : namesKey
            )
            .fixedSize()
            Button(action: openInBraus) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in Braus")
            .accessibilityLabel("Open in Braus")
            .focused(opensFocus)
            // The window has no chrome of its own. Closing it while the person has the application
            // gives the application back too.
            let closeTitle = ScreenHoverControls.isUnderway(lending) ? "Hand Back and Close" : "Close"
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(closeTitle)
            .accessibilityLabel(closeTitle)
        }
        .padding(
            .vertical,
            8
        )
        .padding(
            .horizontal,
            12
        )
        .modifier(GlassCapsule(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(worker.name)'s screen controls")
    }
}
