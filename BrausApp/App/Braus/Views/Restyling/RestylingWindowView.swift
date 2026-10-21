//
//  RestylingWindowView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// RestylingWindowView is the restyling mockup's house window, in the house's frame (`HouseSplit`): the
/// house in the sidebar, the conversation with the chosen worker, and an inspector that opens from the
/// toolbar.
///
/// The toolbar holds New Worker by the traffic lights; at the trailing edge, the worker's usage, the Screen and
/// Inspector controls; the window has no title, as the worker sits at the top of its conversation.
/// New Worker opens its sheet (`HouseNewWorkerSheet`), and the worker it creates is chosen. A room's
/// Edit Worker… chooses its worker and shows the inspector, where the worker is edited. Edit > Find…
/// focuses the sidebar's search (`HouseFindCommands`).
///
/// A worker chosen with the pointer hands the keyboard to the composer, so the sidebar's selection
/// draws unemphasized; one chosen with the arrow keys leaves it in the sidebar to keep browsing, and
/// Return there moves it to the composer. The conversation, the toolbar and the inspector follow the
/// selection a frame later (`shownSelection`): the frame of the choice carries only the sidebar,
/// where the room's plaque starts its swing, and building the conversation, tens of milliseconds,
/// runs while Core Animation plays it.
struct RestylingWindowView: View {

    @State private var house = MockHouse.sample

    /// What the app's own components read, on mock values: the model, the usage, the connections.
    @State private var team = MockTeam()

    @State private var selection: HouseWorker.ID?

    /// The worker the conversation shows, which follows `selection` once its frame is committed.
    @State private var shownSelection: HouseWorker.ID?

    /// Whether the conversation about to be shown takes the keyboard: its worker was chosen with the
    /// pointer.
    @State private var focusesShownComposer = false

    /// Whether the person asked for the inspector, which a narrow window may not show yet.
    @State private var isInspectorRequested = false

    @State private var showsScreen = true

    @State private var isCreatingWorker = false

    @FocusState private var isComposerFocused: Bool

    var body: some View {
        HouseSplit(isInspectorRequested: $isInspectorRequested) {
            HouseSidebar(
                house    : house,
                selection: $selection,
                edit     : edit
            )
            .onKeyPress(.return) {
                guard selection != nil else { return .ignored }
                isComposerFocused = true
                return .handled
            }
            .toolbar {
                ToolbarItem {
                    Button(
                        "New Worker",
                        systemImage: "plus"
                    ) {
                        isCreatingWorker = true
                    }
                    .help("New worker")
                }
            }
        } detail: {
            HouseDetail(
                worker           : selectedWorker,
                isComposerFocused: $isComposerFocused
            )
            .toolbar { toolbar }
        } inspector: {
            HouseInspector(
                worker     : selectedWorkerBinding,
                showsScreen: showsScreen
            )
        }
        .background(FirstWindowSize())
        .sheet(isPresented: $isCreatingWorker) {
            HouseNewWorkerSheet(house: $house) { selection = $0 }
        }
        .onChange(of: selection) {
            focusesShownComposer = selection != nil && NSApp.currentEvent?.type != .keyDown
            // An empty group completes once the current transaction commits, normally the sidebar's frame
            // that starts the plaque's swing; the conversation then builds while Core Animation plays it.
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { shownSelection = selection }
            }
            CATransaction.commit()
        }
        .onChange(of: shownSelection) {
            guard focusesShownComposer else { return }
            Task {
                // Asked for before the new composer is in its window, the focus would be dropped.
                await Task.yield()
                isComposerFocused = true
            }
        }
        .environment(team)
    }

    private var selectedWorker: HouseWorker? {
        house.workers.first { $0.id == shownSelection }
    }

    /// The shown worker, for the inspector to edit in the house.
    private var selectedWorkerBinding: Binding<HouseWorker>? {
        house.workers.firstIndex { $0.id == shownSelection }.map { $house.workers[$0] }
    }

    /// Chooses `worker` and shows the inspector, where it is edited, as the app's Choose Provider… does.
    private func edit(_ worker: HouseWorker.ID) {
        selection            = worker
        isInspectorRequested = true
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        HouseToolbar(
            worker              : selectedWorker,
            team                : team,
            isInspectorRequested: isInspectorRequested,
            toggleInspector     : { isInspectorRequested.toggle() },
            showsScreen         : $showsScreen
        )
    }

    /// FirstWindowSize opens the house at the design's 1180 × 720 the first time, then never again,
    /// so later launches keep the frame the person left. The scene is shared with the team window,
    /// whose saved frame the house inherits, so the first time is the house's own defaults flag
    /// (`AppPreferences.restylingDidSizeWindow`), not a saved frame. It draws nothing.
    private struct FirstWindowSize: NSViewRepresentable {

        func makeNSView(context: Context) -> BridgeView { BridgeView() }

        func updateNSView(
            _ view : BridgeView,
            context: Context
        ) {}

        /// The AppKit end: it sizes its window once, on the turn after it joins it.
        final class BridgeView: NSView {

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                let defaults = UserDefaults.standard
                guard window != nil, !defaults.bool(forKey: AppPreferences.restylingDidSizeWindow) else { return }

                defaults.set(
                    true,
                    forKey: AppPreferences.restylingDidSizeWindow
                )
                // After SwiftUI has restored the scene's saved frame, which would otherwise win.
                DispatchQueue.main.async { [weak self] in
                    guard let window = self?.window else { return }

                    window.setContentSize(NSSize(
                        width : 1180,
                        height: 720
                    ))
                    window.center()
                }
            }
        }
    }
}
