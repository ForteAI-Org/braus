//
//  HouseWebSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseWebSection is the conversation's choice of how Braus's Chrome runs, as the app's
/// `InspectorBrowserSection` offers it, on `MockTeam`'s values: headless, or a window the person
/// can watch. It is the same choice as Show Chrome Window in the composer's `+` menu. The toggle
/// carries one short line where the app's section has a footer, since a section that folds has none.
struct HouseWebSection: View {
    let worker: MockWorker
    let team  : MockTeam

    @Binding var isExpanded: Bool

    var body: some View {
        HouseFoldableSection(
            title     : "Web",
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
                Text("Braus uses its own Chrome, never yours.")
            }
        }
    }
}
