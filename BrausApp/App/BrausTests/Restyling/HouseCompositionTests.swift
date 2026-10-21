//
//  HouseCompositionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import ChatCore
import ModelTransports
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseComposition")
@MainActor
struct HouseCompositionTests {

    // MARK: Composer

    @Test("The composer's model picker is the app's, offering the app's models and efforts for the mock provider")
    func composerPicker() throws {
        let team   = MockTeam()
        let worker = try Self.worker("Delivery")
        #expect(team.selection(of: worker).provider == .claudeCode)

        // What the app offers for a provider whose listing failed: its fixed models, with their efforts.
        for provider in [ModelProvider.claudeCode, .codex] {
            let app = try ProviderCatalog.resolvedCatalogue(
                .failure(ListingFailed()),
                for : provider,
                kept: nil
            )
            #expect(team.catalogue(for: provider) == app)
        }
        let opus = try #require(team.catalogue(for: .claudeCode).first { $0.id == "claude-opus-5-5" })
        #expect(opus.efforts == [.low, .medium, .high, .xhigh, .max])

        let composer = String(reflecting: HouseComposer.Body.self)
        #expect(composer.contains("ConversationModelButton"))
        #expect(composer.contains("ConversationModelPresenter"))
        #expect(!composer.contains("ConversationContextButton"))
    }

