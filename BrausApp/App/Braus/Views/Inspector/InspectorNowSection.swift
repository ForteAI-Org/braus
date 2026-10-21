//
//  InspectorNowSection.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

/// Where the worker is in the flow: whether it answers, and what it does with the computer.
struct InspectorNowSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    /// Vertical padding added to each row, and the gap held after the section; the app's inspector
    /// keeps the system's own, the house passes its own.
    var rowPadding: CGFloat = 0
    var footerGap : CGFloat = 0

    var body: some View {
        Section {
            LabeledContent("Status") {
                if team.isAnswering(worker.id) {
                    StatusText(
                        team.isCompacting(worker.id) ? "Compacting Context" : "Answering",
                        tone: .active
                    )
                } else {
                    StatusText(
                        "Idle",
                        tone: .quiet
                    )
                }
            }
            .padding(.vertical, rowPadding)

            LabeledContent("Computer") { computer }
                .padding(.vertical, rowPadding)
        } header: {
            Text("Now")
        } footer: {
            if footerGap > 0 { HouseSectionGap(height: footerGap) }
        }
    }

    @ViewBuilder
    private var computer: some View {
        if team.holdsComputer(worker.id) {
            StatusText(
                team.activity(of: worker.id) ?? "Using This Mac",
                tone: .active
            )
        } else if let activity = team.activity(of: worker.id) {
            StatusText(
                activity,
                tone: .waiting
            )
        } else {
            Text("Not Using This Mac")
                .foregroundStyle(.secondary)
        }
    }
}
