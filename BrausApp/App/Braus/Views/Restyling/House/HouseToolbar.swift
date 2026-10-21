//
//  HouseToolbar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseToolbar is the house window's own controls at the trailing edge of the toolbar, placed as
/// the team window places them (`TeamShellView`): the worker's usage in a capsule of its own
/// (`HouseUsageCapsule`), once it has recorded a turn, then the Screen and Inspector controls.
///
/// The window has no title, so the flexible space is what takes them to the trailing edge; before
/// macOS 26 it is an item holding only a spacer. The items keep their identities whichever worker
/// is shown: only showing no worker, or a worker with no turn yet, leaves the usage out.
struct HouseToolbar: ToolbarContent {
    let worker              : MockWorker?
    let team                : MockTeam
    let isInspectorRequested: Bool
    let toggleInspector     : () -> Void

    @Binding var showsScreen: Bool

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }

        if let worker, UsageWording.counter(of: team.usage(of: worker)) != nil {
            // One item, so macOS 26 draws the ring and the counter in one glass capsule.
            ToolbarItem {
                HouseUsageCapsule(
                    worker: worker,
                    team  : team
                )
            }

            // Its own glass capsule, apart from the Screen and Inspector controls.
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }

        ToolbarItem {
            Toggle(isOn: $showsScreen) {
                Label(
                    "Show Screen",
                    systemImage: "display"
                )
            }
            .toggleStyle(.button)
            .disabled(worker?.status != .busy)
            .help("Show or hide the worker’s screen.")
        }

        ToolbarItem {
            Button(
                isInspectorRequested ? "Hide Inspector" : "Show Inspector",
                systemImage: "info.circle",
                action     : toggleInspector
            )
            .keyboardShortcut(
                "i",
                modifiers: [.control, .option, .command]
            )
            .help("Show or hide the inspector.")
        }
    }
}
