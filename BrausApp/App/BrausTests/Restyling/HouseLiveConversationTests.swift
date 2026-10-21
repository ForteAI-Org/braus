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
@Suite("The new look's conversation over the team")
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

    @Test("The conversation shows the team's transcript under the hero, and its composer in the new look")
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
        #expect(field.lineLimit == ComposerBar.Chrome.house.maximumLines)

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