    @Test("A choice in the picker is the worker's, and another provider starts on the app's starting model")
    func choosingAModel() throws {
        let team   = MockTeam()
        let worker = try Self.worker("Design")
        let haiku  = ModelSelection(
            provider: .claudeCode,
            model   : "claude-haiku-4-5",
            effort  : .medium
        )
        team.select(
            haiku,
            for: worker
        )
        #expect(team.selection(of: worker) == haiku)
        #expect(team.selection(of: try Self.worker("Mixing")).model == "claude-haiku-4-5")

        team.changeProvider(
            of: worker,
            to: .codex
        )
        #expect(team.selection(of: worker) == ModelSelection(
            provider: .codex,
            model   : "gpt-5.6-luna",
            effort  : .medium
        ))
        // The context is the provider's, and nothing has run there yet.
        #expect(team.usage(of: worker).context == nil)
        #expect(!team.isAnswering(worker))
        #expect(team.isAnswering(try Self.worker("Delivery")))
    }

    // MARK: Toolbar

    @Test("The toolbar keeps its item identifiers across workers with the context ring in it")
    func toolbarStaysWithTheRing() async throws {
        let team    = MockTeam()
        let workers = MockHouse.sample.workers
        let choice  = Choice()
        choice.worker = workers[0]

        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 1100,
                height: 600
            ),
            styleMask  : [.titled, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DetailHost(
            choice: choice,
            team  : team
        ))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host

        let deadline = ContinuousClock.now + .seconds(2)
        while (window.toolbar?.items.count ?? 0) == 0 {
            try #require(ContinuousClock.now < deadline, "no toolbar appeared")
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let before = window.toolbar?.items.map(\.itemIdentifier) ?? []

        for worker in workers[1...3] + [workers[0]] {
            try #require(UsageWording.ringContext(of: team.usage(of: worker)) != nil, "\(worker.name) has no ring")
            choice.worker = worker
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.toolbar?.items.map(\.itemIdentifier) == before, "after showing \(worker.name)")
        }

        // With no worker there is no usage to show; it comes back in its place.
        choice.worker = nil
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        let empty = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(empty.count < before.count)
        #expect(empty.allSatisfy(before.contains))
        choice.worker = workers[0]
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        // The usage item comes back as a new item; the others are the ones they were.
        let back = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(back.count == before.count)
        #expect(empty.allSatisfy(back.contains))
    }

    // MARK: Usage

    @Test("The counter counts new tokens only, and the ring hides while the context's size is unknown")
    func counterAndRing() throws {
        let team     = MockTeam()
        let delivery = team.usage(of: try Self.worker("Delivery"))
        let lifetime = delivery.lifetime
        #expect(UsageWording.counter(of: delivery) == lifetime.input - lifetime.cacheReads + lifetime.output)
        #expect(lifetime.cacheReads > 0)
        #expect(UsageWording.ringContext(of: delivery)?.fraction == 0.34)

        // After a fresh context, and for a worker that has recorded no turn yet.
        let ptAgent = team.usage(of: try Self.worker("PT Agent"))
        #expect(UsageWording.ringContext(of: ptAgent) == nil)
        #expect(UsageWording.counter(of: ptAgent) != nil)
        let newcomer = HouseWorker(
            id        : UUID(),
            name      : "Newcomer",
            status    : .free,
            activity  : "Settles in",
            role      : "Helps out",
            category  : .general,
            shape     : .circle,
            badge     : nil,
            usesScreen: false
        )
        #expect(UsageWording.counter(of: team.usage(of: newcomer)) == nil)
    }

    @Test("A context at 90% compacts on its own to a tenth, counting the compaction's tokens but no message")
    func compaction() async throws {
        let team = MockTeam()
        team.compactionDuration = .zero
        let mastering = try Self.worker("Mastering")
        let before    = team.usage(of: mastering)
        #expect(before.context?.fraction == 0.91)

        team.compactIfFull(mastering)
        #expect(team.isCompacting(mastering))
        try await Self.waitUntil { !team.isCompacting(mastering) }
        let after = team.usage(of: mastering)
        #expect(after.context?.tokens == 18_200)
        #expect(after.turns == before.turns)
        #expect(UsageWording.counter(of: after) == (UsageWording.counter(of: before) ?? 0) + 18_200)

        // Below 90%, and while the worker answers, nothing compacts.
        let design = try Self.worker("Design")
        team.compactIfFull(design)
        #expect(!team.isCompacting(design))
        let render = try Self.worker("Render")
        team.compact(render)
        #expect(!team.isCompacting(render))

        // A fresh context forgets the size until the next turn.
        team.startFresh(design)
        #expect(team.usage(of: design).context == nil)
    }

    // MARK: Inspector

    @Test("The inspector stands on the sections of the app's own inspector")
    func inspectorSections() {
        let inspector = String(reflecting: HouseInspector.Body.self)
        let sections = [
            "HouseNowSection",
            "HouseScreenSection",
            "HouseModelSection",
            "HouseWebSection",
            "InspectorTurnSection",
        ]
        for section in sections {
            #expect(inspector.contains(section))
        }
    }

    @Test("A check of a connection runs, then finds a key-based provider without its key")
    func connectionCheck() async throws {
        let team = MockTeam()
        team.checkDuration = .zero
        #expect(team.readyConnections == 3)
        #expect(team.connectionStates[.gemini] == nil)

        team.check(.gemini)
        #expect(team.checking.contains(.gemini))
        try await Self.waitUntil { !team.checking.contains(.gemini) }
        #expect(team.connectionStates[.gemini] == .credentialMissing)
        #expect(team.readyConnections == 3)
        #expect(HouseModelSection.access(.claudeCode) == "Subscription · Claude Code")
        #expect(HouseModelSection.access(.anthropic) == "API Key")
    }

    // MARK: Helpers

    /// ListingFailed is a listing that failed for a reason the connection does not explain.
    private struct ListingFailed: Error {}

    /// Choice is the worker a test's detail column shows.
    @Observable
    final class Choice {
        var worker: HouseWorker?
    }

    /// DetailHost is the house window's split with its detail column and the house's toolbar.
    private struct DetailHost: View {
        let choice: Choice
        let team  : MockTeam

        @FocusState private var isFocused: Bool

        var body: some View {
            NavigationSplitView {
                Color.clear
            } detail: {
                HouseDetail(
                    worker           : choice.worker,
                    isComposerFocused: $isFocused
                )
                .toolbar {
                    HouseToolbar(
                        worker              : choice.worker,
                        team                : team,
                        isInspectorRequested: false,
                        toggleInspector     : {},
                        showsScreen         : .constant(true)
                    )
                }
            }
            .environment(team)
        }
    }

    private static func worker(_ name: String) throws -> HouseWorker {
        try #require(MockHouse.sample.workers.first { $0.name == name })
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "the condition never held")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
