//
//  HouseWebSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseWebSection is the conversation's choice of how Braus's Chrome runs, as the app's
/// `InspectorBrowserSection` offers it, on `MockTeam`'s values: headless, or a window the person
/// can watch. It is the same choice as Show Chrome Window in the composer's `+` menu. Its footer is one
/// short line where the app's section says more.
struct HouseWebSection: View {
    let worker: MockWorker
    let team  : MockTeam

    var body: some View {
        Section {
            Toggle(
                "Show Chrome Window",
                isOn: Binding(
                    get: { team.showsBrowserWindow(of: worker) },
                    set: { shows in
                        team.setShowsBrowserWindow(
                            shows,
                            of: worker
                        )
                    }
                )
            )
        } header: {
            Text("Web")
        } footer: {
            Text("Braus uses its own Chrome, never yours.")
                .padding(.bottom, 2)
        }
    }
}
