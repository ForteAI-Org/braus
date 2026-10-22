//
//  HouseTranscriptTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import Foundation
import Testing
@testable import Braus

/// The app's own transcript: its column and bubbles, a new reply's words arriving, and the thinking
/// bubble springing in. Offscreen windows only, never ordered in.
@MainActor
@Suite("The transcript's column", .serialized)
struct HouseTranscriptTests {

    private static let house = TranscriptStyle()

    @Test("Bubbles stand in a centred column with the tight corner toward their author")
    func bubblesInTheColumn() {
        let person = TranscriptItem(
            id            : .message(UUID()),
            kind          : .personMessage(text: "Export the stems.", delivery: .completed, badge: nil),
            date          : .now,
            authorWorkerID: nil,
            continuesGroup: false,
            endsGroup     : true
        )
        let worker = TranscriptItem(
            id            : .message(UUID()),
            kind          : .workerReply(text: "Done.", isInterrupted: false),
            date          : .now,
            authorWorkerID: UUID(),
            continuesGroup: false,
            endsGroup     : true
        )
        let size = [CGSize(width: 120, height: 17)]
        let mine = RowGeometry(item: person, rowWidth: 900, style: Self.house, blocks: [.text], sizes: size)
        let its  = RowGeometry(item: worker, rowWidth: 900, style: Self.house, blocks: [.text], sizes: size)
        #expect(mine.surface.maxX == 730, "the column is 560 points, centred in 900")
        #expect(its.surface.minX == 170)
        #expect(mine.surface.size == CGSize(width: 152, height: 39), "16 points across and 11 down around the text")
        #expect(its.text.origin == CGPoint(x: 186, y: 11))

        let narrow = RowGeometry(item: worker, rowWidth: 400, style: Self.house, blocks: [.text], sizes: size)
        #expect(narrow.surface.minX == 24, "a narrow window keeps 24 points beside the column")
    }

    @Test("A new reply's words fade in one after another; history and Reduce Motion show at once")
    func newReplyWordsArrive() async throws {
        RestylingMotion.overrideReducesMotion = false
        defer { RestylingMotion.overrideReducesMotion = nil }
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Export the stems.", at: 0)
        try await fixture.say("An older reply, which is history.", at: 10, byWorker: true)
        let (controller, window) = try await Self.opened(Self.house, over: fixture.store, fixture: fixture)
        defer { window.close() }
        #expect(Self.reveals(in: controller).isEmpty, "history never plays")

        let reply = try await fixture.say("Done: twelve stems are in Delivery.", at: 20, byWorker: true)
        controller.refresh()
        await controller.settle()

        let row    = try #require(Self.cell(of: reply.id, in: controller)).rowView
        let reveal = try #require(row.subviews.compactMap { $0 as? WordReveal }.first)
        let words  = reveal.layer?.sublayers ?? []
        #expect(words.count == 6)
        let begins = words.compactMap { $0.animation(forKey: "arrival")?.beginTime }
        #expect(begins.count == 6)
        for (earlier, later) in zip(begins, begins.dropFirst()) {
            #expect(abs(later - earlier - RestylingTiming.wordStagger) < 0.001, "each word 45 ms after the one before")
        }
        try await Self.wait { !row.subviews.contains { $0 is WordReveal } }

        RestylingMotion.overrideReducesMotion = true
        let quiet = try await fixture.say("And the mix too.", at: 30, byWorker: true)
        controller.refresh()
        await controller.settle()
        let still = try #require(Self.cell(of: quiet.id, in: controller)).rowView
        #expect(!still.subviews.contains { $0 is WordReveal }, "Reduce Motion shows the words at once")
    }

    @Test("A reply that grows fades in only its new words")
    func growingReplyRevealsTheNewWords() async throws {
        RestylingMotion.overrideReducesMotion = false
        defer { RestylingMotion.overrideReducesMotion = nil }
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Show me the build steps.", at: 0)
        let message = try await fixture.say("", at: 2, byWorker: true, delivery: .responding)
        let source  = GrowingSource(store: fixture.store, streaming: message.id, text: "First steps")
        let (controller, window) = try await Self.opened(Self.house, over: source, fixture: fixture)
        defer { window.close() }
        #expect(Self.reveals(in: controller).isEmpty)

        await source.append(" and then more")
        controller.refresh()
        await controller.settle()

        let row    = try #require(Self.cell(of: message.id, in: controller)).rowView
        let reveal = try #require(row.subviews.compactMap { $0 as? WordReveal }.first)
        #expect(reveal.layer?.sublayers?.count == 3, "and, then, more")
    }

    @Test("The thinking bubble springs in from its bottom leading corner")
    func thinkingSpringsIn() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Export the stems.", at: 0)
        let (controller, window) = try await Self.opened(Self.house, over: fixture.store, fixture: fixture)
        defer { window.close() }
        try await fixture.record(.executionStarted, subject: UUID(), at: 1)
        controller.refresh()
        await controller.settle()

        let index = try #require(controller.rows.lastIndex { $0.item.kind == .thinking })
        let cell  = try #require(controller.collectionView.item(at: IndexPath(item: index, section: 0)))
        let entry = cell.view.layer?.animation(forKey: "entrance")
        #expect((entry as? CASpringAnimation)?.keyPath == "transform")
    }

    // MARK: Helpers

    private static func opened(
        _ style        : TranscriptStyle,
        over source    : any ConversationWindowSource,
        fixture        : TranscriptFixture
    ) async throws -> (TranscriptController, NSWindow) {
        let controller = TranscriptController(
            source: source,
            style : style
        )
        let window     = TranscriptFixture.offscreenWindow(
            for : controller.view,
            size: CGSize(width: 700, height: 600)
        )
        window.appearance = NSAppearance(named: .darkAqua)
        controller.open(
            fixture.conversation,
            workerName    : "Atlas",
            appearance    : TranscriptFixture.appearance,
            readingAnchor : nil,
            readingOffset : 0
        )
        await controller.settle()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private static func cell(
        of messageID : UUID,
        in controller: TranscriptController
    ) -> TranscriptCell? {
        guard let index = controller.rows.firstIndex(where: { $0.item.messageID == messageID }) else { return nil }

        return controller.collectionView.item(at: IndexPath(item: index, section: 0)) as? TranscriptCell
    }

    /// Every reveal playing over the transcript's rows on screen.
    private static func reveals(in controller: TranscriptController) -> [WordReveal] {
        controller.collectionView.indexPathsForVisibleItems().flatMap { path in
            (controller.collectionView.item(at: path) as? TranscriptCell)?.rowView.subviews
                .compactMap { $0 as? WordReveal } ?? []
        }
    }

    /// Waits until `condition` holds, five seconds at most.
    private static func wait(for condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
