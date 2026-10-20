//
//  RestylingWindowView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// RestylingWindowView is the restyling mockup's house window, dark only: the house in the sidebar,
/// the conversation with the chosen worker, and an inspector that opens from the toolbar. Window,
/// sidebar and inspector keep the system's own backgrounds; only their content is drawn.
///
/// The toolbar holds New Worker beside the traffic lights, and at the trailing edge the Screen and
/// Inspector controls; the window has no title, as the worker sits at the top of its conversation.
/// New Worker is a placeholder. Edit > Find… focuses the sidebar's search (`HouseFindCommands`).
struct RestylingWindowView: View {

    @State private var house = MockHouse.sample

    @State private var selection: MockWorker.ID?

    @State private var showsInspector = false

    @State private var showsScreen = true

    var body: some View {
        NavigationSplitView {
            HouseSidebar(
                house    : house,
                selection: $selection
            )
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem {
                    Button(
                        "New Worker",
                        systemImage: "plus"
                    ) {}
                    .help("New worker")
                }
            }
            .navigationSplitViewColumnWidth(
                min  : ShellMetrics.compactSidebar,
                ideal: ShellMetrics.sidebar.ideal,
                max  : ShellMetrics.sidebar.maximum
            )
        } detail: {
            detail
                .frame(
                    minWidth : 0,
                    maxWidth : .infinity,
                    minHeight: 0,
                    maxHeight: .infinity
                )
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    HouseInspector(
                        worker     : selectedWorker,
                        showsScreen: showsScreen
                    )
                    .inspectorColumnWidth(
                        min  : ShellMetrics.inspector.minimum,
                        ideal: ShellMetrics.inspector.ideal,
                        max  : ShellMetrics.inspector.maximum
                    )
                }
        }
        .toolbar(removing: .title)
        .frame(
            minWidth : ShellMetrics.windowMinimum,
            minHeight: 560
        )
        .preferredColorScheme(.dark)
    }

    private var selectedWorker: MockWorker? {
        house.workers.first { $0.id == selection }
    }

    // MARK: Toolbar

    /// The Screen and Inspector controls at the trailing edge. The window has no title, so the
    /// flexible space takes them there; before macOS 26 it is an item holding only a spacer.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }

        ToolbarItem {
            Toggle(isOn: $showsScreen) {
                Label(
                    "Show Screen",
                    systemImage: "display"
                )
            }
            .toggleStyle(.button)
            .disabled(selectedWorker?.status != .busy)
            .help("Show or hide the worker’s screen.")
        }

        ToolbarItem {
            Button(
                showsInspector ? "Hide Inspector" : "Show Inspector",
                systemImage: "info.circle"
            ) {
                showsInspector.toggle()
            }
            .keyboardShortcut(
                "i",
                modifiers: [.control, .option, .command]
            )
            .help("Show or hide the inspector.")
        }
    }

    // MARK: Areas

    @ViewBuilder
    private var detail: some View {
        if let worker = selectedWorker {
            HouseConversationView(worker: worker)
                .id(worker.id)
        } else {
            ContentUnavailableView(
                "Choose a Room",
                systemImage: "house",
                description: Text("Pick a room to talk with its worker.")
            )
        }
    }
}
