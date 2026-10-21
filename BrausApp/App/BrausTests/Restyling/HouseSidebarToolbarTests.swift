//
//  HouseSidebarToolbarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

@Suite("The house sidebar's toolbar")
@MainActor
struct HouseSidebarToolbarTests {

    @Test("The archive is a button in the sidebar's toolbar, beside New Worker, that names its count")
    func archiveInSidebarToolbar() async throws {
        #expect(HouseArchiveButton.spokenLabel(archivedCount: 3) == "Archive, 3 workers")
        #expect(String(reflecting: HouseArchiveButton.Body.self).contains("SwiftUI.Button<"))

        let (window, _, directory) = try await Self.sidebarWindow(archived: 3)
        defer {
            window.close()
            TemporaryStore.discard(directory)
        }
        let items   = window.toolbar?.items ?? []
        let labels  = items.map(\.label)
        let archive = try #require(items.firstIndex { $0.label == "Archive" })
        #expect(items[archive].toolTip == "Archive · 3")
        #expect(labels.firstIndex(of: "New Worker") == archive - 1)
        // The sidebar's items come before the split's first separator, the detail's after it.
        let separator = try #require(items.firstIndex { $0.itemIdentifier.rawValue.contains("splitViewSeparator") })
        #expect(archive < separator)
    }

    @Test("The sidebar's toolbar has no archive when the archive is empty")
    func noArchiveWhenEmpty() async throws {
        let (window, _, directory) = try await Self.sidebarWindow(archived: 0)
        defer {
            window.close()
            TemporaryStore.discard(directory)
        }
        let labels = window.toolbar?.items.map(\.label) ?? []
        #expect(labels.contains("New Worker"))
        #expect(!labels.contains("Archive"))
    }

    @Test("The sidebar's toolbar keeps its items when the selection changes")
    func toolbarStaysAcrossSelection() async throws {
        let (window, choice, directory) = try await Self.sidebarWindow(archived: 3)
        defer {
            window.close()
            TemporaryStore.discard(directory)
        }
        let before  = window.toolbar?.items.map(\.itemIdentifier) ?? []
        let workers = HouseRoster.workers(of: choice.team)
        for worker in workers[0...3].map(\.id) + [nil, workers[0].id] {
            choice.worker = worker
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.toolbar?.items.map(\.itemIdentifier) == before)
        }
    }

    /// A window with the house's split, its sidebar showing a team of four workers and `archived`
    /// in the archive, once its toolbar has items, and the folder of the team's store.
    private static func sidebarWindow(archived: Int) async throws -> (NSWindow, Choice, URL) {
        let directory = TemporaryStore.directory()
        let store     = try WorkspaceStore.opening(in: directory)
        for index in 0..<(4 + archived) {
            let worker = try await store.createWorker(
                name      : "Worker \(index + 1)",
                appearance: TemporaryStore.appearance()
            )
            if index >= 4 {
                try await store.update(
                    worker: worker.id,
                    .archived(true)
                )
            }
        }
        let team = TeamModel(
            store      : store,
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        await team.load()
        let choice = Choice(team: team)
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 1000,
                height: 600
            ),
            styleMask  : [.titled, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarHost(choice: choice))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host

        let deadline = ContinuousClock.now + .seconds(2)
        while window.toolbar?.items.contains(where: { $0.label == "New Worker" }) != true {
            try #require(ContinuousClock.now < deadline, "no toolbar appeared")
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        // The items that follow New Worker are added in the same update.
        try await Task.sleep(for: .milliseconds(100))
        return (window, choice, directory)
    }

    /// Choice is the team a test's sidebar shows and the worker it selects.
    @Observable
    final class Choice {
        let team: TeamModel

        var worker: HouseWorker.ID?

        init(team: TeamModel) { self.team = team }
    }

    /// SidebarHost is the house window's split with the house's sidebar and New Worker beside it.
    private struct SidebarHost: View {
        @Bindable var choice: Choice

        var body: some View {
            NavigationSplitView {
                HouseSidebar(
                    workers  : HouseRoster.workers(of: choice.team),
                    selection: $choice.worker,
                    team     : choice.team
                )
                .toolbar {
                    ToolbarItem {
                        Button(
                            "New Worker",
                            systemImage: "plus"
                        ) {}
                    }
                }
            } detail: {
                Color.clear
            }
        }
    }
}
