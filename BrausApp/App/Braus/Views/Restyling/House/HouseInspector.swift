//
//  HouseInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseInspector is the mockup's inspector, a grouped form with the system's own section headers
/// as the app's inspector is (`WorkerInspectorView`), with its sections on `MockTeam`'s values: the
/// worker itself, which the person edits here (`HouseWorkerSection`), where the worker is now, its screen
/// while it is busy and the toolbar's Screen toggle is on, its model and provider, its Chrome
/// window, and its current or last turn (`InspectorTurnSection`). With no worker chosen it says
/// where the details come from.
///
/// Every section is always open. The list of providers opens in place, and the inspector keeps
/// which worker's list is open, so coming back to that worker finds it as it was left.
struct HouseInspector: View {
    let worker     : Binding<HouseWorker>?
    let showsScreen: Bool

    /// The worker whose list of providers is open, as the app's `TeamModel.choosingProviderFor`.
    @State private var choosingProviderFor: HouseWorker.ID?

    @Environment(MockTeam.self)
    private var team: MockTeam?

    var body: some View {
        if let binding = worker, let team {
            let worker = binding.wrappedValue
            Form {
                ForEach(Self.parts(
                    showsScreen: showsScreen,
                    isBusy     : worker.status == .busy
                )) { part in
                    section(
                        part,
                        binding: binding,
                        team   : team
                    )
                }
            }
            .formStyle(.grouped)
            // Room above the first section and below the last.
            .contentMargins(.vertical, 28, for: .scrollContent)
        } else {
            ContentUnavailableView(
                "No Worker",
                systemImage: "info.circle",
                description: Text("Details appear when you choose a room.")
            )
        }
    }

    /// Part is one section of the inspector, in the order they stand.
    enum Part: Identifiable, CaseIterable {
        case screen, worker, now, model, web, turn

        var id: Self { self }
    }

    /// The sections that stand now, in order: Screen comes first whenever the worker is busy and
    /// the toolbar's Screen toggle is on, then the worker itself.
    static func parts(
        showsScreen: Bool,
        isBusy     : Bool
    ) -> [Part] {
        Part.allCases.filter { $0 != .screen || (showsScreen && isBusy) }
    }

    @ViewBuilder
    private func section(
        _ part  : Part,
        binding : Binding<HouseWorker>,
        team    : MockTeam
    ) -> some View {
        let worker = binding.wrappedValue
        switch part {
        case .screen:
            HouseScreenSection(worker: worker)
        case .worker:
            HouseWorkerSection(
                name             : worker.name,
                role             : worker.role,
                shape            : worker.shape,
                roleFollowsTyping: true,
                isSpacious       : true,
                commitName       : { binding.wrappedValue.name = $0 },
                commitRole       : { binding.wrappedValue.role = $0 },
                commitShape      : { binding.wrappedValue.shape = $0 }
            )
            .id(worker.id)
        case .now:
            HouseNowSection(
                worker: worker,
                team  : team
            )
        case .model:
            HouseModelSection(
                worker    : worker,
                team      : team,
                isChoosing: Binding(
                    get: { choosingProviderFor == worker.id },
                    set: { choosingProviderFor = $0 ? worker.id : nil }
                )
            )
        case .web:
            HouseWebSection(
                worker: worker,
                team  : team
            )
        case .turn:
            InspectorTurnSection(
                workerName: worker.name,
                turn      : team.lastTurn(of: worker),
                rowPadding: InspectorRowSpacing.vertical
            )
        }
    }
}
