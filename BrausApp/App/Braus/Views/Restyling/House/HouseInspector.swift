//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector: only two satin slabs, the worker's screen while it
/// has one and the toolbar's Screen toggle is on, and its provider. With no worker chosen it says
/// where the details come from.
struct HouseInspector: View {
    let worker     : MockWorker?
    let showsScreen: Bool

    var body: some View {
        if let worker {
            ScrollView {
                VStack(spacing: 12) {
                    if showsScreen, worker.status == .busy {
                        ScreenSlab(worker: worker)
                    }
                    ProviderSlab()
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "No Worker",
                systemImage: "info.circle",
                description: Text("Details appear when you choose a room.")
            )
        }
    }
}
