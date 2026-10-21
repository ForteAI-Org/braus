//
//  HouseLiveInspector.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import SwiftUI

/// HouseLiveInspector is the house's inspector (`HouseShellView`): a grouped form, its rows a little
/// taller than the system's and a gap after each section, over the inspector's sections.
///
/// The turn's model and effort are the execution's frozen settings (`TurnSummary`), never the
/// current profile. Colour is kept for state: a dot beside what the worker is doing and how its
/// connection is, and a symbol with every outcome, so nothing depends on colour alone.
///
/// The Screen section comes first while the worker has a screen to watch, then the worker itself,
/// which the person edits here and which is saved through `TeamModel.update`, then where the worker
/// is now, its model and provider, its Chrome window and its current or last turn. With no worker
/// chosen it says where the details come from.
struct HouseLiveInspector: View {

    let team: TeamModel

    var body: some View {
        if let worker = team.selectedWorker {
            Content(
                team  : team,
                worker: worker
            )
        } else {
            ContentUnavailableView(
                "No Worker Selected",
                systemImage: "info.circle",
                description: Text("Select a worker to view current activity and turn details.")
            )
        }
    }

    /// Content is the form for a chosen worker.
    struct Content: View {

        let team  : TeamModel
        let worker: WorkerSnapshot

        /// The room the house gives its rows and the end of its sections, passed to every real section.
        static let rowPadding = InspectorRowSpacing.vertical
        static let footerGap  = HouseSectionGap.height

        @State private var turn = InspectorTurnSection.Reading.reading

        /// What reading the turn again depends on: a new record in the open conversation, or a turn
        /// starting or ending.
        private struct TurnKey: Equatable {
            let workerID : UUID
            let revision : Int
            let isRunning: Bool
        }

        var body: some View {
            Form {
                InspectorScreenSection(
                    team     : team,
                    worker   : worker,
                    footerGap: Self.footerGap
                )

                HouseWorkerSection(
                    name       : worker.name,
                    role       : worker.role ?? "",
                    shape      : worker.shape,
                    commitName : { update(.name($0)) },
                    commitRole : { update(.role($0.isEmpty ? nil : $0)) },
                    commitShape: { update(.shape($0.rawValue)) }
                )
                .id(worker.id)

                InspectorNowSection(
                    team      : team,
                    worker    : worker,
                    rowPadding: Self.rowPadding,
                    footerGap : Self.footerGap
                )
                InspectorModelSection(
                    team      : team,
                    worker    : worker,
                    rowPadding: Self.rowPadding,
                    footerGap : Self.footerGap
                )
                InspectorBrowserSection(
                    team      : team,
                    worker    : worker,
                    rowPadding: Self.rowPadding,
                    footerGap : Self.footerGap
                )
                InspectorTurnSection(
                    workerName: worker.name,
                    turn      : turn,
                    rowPadding: Self.rowPadding
                )
            }
            .formStyle(.grouped)
            // Room above the first section and below the last, as the house's own inspector has it.
            .contentMargins(.vertical, 28, for: .scrollContent)
            .task(id: TurnKey(
                workerID : worker.id,
                revision : team.transcriptRevision,
                isRunning: team.isAnswering(worker.id)
            )) {
                await readTurn()
            }
        }

        /// Saves one edit of this worker; the id is taken now, so a worker chosen next is not touched.
        private func update(_ change: WorkerChange) {
            let id   = worker.id
            let team = team
            Task { await team.update(id, change) }
        }

        private func readTurn() async {
            do {
                let summary = try await team.latestTurn(of: worker.id)
                turn = summary.map(InspectorTurnSection.Reading.read) ?? .nothingYet
            } catch {
                turn = .failed(String(describing: error))
            }
        }
    }
}
