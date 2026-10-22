//
//  HouseLiveConversationTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@MainActor
@Suite("The house's conversation over the team")
struct HouseLiveConversationTests {

    @Test("The hero listens while the person writes between turns, and shows its status otherwise")
    func brows() {
        for status in [WorkerStatus.free, .busy, .waiting, .off] {
            #expect(HouseLiveConversation.brows(
                status     : status,
                isAnswering: false,
                draft      : "Check the mix"
            ) == .listening)
            #expect(HouseLiveConversation.brows(
                status     : status,
                isAnswering: false,
                draft      : " \n "
            ) == BrowState(status))
            #expect(HouseLiveConversation.brows(
                status     : status,
                isAnswering: true,
                draft      : "Then the stems"
            ) == BrowState(status))
        }
    }

    @Test("The conversation shows the team's transcript under the hero, and its composer")
    func hostsTheTeamsConversation() async throws {
        let folder = URL.temporaryDirectory.appending(
            path         : "HouseLiveConversation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let team    = try await WindowSnapshots.syntheticTeam(in: folder)
        let worker  = try #require(team.selectedWorker)
        let hosting = NSHostingView(rootView: HouseLiveConversation(
            team  : team,
            worker: worker
        ))
        // Never ordered in: the conversation is laid out and drawn offscreen.
        let window = NSWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 700
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.appearance           = NSAppearance(named: .darkAqua)
        window.contentView          = hosting
        defer { window.close() }

        var rows = 0
        for _ in 0..<250 where rows == 0 {
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            if let transcript = Self.find(TranscriptCollectionView.self, in: hosting), transcript.numberOfSections > 0 {
                rows = transcript.numberOfItems(inSection: 0)
            }
        }
        #expect(rows > 0, "the transcript shows the conversation's messages")
        let field = try #require(Self.find(ComposerScrollView.self, in: hosting))
        #expect(field.textView.placeholder == "Message \(worker.name)")
        #expect(field.lineLimit == ComposerBar.maximumLines)

        guard ProcessInfo.processInfo.environment["BRAUS_SNAPSHOTS"] == "1" else { return }
        // Long enough for the hero to hop out of its capsule before the drawing.
        try await Task.sleep(for: .seconds(1))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap
        )
        let file = try ComposerSnapshotTests.directory.appending(path: "house-live-conversation.png")
        try #require(bitmap.representation(
            using     : .png,
            properties: [:]
        )).write(to: file)
        print("snapshot: \(file.path)")
    }

    @Test("The reply lands only for a turn that ends in the conversation shown")
    func landingNeedsTheShownConversation() {
        func lands(
            _ wasRunning: Bool,
            _ isRunning : Bool,
            reply       : Bool = true,
            shown       : Bool = true
        ) -> Bool {
            HouseLiveConversation.landsReply(
                wasRunning   : wasRunning,
                isRunning    : isRunning,
                endsWithReply: reply,
                isShown      : shown
            )
        }
        #expect(lands(true, false))
        #expect(!lands(true, true))
        #expect(!lands(false, false))
        #expect(!lands(false, true))
        #expect(!lands(true, false, reply: false))
        // Another worker's turn cleared while the leaving conversation is still drawn.
        #expect(!lands(true, false, shown: false))
    }

    @Test("Opening another conversation clears the running turn before it is shown")
    func switchingClearsTheTurnBeforeTheNewConversationIsShown() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say(
            "Export the stems",
            at: 0
        )
        let other = try await fixture.store.createConversation(participants: [fixture.workerID]).id
        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(
            x     : 0,
            y     : 0,
            width : 600,
            height: 500
        )
        controller.view.layoutSubtreeIfNeeded()
        func open(_ conversation: UUID) {
            controller.open(
                conversation,
                workerName   : "Atlas",
                appearance   : TranscriptFixture.appearance,
                readingAnchor: nil,
                readingOffset: 0
            )
        }
        open(fixture.conversation)
        await controller.settle()
        try await fixture.record(
            .executionStarted,
            subject: UUID(),
            at     : 1
        )
        controller.refresh()
        await controller.settle()
        #expect(controller.runningTurn != nil)
        #expect(controller.shownConversationID == fixture.conversation)

        // The window's `isArrivalOpen` is false here, so the cleared turn lands nothing.
        open(other)
        #expect(controller.runningTurn == nil)
        #expect(controller.shownConversationID == fixture.conversation)
        await controller.settle()
        #expect(controller.shownConversationID == other)
    }

    private static func find<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }
}
