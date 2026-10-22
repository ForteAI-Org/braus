//
//  HouseLiveToolbar.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseLiveToolbar is the house window's toolbar, fed by `TeamModel`. At the trailing edge, the
/// worker's usage in a capsule of its own (`ToolbarUsageCapsule`, the context ring and the token
/// counter) once it has recorded a turn, then the Screen toggle, which
/// moves the screen between the conversation and the inspector and works only while the worker has
/// one, and the Inspector toggle, which names itself by whether the window shows the inspector.
///
/// The items keep their identities whichever worker is shown: only choosing no worker, or a worker
/// with no turn yet, leaves the usage out.
struct HouseLiveToolbar: ToolbarContent {
    let team            : TeamModel
    let isInspectorShown: Bool
    let toggleInspector : () -> Void

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }

        if let worker = team.selectedWorker,
           let usage  = team.usage[worker.id],
           UsageWording.counter(of: usage) != nil {
            // One item, so macOS 26 draws the ring and the counter in one glass capsule.
            ToolbarItem {
                ToolbarUsageCapsule(
                    team  : team,
                    worker: worker,
                    usage : usage
                )
            }

            // Its own glass capsule, apart from the Screen and Inspector controls.
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }

        ToolbarItem {
            Toggle(isOn: screenOverConversation) {
                Label(
                    "Show Screen in Conversation",
                    systemImage: "display"
                )
            }
            .toggleStyle(.button)
            .disabled(!hasScreen)
            .help("Move the worker’s screen between the conversation and inspector.")
        }

        ToolbarItem {
            Button(
                Self.inspectorTitle(isShown: isInspectorShown),
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

    /// The inspector button's name: what pressing it would do to what the window shows, which a narrow
    /// window may keep from the person's request.
    static func inspectorTitle(isShown: Bool) -> String {
        isShown ? "Hide Inspector" : "Show Inspector"
    }

    /// True while the selected worker has a screen to watch.
    private var hasScreen: Bool {
        team.selection.map(team.hasScreen) ?? false
    }

    private var screenOverConversation: Binding<Bool> {
        Binding(
            get: { team.showsScreenInConversation },
            set: { shows in withAnimation(.snappy) { team.showsScreenInConversation = shows } }
        )
    }
}
