//
//  BrainAppView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AutomationRuntime
import Memory
import SwiftUI

/// BrainAppView is one application's Brain, pushed from the list of
/// applications with the application's name as its title: a graph that
/// moves and can be played as it grew, or a list. The window's toolbar
/// switches between the two, as a Finder window switches its views.
///
/// The simulation is made once the page appears and kept while it is open, so
/// going to the list and back finds the graph as it was left.
struct BrainAppView: View {

    enum Mode {
        case graph
        case list
    }

    let app: BrainAppSummary
    let directory: URL

    @State private var content = BrainAppContent()

    @State private var mode = Mode.graph

    @State private var simulation: BrainSimulation?

    var body: some View {
        Group {
            if let unavailable = content.unavailable {
                ContentUnavailableView(
                    String(localized: "Brain Unavailable"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(localized: "The Brain's memory could not be read: \(unavailable)"))
                )
            } else if content.isEmpty {
                ContentUnavailableView(
                    String(localized: "No App Knowledge Yet"),
                    systemImage: "brain"
                )
            } else if content.brain != nil {
                switch mode {
                    case .graph:
                        if let simulation {
                            BrainGraphView(simulation: simulation)
                                .scrollContentBackground(.hidden)
                                .background { Color.houseGround.ignoresSafeArea() }

                        } else {
                            Color.clear
                        }

                    case .list:
                        if let list = content.list {
                            BrainListView(content: list)
                                .scrollContentBackground(.hidden)
                                .background { Color.houseGround.ignoresSafeArea() }
                        }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(app.name)
        .background(TransparentTitleBar())
        .toolbar {
            ToolbarItem {
                Picker(
                    String(localized: "View"),
                    selection: $mode.animation(.easeInOut(duration: 0.2))
                ) {
                    Label(
                        String(localized: "Graph"),
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    .tag(Mode.graph)

                    Label(
                        String(localized: "List"),
                        systemImage: "list.bullet"
                    )
                    .tag(Mode.list)
                }
                .pickerStyle(.segmented)
                .help(String(localized: "Show the Brain as a graph or list."))
            }
        }
        .task {
            await content.load(bundleID: app.bundleID) { bundleID in
                try await MemoryService.shared(for: directory).brain(of: bundleID)
            }
            if simulation == nil, let brain = content.brain {
                simulation = await BrainSimulation.settled(BrainGraph(brain: brain))
            }
        }
    }
}

/// BrainAppContent keeps one detail page's read, including its failure, across task restarts.
@Observable
@MainActor
final class BrainAppContent {
    private(set) var brain: UIBrain?
    private(set) var unavailable: String?
    private(set) var isEmpty = false
    private(set) var list: BrainListView.Content?
    private var hasLoaded = false

    func load(bundleID: String, read: (String) async throws -> UIBrain?) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let loaded = try await read(bundleID)
            try Task.checkCancellation()
            guard let loaded else {
                isEmpty = true
                return
            }
            list = BrainListView.Content(brain: loaded)
            brain = loaded
        } catch is CancellationError {
            hasLoaded = false
        } catch {
            unavailable = MemoryService.describe(error)
        }
    }
}
