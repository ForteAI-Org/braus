//
//  HouseNowSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseNowSection is where the worker is in the flow, as the app's `InspectorNowSection` says it,
/// on `MockTeam`'s values: whether it answers or compacts its context, and what it does with the
/// computer: the app it drives while busy, what it needs from the person while it waits.
struct HouseNowSection: View {
    let worker: MockWorker
    let team  : MockTeam

    @Binding var isExpanded: Bool

    var body: some View {
        HouseFoldableSection(
            title     : "Now",
            isExpanded: $isExpanded
        ) {
            LabeledContent("Status") {
                if team.isAnswering(worker) || team.isCompacting(worker) {
                    StatusText(
                        team.isCompacting(worker) ? "Compacting Context" : "Answering",
                        tone: .active
                    )
                } else {
                    StatusText(
                        "Idle",
                        tone: .quiet
                    )
                }
            }

            LabeledContent("Computer") { computer }
        }
    }

    @ViewBuilder
    private var computer: some View {
        switch worker.status {
        case .busy:
            StatusText(
                worker.activity,
                tone: .active
            )
        case .waiting:
            StatusText(
                worker.activity,
                tone: .waiting
            )
        case .free, .off:
            Text("Not Using This Mac")
                .foregroundStyle(.secondary)
        }
    }
}
