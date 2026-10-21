//
//  HouseWorkerMenu.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseWorkerMenu is a room's or a row's context menu: Edit Worker…, which calls `edit`, then what
/// the Team menu offers for the worker (`WorkerCommands`).
struct HouseWorkerMenu: View {
    let workerID: UUID
    let team    : TeamModel
    let edit    : (UUID) -> Void

    var body: some View {
        Button("Edit Worker…") { edit(workerID) }
        if let worker = team.worker(workerID) {
            Divider()
            WorkerCommands(
                worker: worker,
                team  : team
            )
        }
    }
}
