//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector, a grouped form as the app's own inspector is
/// (`WorkerInspectorView`), with its sections on `MockTeam`'s values: where the worker is now, its
/// screen while it is busy and the toolbar's Screen toggle is on, its model and provider, its
/// Chrome window, and its current or last turn (`InspectorTurnSection`). With no worker chosen it
/// says where the details come from.
///
/// Every section folds under its title, and the list of providers opens in place; the inspector
/// keeps both per worker (`InspectorDisclosure`), so coming back to a worker finds its inspector
/// as it was left.
struct HouseInspector: View {
    let worker     : MockWorker?
    let showsScreen: Bool

    @State private var disclosure = InspectorDisclosure()

    @Environment(MockTeam.self)
    private var team: MockTeam?

    var body: some View {
        if let worker, let team {
            Form {
                HouseNowSection(
                    worker    : worker,
                    team      : team,
                    isExpanded: expansion(
                        .now,
                        of: worker
                    )
                )
                if showsScreen, worker.status == .busy {
                    HouseScreenSection(
                        worker    : worker,
                        isExpanded: expansion(
                            .screen,
                            of: worker
                        )
                    )
                }
                HouseModelSection(
                    worker    : worker,
                    team      : team,
                    isExpanded: expansion(
                        .model,
                        of: worker
                    ),
                    isChoosing: Binding(
                        get: { disclosure.choosingProviderFor == worker.id },
                        set: { disclosure.choosingProviderFor = $0 ? worker.id : nil }
                    )
                )
                HouseWebSection(
                    worker    : worker,
                    team      : team,
                    isExpanded: expansion(
                        .web,
                        of: worker
                    )
                )
                InspectorTurnSection(
                    workerName: worker.name,
                    turn      : team.lastTurn(of: worker),
                    isExpanded: expansion(
                        .turn,
                        of: worker
                    )
                )
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Worker",
                systemImage: "info.circle",
                description: Text("Details appear when you choose a room.")
            )
        }
    }

    /// Whether `section` is open for `worker`, which folding it changes for that worker alone.
    private func expansion(
        _ section: InspectorDisclosure.Section,
        of worker: MockWorker
    ) -> Binding<Bool> {
        Binding(
            get: {
                disclosure.isExpanded(
                    section,
                    for: worker.id
                )
            },
            set: { isExpanded in
                disclosure.setExpanded(
                    isExpanded,
                    section,
                    for: worker.id
                )
            }
        )
    }
}
