//
//  HouseShellView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseShellView is the team window in the new look (`AppPreferences.newLook`): the house's frame
/// (`HouseSplit`) over the same `TeamModel` today's `TeamShellView` reads, dark only.
///
/// The sidebar is the house over the team's real workers (`HouseRoster`); the conversation and the
/// inspector are today's views until the house's own take their place. The selection is the team's:
/// a worker chosen with the pointer hands the keyboard to the composer, one chosen with the keys
/// leaves it in the sidebar, and Return there moves it to the composer. The sheets, the dialogs, the
/// approvals and the Team menu are the ones `TeamShellView` presents, so either shell does the same.
struct HouseShellView: View {

    @Bindable
    var team: TeamModel

    /// The window's own memory of the person's request, shared with today's shell.
    @Binding var isInspectorRequested: Bool

    /// Moves each time a worker chosen with the pointer, or Return in the sidebar, hands the keyboard to
    /// the composer.
    @State private var composerFocus = 0

    var body: some View {
        HouseSplit(isInspectorRequested: $isInspectorRequested) {
            HouseSidebar(
                house    : house,
                selection: $team.selection,
                edit     : edit
            )
            .onKeyPress(.return) {
                guard team.selection != nil else { return .ignored }
                composerFocus += 1
                return .handled
            }
            .toolbar {
                ToolbarItem {
                    Button(
                        "New Worker",
                        systemImage: "plus"
                    ) {
                        team.isCreatingWorker = true
                    }
                    .help("New worker")
                }
            }
        } detail: {
            detail
                .toolbar { toolbar }
        } inspector: {
            inspector
        }
        .overlay { enlargedScreen }
        .onChange(of: team.selection) {
            // Another worker takes the enlarged screen away with no shrink to land.
            team.dismissEnlargedScreen()
            Task { await team.openSelectedConversation() }
            guard team.selection != nil, NSApp.currentEvent?.type != .keyDown else { return }
            Task {
                // Asked for before the new composer is in its window, the focus would be dropped.
                await Task.yield()
                composerFocus += 1
            }
        }
        .onChange(of: hasScreen) { _, hasScreen in
            if !hasScreen { team.dismissEnlargedScreen() }
        }
        // A window closed with the screen enlarged opens small again.
        .onDisappear { team.dismissEnlargedScreen() }
        .sheet(isPresented: $team.isCreatingWorker) {
            NewWorkerSheet(team: team)
        }
        .sheet(isPresented: $team.isShowingConnections) {
            ConnectionsSheet(connections: team.connections)
        }
        .sheet(isPresented: $team.isShowingPermissions) {
            PermissionsSheet(broker: team.broker)
        }
        // The worker's commands open its list of providers, which lives in the inspector.
        .onChange(of: team.choosingProviderFor) {
            if team.choosingProviderFor != nil { isInspectorRequested = true }
        }
        .focusedSceneValue(
            \.team,
            team
        )
        .confirmationDialog(
            deletionTitle,
            isPresented    : Binding(
                get: { team.deletingWorker != nil },
                set: { if !$0 { team.deletingWorker = nil } }
            ),
            titleVisibility: .visible,
            presenting     : team.deletingWorker.flatMap(team.worker)
        ) { worker in
            Button(
                "Delete Worker",
                role: .destructive
            ) {
                Task { await team.deleteWorker(worker.id) }
            }
            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: { _ in
            Text("""
                Its conversation, history, and model settings will be deleted. Its working folder will be \
                moved to the Trash. Shared Brain knowledge and data already sent to providers will remain. \
                Archive the worker instead if you want to keep its history.
                """)
        }
        // An irreversible adapter call waits here for the person, one call at a time.
        .adapterApprovals(team.approvals)
        .alert(
            team.problem?.title ?? "Braus Couldn’t Complete the Action",
            isPresented: Binding(
                get: { team.problem != nil },
                set: { if !$0 { team.problem = nil } }
            )
        ) {
            Button(
                "OK",
                role: .cancel
            ) {}
        } message: {
            Text(team.problem?.displayMessage ?? "")
        }
    }

    /// The team's active workers as the house's rooms.
    private var house: MockHouse {
        MockHouse(
            workers      : HouseRoster.workers(
                of              : team,
                showsUnreadCount: AppPreferenceValues.shared.sidebarShowsUnreadCount
            ),
            archivedCount: team.archived.count,
            mostUsed     : []
        )
    }

    private var deletionTitle: String {
        let name = team.deletingWorker.flatMap(team.worker)?.name ?? "this worker"
        return "Delete \(name)?"
    }

    /// True while the selected worker has a screen to watch.
    private var hasScreen: Bool {
        team.selection.map(team.hasScreen) ?? false
    }

    /// Chooses `worker` and shows the inspector, where it is edited, as Choose Provider… does.
    private func edit(_ worker: HouseWorker.ID) {
        team.selection       = worker
        isInspectorRequested = true
    }

    // MARK: Toolbar

    /// The inspector's toggle, until the house's own toolbar takes its place.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button(
                isInspectorRequested ? "Hide Inspector" : "Show Inspector",
                systemImage: "info.circle"
            ) {
                isInspectorRequested.toggle()
            }
            .keyboardShortcut(
                "i",
                modifiers: [.control, .option, .command]
            )
            .help("Show or hide the inspector.")
        }
    }

    // MARK: Areas

    /// The selected worker's screen over the whole window, while it is enlarged.
    @ViewBuilder
    private var enlargedScreen: some View {
        if let enlargement = team.enlargedScreen,
           let worker      = team.selectedWorker,
           enlargement.workerID == worker.id,
           team.hasScreen(worker.id) {
            ConversationEnlargedScreen(
                team       : team,
                worker     : worker,
                enlargement: enlargement
            )
            .ignoresSafeArea(
                .container,
                edges: .top
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let worker = team.selectedWorker {
            WorkerConversationView(
                team        : team,
                worker      : worker,
                focusRequest: composerFocus
            )
        } else if team.active.isEmpty && team.archived.isEmpty {
            FirstLaunchView(team: team)
        } else {
            ContentUnavailableView(
                "No Worker Selected",
                systemImage: "person.crop.circle",
                description: Text("Select a worker to open its conversation.")
            )
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let worker = team.selectedWorker {
            WorkerInspectorView(
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
}
