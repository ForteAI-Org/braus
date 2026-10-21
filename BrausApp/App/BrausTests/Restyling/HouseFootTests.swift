//
//  HouseFootTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseFoot")
@MainActor
struct HouseFootTests {

    @Test("The account is a menu that holds Settings and Sign Out")
    func accountMenu() {
        #expect(HouseFoot.AccountButton.Action.allCases.map(\.title) == ["Settings…", "Sign Out"])
        #expect(String(reflecting: HouseFoot.AccountButton.Body.self).contains("SwiftUI.Menu<"))
        #expect(MockAccount.sample.monogram == "ER")
    }

    @Test("The foot holds the account alone; the archive is not in it")
    func accountAlone() {
        let foot = String(reflecting: HouseFoot.Body.self)
        #expect(foot.contains("AccountButton"))
        #expect(!foot.contains("Archive"))
    }

    @Test("The archive is a button in the sidebar's toolbar, beside New Worker, that names its count")
    func archiveInSidebarToolbar() async throws {
        #expect(HouseArchiveButton.spokenLabel(archivedCount: 3) == "Archive, 3 workers")
        #expect(String(reflecting: HouseArchiveButton.Body.self).contains("SwiftUI.Button<"))

        let (window, _) = try await Self.sidebarWindow(house: .sample)
        defer { window.close() }
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
        var house = MockHouse.sample
        house.archivedCount = 0
        let (window, _) = try await Self.sidebarWindow(house: house)
        defer { window.close() }
        let labels = window.toolbar?.items.map(\.label) ?? []
        #expect(labels.contains("New Worker"))
        #expect(!labels.contains("Archive"))
    }

    @Test("The sidebar's toolbar keeps its items when the selection changes")
    func toolbarStaysAcrossSelection() async throws {
        let (window, choice) = try await Self.sidebarWindow(house: .sample)
        defer { window.close() }
        let before  = window.toolbar?.items.map(\.itemIdentifier) ?? []
        let workers = MockHouse.sample.workers
        for worker in workers[0...3].map(\.id) + [nil, workers[0].id] {
            choice.worker = worker
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.toolbar?.items.map(\.itemIdentifier) == before)
        }
    }

    /// A window with the house's split, its sidebar showing `house`, once its toolbar has items.
    private static func sidebarWindow(house: MockHouse) async throws -> (NSWindow, Choice) {
        let choice = Choice()
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
        let host = NSHostingView(rootView: SidebarHost(
            house : house,
            choice: choice
        ))
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
        return (window, choice)
    }

    /// Choice is the worker a test's sidebar selects.
    @Observable
    final class Choice {
        var worker: HouseWorker.ID?
    }

    /// SidebarHost is the house window's split with the house's sidebar and New Worker beside it.
    private struct SidebarHost: View {
        let house: MockHouse

        @Bindable var choice: Choice

        var body: some View {
            NavigationSplitView {
                HouseSidebar(
                    house    : house,
                    selection: $choice.worker
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
