//
//  TurnRowsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Braus

/// A turn's rows: no execution dividers, the thinking bubble derived from a
/// running execution, and the reply that takes its place.
@Suite("Turn rows: no dividers, the thinking bubble and its replacement")
struct TurnRowsTests {

    private static func isThinking(_ item: TranscriptItem) -> Bool { item.kind == .thinking }

    /// The person asks and the worker's turn starts, with one tool call so far.
    private func running(_ fixture: TranscriptFixture) async throws -> UUID {
        let turn = UUID()
        try await fixture.say("Open Calculator", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        try await fixture.record(.toolActivity, subject: turn, at: 2, text: "→ open_session {\"app\":\"Calculator\"}")
        return turn
    }

    @Test("A started and a completed turn draw no divider: only messages, the tool line and days")
    func noDividers() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn = try await running(fixture)
        try await fixture.say("Opened.", at: 3, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 4)

        let items = try await fixture.items()
        #expect(!items.contains { if case .event = $0.id { true } else { false } })
        #expect(!items.contains(where: Self.isThinking))
        let labels = items.map { TranscriptWording.accessibilityLabel(for: $0, workerName: "Atlas") }
        #expect(!labels.contains { $0.contains("started working") || $0.hasPrefix("Finished") })
        #expect(items.count == 4)
    }

    @Test("A running turn with no reply shows a thinking bubble where the reply will land, the tool line above it")
    func thinkingWhileRunning() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn  = try await running(fixture)
        let items = TranscriptFixture.withoutDays(try await fixture.items())

        #expect(items.count == 3)
        #expect(items[2].id == .thinking(execution: turn, replies: 0))
        #expect(items[2].authorWorkerID == fixture.workerID)
        #expect(!items[2].continuesGroup, "the bubble carries the worker's name and mascot")
        guard case .toolRun(_, _, let ending) = items[1].kind else {
            Issue.record("no tool line above the bubble")
            return
        }
        #expect(ending == nil)
        #expect(!items[1].continuesGroup, "the line opens the worker's part of the turn")
        #expect(TranscriptWording.header(for: items[2], workerName: "Atlas") == ("Atlas", ""))
    }

    @Test("The reply replaces the bubble in place: same position, the same row, nothing inserted")
    func replyReplacesBubble() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn   = try await running(fixture)
        let before = try await fixture.items()
        let bubble = try #require(before.firstIndex(where: Self.isThinking))

        let reply = try await fixture.say("Calculator is open.", at: 3, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 4)
        let after  = try await fixture.items()
        let update = TranscriptUpdate(from: before, to: after)

        #expect(after[bubble].id == .message(reply.id))
        #expect(update.replaced == [bubble])
        #expect(update.inserted.isEmpty && update.removed.isEmpty)
        #expect(update.changed.contains(.message(reply.id)))
    }

    @Test("Between steps a new bubble follows the reply, which still takes the old bubble's row")
    func bubbleBetweenSteps() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn   = try await running(fixture)
        let before = try await fixture.items()
        let bubble = try #require(before.firstIndex(where: Self.isThinking))

        let reply = try await fixture.say("Opening it now.", at: 3, byWorker: true)
        let after = try await fixture.items()
        let update = TranscriptUpdate(from: before, to: after)

        #expect(after[bubble].id == .message(reply.id))
        #expect(after[bubble + 1].id == .thinking(execution: turn, replies: 1))
        #expect(after[bubble + 1].continuesGroup)
        #expect(update.replaced == [bubble])
        #expect(update.inserted == [bubble + 1])
    }

    @Test("A reply still streaming hides the bubble: the reply is what is arriving")
    func streamingReplyHidesBubble() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await running(fixture)
        try await fixture.say("Opening", at: 3, byWorker: true, delivery: .responding)
        #expect(!(try await fixture.items()).contains(where: Self.isThinking))
    }

    @Test("The bubble goes when the turn is stopped or fails, and a window short of the newest shows none")
    func bubbleEnds() async throws {
        for ending in [EventType.executionCancelled, .executionFailed] {
            let fixture = try await TranscriptFixture()
            defer { fixture.discard() }
            let turn = try await running(fixture)
            #expect(try await fixture.items().contains(where: Self.isThinking))
            try await fixture.record(ending, subject: turn, at: 5, text: "reason")
            #expect(!(try await fixture.items()).contains(where: Self.isThinking))
        }

        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await running(fixture)
        let window = try await TranscriptWindow.opening(fixture.conversation, around: nil, from: fixture.store)
        let items  = ConversationProjection.items(messages: window.messages, events: window.events, expanded: [],
                                                  now: TranscriptFixture.at(100), isAtNewest: false)
        #expect(!items.contains(where: Self.isThinking))
    }

    @Test("The group's end adds only its time below, and moves no text")
    func groupEndAddsItsTime() {
        let item = TranscriptItem(
            id            : .message(UUID()),
            kind          : .workerReply(text: "Done.", isInterrupted: false),
            date          : TranscriptFixture.at(0),
            authorWorkerID: UUID(),
            continuesGroup: false,
            endsGroup     : true
        )
        var inside = item
        inside.endsGroup = false
        let size    = [CGSize(width: 120, height: 17)]
        let ending  = RowGeometry(item: item, rowWidth: 600, style: TranscriptStyle(), blocks: [.text], sizes: size)
        let within  = RowGeometry(item: inside, rowWidth: 600, style: TranscriptStyle(), blocks: [.text], sizes: size)
        #expect(ending.text == within.text && ending.surface == within.surface)
        #expect(within.footer == nil && (ending.footer?.minY ?? 0) > ending.surface.maxY)
    }

    @Test("A thinking row has no text, draws a bubble of one line, reads its worker's name and shows it only with authors")
    func thinkingRowPrepares() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await running(fixture)
        let items    = try await fixture.items()
        let prepared = await RowPreparation.prepare(items, workerName: "Atlas", width: 600, style: TranscriptStyle(),
                                                    cache: LayoutMeasurementCache(), pipeline: MarkdownContent())
        let row = try #require(prepared.rows.first { $0.item.kind == .thinking })
        #expect(row.text.blocks.isEmpty)
        // A direct conversation names its worker in the title bar, not on the bubble.
        #expect(row.geometry.avatar == nil && row.geometry.header == nil)
        let authored = RowGeometry(item: row.item, rowWidth: 600, style: TranscriptStyle(showsAuthors: true),
                                   blocks: [], sizes: [])
        #expect(authored.avatar != nil && authored.header != nil)
        #expect(row.geometry.text.size == RowGeometry.thinkingSize(TranscriptStyle()))
        #expect(row.geometry.text.width > row.geometry.text.height, "as wide as its bubble of thinking")
        #expect(TranscriptWording.accessibilityLabel(for: row.item, workerName: "Atlas") == "Atlas is preparing a response")
    }

    @Test("The thinking blob is the bubble's light grey")
    @MainActor
    func thinkingBlobIsLightGrey() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        _ = try await running(fixture)
        let items    = try await fixture.items()
        let prepared = await RowPreparation.prepare(items, workerName: "Atlas", width: 600, style: TranscriptStyle(),
                                                    cache: LayoutMeasurementCache(), pipeline: MarkdownContent())
        let row  = try #require(prepared.rows.first { $0.item.kind == .thinking })
        let view = TranscriptRowView()
        view.configure(row, style: TranscriptStyle(), workerName: "Atlas", avatar: nil, selection: nil)
        let blob = try #require(view.subviews.compactMap { $0 as? ThinkingBlobView }.first)
        #expect(blob.tint == NSColor(white: 0.92, alpha: 1))
    }
}
