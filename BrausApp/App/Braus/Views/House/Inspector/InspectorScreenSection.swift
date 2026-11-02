//
//  InspectorScreenSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// The live screen while there is a window to watch and it is neither over the
/// conversation, where the toolbar's screen toggle puts it, nor in its own window;
/// nothing otherwise.
struct InspectorScreenSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    /// The gap held after the section; the app's inspector has none, the house passes its own.
    var footerGap: CGFloat = 0

    var body: some View {
        if team.hasScreen(worker.id), team.screenPlace(of: worker.id) == .inspector {
            Section {
                WorkerScreenCard(
                    team  : team,
                    worker: worker,
                    place : .inspector
                )
            } header: {
                Text("Screen")
            } footer: {
                if footerGap > 0 { HouseSectionGap(height: footerGap) }
            }
        }
    }
}
