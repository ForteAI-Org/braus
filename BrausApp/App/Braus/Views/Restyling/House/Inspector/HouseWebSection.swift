//
//  HouseWebSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseWebSection is the conversation's choice of how Braus's Chrome runs, as the app's
/// `InspectorBrowserSection` offers it, on `MockTeam`'s values: headless, or a window the person
/// can watch. It is the same choice as Show Chrome Window in the composer's `+` menu. What the
/// app's section says in its footer is the toggle's description here, since a section that folds
/// has no footer.
struct HouseWebSection: View {
    let worker: MockWorker
    let team  : MockTeam

    @Binding var isExpanded: Bool

    var body: some View {
        Section(
            "Web",
            isExpanded: $isExpanded
        ) {
            Toggle(isOn: Binding(
                get: { team.showsBrowserWindow(of: worker) },
                set: { shows in
                    team.setShowsBrowserWindow(
                        shows,
                        of: worker
                    )
                }
            )) {
                Text("Show Chrome Window")
                Text("Braus drives pages in its own Chrome, never yours. Shown or hidden, it does not take your focus. A change applies the next time Braus opens a page.")
            }
        }
    }
}
