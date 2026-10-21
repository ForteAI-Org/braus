//
//  HouseLiveToolbarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@MainActor
@Suite("The house's live toolbar")
struct HouseLiveToolbarTests {

    /// The window is never shown: it sits far off screen behind every other, and nothing is sent to it.
    @Test("The screen and inspector items keep their identities across workers and the empty choice")
    func identitiesAreStable() async throws {
        let directory = URL.temporaryDirectory.appending(
            path         : "HouseLiveToolbarTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let team      = try await WindowSnapshots.syntheticTeam(
            in           : directory,
            contextTokens: 142_318
        )
        var requested = true
        let window    = NSWindow(contentViewController: NSHostingController(
            rootView: HouseShellView(
                team                : team,
                isInspectorRequested: Binding(
                    get: { requested },
                    set: { requested = $0 }
                )
            )
        ))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setFrame(
            NSRect(x: -30_000, y: 0, width: 1200, height: 760),
            display: false
        )
        window.orderBack(nil)
        // Closing frees the hosted rooms' denoiser buckets, which the shared pool would keep.
        window.isReleasedWhenClosed = false
        defer {
            window.contentViewController = nil
            window.close()
        }

        func identifiers() async throws -> [String] {
            try await Task.sleep(for: .seconds(1.5))
            let items = window.toolbar?.items ?? []
            return items
                .filter { $0.label == "Show Screen in Conversation" || $0.label == "Hide Inspector" }
                .map { $0.itemIdentifier.rawValue }
        }

        let withUsage = try await identifiers()
        #expect(withUsage.count == 2)
        #expect(window.toolbar?.items.count == 7, "The usage capsule and its fixed space are present")

        team.selection = team.active.first { $0.name == "Nova" }?.id
        #expect(try await identifiers() == withUsage)
        #expect(window.toolbar?.items.count == 5, "A worker with no turn has no usage item")

        team.selection = nil
        #expect(try await identifiers() == withUsage)
    }
}
