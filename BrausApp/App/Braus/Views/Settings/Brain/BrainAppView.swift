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
    @State private var refreshRevision = 0
    @State private var showHistorical = false
    @State private var layoutFailure: String?

    var body: some View {
        Group {
            if let unavailable = content.unavailable ?? layoutFailure {
                ContentUnavailableView(
                    String(localized: "Brain Unavailable"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(localized: "The Brain's memory could not be read: \(unavailable)"))
                )
            } else if content.isEmpty {
                ContentUnavailableView(
                    String(localized: "No saved observations for this app"),
                    systemImage: "brain",
                    description: Text(String(localized: "The app has been encountered, but no observed states or relationships are saved here yet."))
                )
            } else if content.brain != nil {
                switch mode {
                    case .graph:
                        if let simulation, simulation.graph.nodes.isEmpty {
                            ContentUnavailableView(
                                String(localized: "No observed layouts yet"), systemImage: "brain",
                                description: Text(String(localized: "Use the list to inspect the saved relationship evidence."))
                            )
                        } else if let simulation {
                            BrainGraphView(simulation: simulation)
                                .id(ObjectIdentifier(simulation))
                                .scrollContentBackground(.hidden)
                                .background { Color.houseGround.ignoresSafeArea() }

                        } else {
                            ProgressView()
                        }

                    case .list:
                        if let stored = content.stored, stored.hasObservations, !showHistorical {
                            BrainStoredListView(brain: stored)
                        } else if let list = content.list {
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
        .clipped()
        .toolbarBackground(Color.houseGround, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            if let stored = content.stored, stored.hasObservations,
               !stored.projection.objects.isEmpty || !stored.projection.transitions.isEmpty {
                ToolbarItem {
                    Toggle(String(localized: "Historical naming projection"), isOn: $showHistorical)
                }
            }
            ToolbarItem {
                Button { refreshRevision += 1 } label: {
                    Label(String(localized: "Refresh knowledge"), systemImage: "arrow.clockwise")
                }
            }
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
        .task(id: refreshRevision) {
            content.reset()
            simulation = nil
            await content.loadStored(bundleID: app.bundleID) { bundleID in
                try await MemoryService.shared(for: directory).storedBrain(of: bundleID)
            }
        }
        .task(id: "\(refreshRevision)-\(showHistorical)-\(content.stored != nil)") {
            simulation = nil
            layoutFailure = nil
            guard let stored = content.stored else { return }
            let graph = showHistorical ? BrainGraph(brain: stored.projection) : BrainGraph(stored: stored)
            do {
                let settled = try await BrainSimulation.settled(graph)
                try Task.checkCancellation()
                simulation = settled
            } catch is CancellationError {
                // A newer snapshot or leaving the page cancels the layout without publishing it.
            } catch {
                layoutFailure = MemoryService.describe(error)
            }
        }
    }
}

/// BrainAppContent keeps one detail page's read, including its failure, across task restarts.
@Observable
@MainActor
final class BrainAppContent {
    private(set) var stored: StoredBrain?
    private(set) var brain: UIBrain?
    private(set) var unavailable: String?
    private(set) var isEmpty = false
    private(set) var list: BrainListView.Content?
    private var hasLoaded = false
    private var generation = 0

    /// Invalidates the display snapshot only; rereading never writes knowledge.
    func reset() {
        generation += 1
        hasLoaded = false
        stored = nil
        brain = nil
        list = nil
        isEmpty = false
        unavailable = nil
    }

    func load(bundleID: String, read: (String) async throws -> UIBrain?) async {
        await loadStored(bundleID: bundleID) { id in
            try await read(id).map { StoredBrain(bundleID: id, projection: $0) }
        }
    }

    func loadStored(bundleID: String, read: (String) async throws -> StoredBrain?) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        let readingGeneration = generation
        do {
            let loaded = try await read(bundleID)
            try Task.checkCancellation()
            guard readingGeneration == generation else { return }
            guard let loaded else {
                isEmpty = true
                return
            }
            stored = loaded
            isEmpty = loaded.isEmpty
            list = BrainListView.Content(brain: loaded.projection)
            brain = loaded.projection
        } catch is CancellationError {
            if readingGeneration == generation { hasLoaded = false }
        } catch {
            if readingGeneration == generation { unavailable = MemoryService.describe(error) }
        }
    }
}
