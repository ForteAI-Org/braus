//
//  BrainSettings.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AutomationRuntime
import SwiftUI

/// BrainSettings is what the engine's Brain has learned, one application at a
/// time: the applications it knows, each of which pushes its own page with
/// the application's name as the title and the window's back button to come
/// back. The Brain is shared by every worker and the command line, so it is
/// the computer's and not a worker's. It is read, never changed, here.
struct BrainSettings: View {

    /// The knowledge directory the workers and the command line write.
    let directory: URL

    @State private var apps: [BrainAppSummary] = []
    @State private var unavailable: String?
    @State private var memory: MemoryService.Status?
    @State private var refreshRevision = 0
    @State private var isLoading = true
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                if isLoading, apps.isEmpty {
                    ProgressView()
                } else if let unavailable {
                    ContentUnavailableView(
                        String(localized: "Brain Unavailable"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(String(localized: "The Brain's memory could not be read: \(unavailable)"))
                    )
                } else if apps.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No App Knowledge Yet"),
                        systemImage: "brain",
                        description: Text(String(localized: "The Brain learns how an app works when a worker first uses it."))
                    )
                } else {
                    Section {
                        ForEach(apps) { app in
                            NavigationLink(value: app.bundleID) { BrainAppRow(app: app) }
                        }
                    } header: {
                        Text(String(localized: "Applications"))
                    } footer: {
                        Text(String(localized: "Workers and the Braus command-line tool share what the Brain learns."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let memory {
                    Section {
                        DisclosureGroup(String(localized: "Memory diagnostics"), isExpanded: $showDiagnostics) {
                            Text(Self.summary(of: memory))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } footer: {
                        Text(String(localized: "These write counters restart with Braus. They do not count all saved knowledge."))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { Color.houseSidebar.ignoresSafeArea() }
            .navigationTitle(String(localized: "Brain"))
            .toolbar {
                ToolbarItem {
                    Button { refreshRevision += 1 } label: {
                        Label(String(localized: "Refresh knowledge"), systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(for: String.self) { bundleID in
                if let app = apps.first(where: { $0.bundleID == bundleID }) { BrainAppView(app: app, directory: directory) }
            }
        }
        .task(id: refreshRevision) {
            isLoading = true
            let loaded = await BrainLibrary.apps(in: directory)
            guard !Task.isCancelled else { return }
            switch loaded {
                case .loaded(let loaded)    : apps = loaded; unavailable = nil
                case .unavailable(let why)  : apps = []; unavailable = why
            }
            memory = await MemoryService.shared(for: directory).status()
            isLoading = false
        }
    }

    /// The memory's state in two lines: the archive and the library, then this run's writes. The
    /// counts start at zero with each launch of Braus.
    static func summary(of status: MemoryService.Status) -> String {
        let state: String = switch status.state {
            case .notOpened         : String(localized: "not opened yet")
            case .open              : String(localized: "open")
            case .degraded(let why) : String(localized: "unavailable: \(why)")
            case .closed            : String(localized: "closed")
        }
        let version = status.libraryVersion ?? String(localized: "unknown")
        var lines = [String(localized: "Memory \(state) at \(status.path), SQLite \(version).")]
        lines.append(String(localized: "Since Braus started: \(status.written) saved, \(status.failed) failed, \(status.dropped) dropped, \(status.pending + status.inFlight) not yet saved."))
        if status.partial > 0 { lines[lines.count - 1] += String(localized: " \(status.partial) saved in part.") }
        if let copy = status.lastBackup {
            let date = copy.formatted(date: .abbreviated, time: .shortened)
            lines.append(String(localized: "Last copy: \(date)."))
        }
        if let recovery = status.lastRecovery { lines.append(recovery) }
        if let imported = status.lastImport { lines.append(imported.prefix(1).uppercased() + imported.dropFirst() + ".") }
        return lines.joined(separator: "\n")
    }
}
