//
//  HouseWorkerMenu.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseWorkerMenu is a room's or a row's context menu: Edit Worker…, which calls `edit`, then, for a
/// real worker of `team`, what the team's own sidebar offers for it (`WorkerCommands`). The mockup,
/// with no team, offers Edit Worker… alone.
struct HouseWorkerMenu: View {
    let workerID: UUID
    let team    : TeamModel?
    let edit    : (UUID) -> Void

    var body: some View {
        Button("Edit Worker…") { edit(workerID) }
        if let team, let worker = team.worker(workerID) {
            Divider()
            WorkerCommands(
                worker: worker,
                team  : team
            )
        }
    }
}
