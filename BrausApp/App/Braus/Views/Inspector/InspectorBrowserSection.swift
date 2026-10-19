//
//  InspectorBrowserSection.swift
//  Braus
//

import SwiftUI

/// The conversation's choice of how Braus's Chrome runs: headless, the default, or as a window the
/// person can watch. Either way the pages are driven from inside Chrome, so the window never takes
/// the person's focus. Shown only when the web is offered, for the open conversation of the
/// selected worker.
struct InspectorBrowserSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    var body: some View {
        if team.offersWeb, let conversation = team.conversation, conversation.participantIDs.contains(worker.id) {
            Section {
                Toggle(
                    "Show Chrome Window",
                    isOn: Binding(
                        get: { team.showsBrowserWindow(in: conversation.id) },
                        set: { shows in
                            Task {
                                await team.setShowsBrowserWindow(
                                    shows,
                                    in: conversation.id
                                )
                            }
                        }
                    )
                )
            } header: {
                Text("Web")
            } footer: {
                Text("Braus drives pages in its own Chrome, never yours. Shown or hidden, it does not take your focus. A change applies the next time Braus opens a page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
