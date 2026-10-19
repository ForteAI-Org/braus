//
//  AdaptersSection.swift
//  Braus
//

import AppAdapters
import AppKit
import SwiftUI

/// AdaptersSection lists the apps workers reach through their own interfaces, without the seat
/// (`AppAdapters`): quiet when one can run, otherwise a short reason and an Allow button that asks
/// macOS for its permission. Only that button asks: reading the list never prompts. The list is
/// read again whenever the app comes back to the front, like `PermissionsSection`, since the
/// permissions are granted in System Settings.
struct AdaptersSection: View {

    /// Line is one adapter as the section lists it.
    private struct Line: Identifiable {
        let id          : String
        let name        : String
        let availability: AdapterAvailability
    }

    /// The adapters of this build, made once: each holds its store or transport.
    private static let adapters = AppAdapters.standard()

    @State private var lines: [Line] = []

    var body: some View {
        Section {
            ForEach(lines) { line in
                LabeledContent(line.name) {
                    state(of: line)
                }
            }
        } header: {
            Text("Apps")
        } footer: {
            Text("Workers use these apps in the background, through their own interfaces. Each Allow button asks macOS for that app's permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
    }

    @ViewBuilder
    private func state(of line: Line) -> some View {
        switch line.availability {
        case .ready:
            Label(
                "Ready",
                systemImage: "checkmark.circle.fill"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(.green)
            .help("Ready")
        case .needsPermission(let reason):
            askable(
                line,
                "Not allowed",
                reason: reason
            )
        case .unknown(let reason):
            askable(
                line,
                "Not known yet",
                reason: reason
            )
        case .unavailable(let reason):
            Text("Unavailable")
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }

    private func askable(
        _ line : Line,
        _ label: String,
        reason : String
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .help(reason)
            Button("Allow…") { allow(line) }
                .controlSize(.small)
        }
    }

    private func read() async {
        lines = await Self.adapters.listing().map { listed in
            Line(
                id          : listed.adapter.name,
                name        : listed.adapter.appNames.first ?? listed.adapter.name,
                availability: listed.availability
            )
        }
    }

    /// Asks for this one adapter's permission, its system prompt when the person has not answered yet.
    private func allow(_ line: Line) {
        Task {
            _ = await Self.adapters.requestPermissions(for: line.id)
            await read()
        }
    }
}
