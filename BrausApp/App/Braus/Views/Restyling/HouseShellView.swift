//
//  HouseShellView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseShellView is the team window once the workspace is open (§3.1): the house's frame
/// (`HouseSplit`) over the team (`TeamModel`), dark only.
///
/// The sidebar is the house over the team's real workers (`HouseRoster`), the conversation is
/// `HouseLiveConversation` over the team's transcript, and the inspector is `HouseLiveInspector`.
/// The selection is the team's: a worker chosen with the pointer hands the keyboard to the composer, one chosen with the keys
/// leaves it in the sidebar, and Return there moves it to the composer. It presents the team's
/// sheets, dialogs and adapter approvals, and publishes the team for the Team menu.
struct HouseShellView: View {

    @Bindable
    var team: TeamModel

    /// The window's own memory of the person's request.
    @Binding var isInspectorRequested: Bool

    /// Moves each time a worker chosen with the pointer, or Return in the sidebar, hands the keyboard to
    /// the composer.
    @State private var composerFocus = 0

    var body: some View {
        HouseSplit(isInspectorRequested: $isInspectorRequested) {
            HouseSidebar(
                workers  : workers,
                selection: $team.selection,
                team     : team,
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
                .toolbar {
                    HouseLiveToolbar(
                        team                : team,
                        isInspectorRequested: isInspectorRequested,
                        toggleInspector     : { isInspectorRequested.toggle() }
                    )
                }
        } inspector: {
            inspector
        }
        .overlay { enlargedScreen }
        .environment(
            \.openWorkerScreen,
            { [team] workerID in
                WorkerScreenWindowController.open(
                    workerID: workerID,
                    team    : team
                )
            }
        )
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
            HouseNewWorkerSheet(
                shapes     : workers.map(\.shape),
                connections: { team.connections.states },
                catalogue  : { provider in
                    (try? await team.connections.loadCatalogue(for: provider)) ?? []
                }
            ) { request in
                Task {
                    await team.createWorker(
                        name        : request.name,
                        role        : request.role,
                        instructions: request.instructions,
                        appearance  : HouseNewWorkerSheet.startingAppearance(),
                        selection   : request.selection,
                        shape       : request.shape
                    )
                }
            }
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
    private var workers: [HouseWorker] {
        HouseRoster.workers(
            of              : team,
            showsUnreadCount: AppPreferenceValues.shared.sidebarShowsUnreadCount
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

    /// Under a root of its own, so the toolbar's items keep their identities when no worker is chosen.
    private var detail: some View {
        ZStack {
            if let worker = team.selectedWorker {
                HouseLiveConversation(
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
    }

    private var inspector: some View {
        HouseLiveInspector(team: team)
    }
}
