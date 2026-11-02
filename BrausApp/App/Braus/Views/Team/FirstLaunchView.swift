//
//  FirstLaunchView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SeatBroker
import SwiftUI

/// The first launch offers the two things there are to do. It invents no
/// team, and it asks for no desktop permission: talking to a worker never
/// needed one.
/// FirstLaunchView is the team window before its first worker: create one, connect a provider,
/// and allow the Mac permissions a worker's seat needs. The Mac Access sheet opens by itself the
/// first time this shows while a permission is missing, so the person is asked at the start and
/// not in the middle of a worker's first task.
struct FirstLaunchView: View {

    let team: TeamModel

    /// Set once the Mac Access sheet has opened by itself, so it does so on one launch only.
    @AppStorage("firstLaunch.offeredMacAccess")
    private var offeredMacAccess = false

    var body: some View {
        ContentUnavailableView {
            Label(
                "Create Your First Worker",
                systemImage: "person.2"
            )
        } description: {
            Text("A worker is an AI assistant that can use apps on this Mac for you. Create one, connect the AI service it runs on, and allow it to use your apps.")
        } actions: {
            // Capsule controls, as the house's own buttons (QueueStrip's Send Now); the first is prominent.
            Group {
                Button("Create Worker") { team.isCreatingWorker = true }
                    .buttonStyle(.borderedProminent)

                Button("Connect Provider…") { team.isShowingConnections = true }
                    .buttonStyle(.bordered)

                Button("Allow Mac Access…") { team.isShowingPermissions = true }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
        }
        .task {
            // A check run draws this screen and leaves the person's preference alone.
            guard !BrausApp.isCheckRun, !offeredMacAccess,
                  team.broker.desktopGrants().contains(where: { !$0.isGranted })
            else { return }
            offeredMacAccess          = true
            team.isShowingPermissions = true
        }
    }
}
