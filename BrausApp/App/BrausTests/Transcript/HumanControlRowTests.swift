//
//  HumanControlRowTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import Foundation
import ModelTransports
import Testing
@testable import Braus

/// The summary sent when the person hands an application back is the worker's
/// turn input, drawn as one quiet row and never as the person's bubble.
@Suite("Hand-back row in the transcript")
struct HumanControlRowTests {

    static let summary = "Human control ended.\nclicked New Track\nFinal state: Stereo track"

    /// Asks, a stopped turn, the hidden summary at 10 and the worker's answer to it at 12.
    private static func handBack(_ fixture: TranscriptFixture) async throws {
        let (stopped, resumed) = (UUID(), UUID())
        try await fixture.say(
            "Create a stereo track.",
            at: 0
        )
        try await fixture.record(
            .executionStarted,
            subject: stopped,
            at     : 1
        )
        try await fixture.record(
            .executionCancelled,
            subject: stopped,
            at     : 2,
            text   : "The person took control."
        )
        try await fixture.store.appendMessage(
            to              : fixture.conversation,
            text            : summary,
            at              : TranscriptFixture.at(10),
            delivery        : .completed,
            endsHumanControl: true
        )
        try await fixture.record(
            .executionStarted,
            subject: resumed,
            at     : 11
        )
        try await fixture.say(
            "You created the stereo track, so the task is done.",
            at      : 12,
            byWorker: true
        )
        try await fixture.record(
            .executionCompleted,
            subject: resumed,
            at     : 13
        )
    }

    /// A turn that the person took over at 3, after one tool call, as the recorder writes it.
    private static func takeOver(_ fixture: TranscriptFixture) async throws {
        let turn = UUID()
        try await fixture.say(
            "Create a stereo track.",
            at: 0
        )
        try await fixture.record(
            .executionStarted,
            subject: turn,
            at     : 1
        )
        try await fixture.record(
            .toolActivity,
            subject: turn,
            at     : 2,
            text   : "→ open_session {\"app\":\"Pro Tools\"}"
        )
        try await fixture.record(
            .executionHandedToPerson,
            subject: turn,
            at     : 3
        )
    }

    private static func isHandBack(_ item: TranscriptItem) -> Bool {
        if case .humanControlFinished = item.kind { true } else { false }
    }

    private static func kinds(_ items: [TranscriptItem]) -> [String] {
        TranscriptFixture.withoutDays(items).map { item in
            switch item.kind {
            case .personMessage(_, _, let badge): badge == nil ? "person" : "person!"
            case .workerReply:                    "reply"
            case .toolRun:                        "tools"
            case .humanControl:                   "wave"
            case .humanControlFinished:           "finished"
            case .humanControlStopped:            "stopped"
            default:                              "other"
            }
        }
    }

    @Test func whileThePersonUsesTheAppTheWaveFollowsTheMessageWithNoErrorOrStop() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.takeOver(fixture)

        let window = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : fixture.store,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let items = ConversationProjection.items(
            messages         : window.messages,
            events           : window.events,
            expanded         : [],
            now              : TranscriptFixture.at(100_000),
            calendar         : TranscriptFixture.calendar(),
            isHumanControlled: true
        )
        #expect(Self.kinds(items) == ["person", "tools", "wave"])
        let wave = try #require(items.last)
        #expect(wave.id == .humanControl && wave.authorWorkerID == nil)
        #expect(RowGeometry.shape(of: wave.kind) == .divider, "never a bubble")
        #expect(RowPreparation.preparedText(
            for       : wave,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        ).string == "Human Interaction")
        #expect(TranscriptWording.accessibilityLabel(
            for       : wave,
            workerName: "Atlas"
        ) == "Human Interaction")
        if case .toolRun(_, _, let ending) = items[items.count - 2].kind {
            #expect(ending == .handedToPerson)
        } else {
            Issue.record("the tool line sits above the wave")
        }
        #expect(RunningTurn(items) == nil, "no thinking bubble while the person works")
    }

    @Test func endControlLeavesNoWaveNoErrorAndNoStopEvenAfterReload() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.takeOver(fixture)

        #expect(Self.kinds(try await fixture.items()) == ["person", "tools"])
        let reopened = try WorkspaceStore.opening(in: fixture.directory)
        let window   = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : reopened,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let items = ConversationProjection.items(
            messages: window.messages,
            events  : window.events,
            expanded: [],
            now     : TranscriptFixture.at(100_000),
            calendar: TranscriptFixture.calendar()
        )
        #expect(Self.kinds(items) == ["person", "tools"])
    }

    @Test func endControlTurnsTheWaveIntoOneStoppedRowThatReloads() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.takeOver(fixture)
        try await fixture.record(
            .humanControlStopped,
            subject: fixture.conversation,
            at     : 10
        )
        // The control may still read as active for a moment after the row lands.
        let window = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : fixture.store,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let landing = ConversationProjection.items(
            messages         : window.messages,
            events           : window.events,
            expanded         : [],
            now              : TranscriptFixture.at(100_000),
            calendar         : TranscriptFixture.calendar(),
            isHumanControlled: true
        )
        #expect(Self.kinds(landing) == ["person", "tools", "stopped"])

        let reopened = try WorkspaceStore.opening(in: fixture.directory)
        let again    = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : reopened,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let items = ConversationProjection.items(
            messages: again.messages,
            events  : again.events,
            expanded: [],
            now     : TranscriptFixture.at(100_000),
            calendar: TranscriptFixture.calendar()
        )
        #expect(Self.kinds(items) == ["person", "tools", "stopped"])
        #expect(again.messages.count == 1, "nothing is sent to the worker")
        let row = try #require(items.last)
        #expect(row.messageID == nil, "not selectable or quotable as a message")
        #expect(row.authorWorkerID == nil && row.isSeparator)
        #expect(row.date == TranscriptFixture.at(10))
        #expect(RowGeometry.shape(of: row.kind) == .divider, "never a bubble")
        #expect(RowPreparation.preparedText(
            for       : row,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        ).string == "Task Stopped")
        #expect(TranscriptWording.accessibilityLabel(
            for       : row,
            workerName: "Atlas"
        ) == "Task Stopped")
        #expect(row.copyText == "Task Stopped")
    }

    @Test func yesTurnsTheWaveIntoTheFinishedRowThenTheAnswer() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.takeOver(fixture)
        try await fixture.store.appendMessage(
            to              : fixture.conversation,
            text            : Self.summary,
            at              : TranscriptFixture.at(10),
            endsHumanControl: true
        )
        // The control may still read as active for a moment after the summary lands.
        let window = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : fixture.store,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let landing = ConversationProjection.items(
            messages         : window.messages,
            events           : window.events,
            expanded         : [],
            now              : TranscriptFixture.at(100_000),
            calendar         : TranscriptFixture.calendar(),
            isHumanControlled: true
        )
        #expect(Self.kinds(landing) == ["person", "tools", "finished"])

        let resumed = UUID()
        try await fixture.record(
            .executionStarted,
            subject: resumed,
            at     : 11
        )
        try await fixture.say(
            "You created the stereo track, so the task is done.",
            at      : 12,
            byWorker: true
        )
        try await fixture.record(
            .executionCompleted,
            subject: resumed,
            at     : 13
        )
        #expect(Self.kinds(try await fixture.items()) == ["person", "tools", "finished", "reply"])
    }

    @Test func theSummaryIsOneQuietRowFollowedByTheAnswer() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.handBack(fixture)

        let items = TranscriptFixture.withoutDays(try await fixture.items())
        let rows  = items.filter(Self.isHandBack)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(!items.contains { $0.copyText.contains("clicked New Track") }, "a folded row never draws the summary")
        #expect(items.filter { if case .personMessage = $0.kind { true } else { false } }.count == 1)
        #expect(row.messageID == nil, "not selectable or quotable as a message")
        #expect(row.authorWorkerID == nil && row.isSeparator)
        #expect(row.date == TranscriptFixture.at(10))
        let index = try #require(items.firstIndex(of: row))
        if case .workerReply = items[index + 1].kind {} else { Issue.record("the answer follows the row") }

        let text = RowPreparation.preparedText(
            for       : row,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        )
        #expect(text.string == "Finished Human Interaction")
        #expect(TranscriptWording.accessibilityLabel(
            for       : row,
            workerName: "Atlas"
        ) == "Finished Human Interaction")
        #expect(row.copyText == "Finished Human Interaction")
        #expect(RowGeometry.shape(of: row.kind) == .divider, "never a bubble")
    }

    @Test func aReopenedStoreDrawsTheSameRows() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.handBack(fixture)
        let before = try await fixture.items()

        let reopened = try WorkspaceStore.opening(in: fixture.directory)
        let window   = try await TranscriptWindow.opening(
            fixture.conversation,
            around    : nil,
            from      : reopened,
            eventLimit: TranscriptWindow.defaultEventLimit
        )
        let after = ConversationProjection.items(
            messages: window.messages,
            events  : window.events,
            expanded: [],
            now     : TranscriptFixture.at(100_000),
            calendar: TranscriptFixture.calendar()
        )
        #expect(after == before)
        #expect(after.filter(Self.isHandBack).count == 1)
        #expect(window.messages.filter(\.endsHumanControl).map(\.text) == [Self.summary])
    }

    @MainActor
    @Test func aLaterTurnsHistoryHoldsTheSummaryOnceAsWhatTheWorkerReceived() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.handBack(fixture)
        try await fixture.say(
            "Now add a mono track.",
            at: 20
        )

        let messages = try await fixture.store.messages(in: fixture.conversation)
        let history  = TeamModel.turnHistory(
            Array(messages.dropLast()),
            by: fixture.workerID
        )
        #expect(history.filter { $0.text == Self.summary }.count == 1)
        #expect(history.first { $0.text == Self.summary }?.role == .user)
        #expect(history.map(\.role) == [.user, .user, .assistant])
    }

    /// The hand-back row of a summary sent as `text`, read from the store folded, then opened.
    private static func handBackRows(_ text: String) async throws -> (folded: TranscriptItem, open: TranscriptItem) {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.takeOver(fixture)
        try await fixture.store.appendMessage(
            to              : fixture.conversation,
            text            : text,
            at              : TranscriptFixture.at(10),
            endsHumanControl: true
        )
        let folded = try #require(try await fixture.items().first(where: Self.isHandBack))
        let open   = try #require(try await fixture.items(expanded: [folded.id]).first(where: Self.isHandBack))
        return (folded, open)
    }

    @Test func aReportMakesTheRowOpenFoldedFirstThenShowsItLineByLine() async throws {
        let report = "Pro Tools — Edit: Mix Session\nDelete: − Track 3.\n2× ⌘S: performed, not verified."
        let (folded, open) = try await Self.handBackRows(report)
        #expect(folded.disclosure == false, "expandable, and folded by default")
        let closed = RowPreparation.preparedText(
            for       : folded,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        )
        #expect(closed.string == "Finished Human Interaction")
        #expect(closed.blocks.map(\.kind) == [.toolSummary])

        #expect(open.id == folded.id && open.disclosure == true)
        let text = RowPreparation.preparedText(
            for       : open,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        )
        #expect(text.blocks.map(\.kind) == [.toolSummary, .report])
        #expect(text.blocks[1].string.components(separatedBy: "\n").count == 3)
        #expect(text.blocks[1].string == report)
        #expect(open.copyText == "Finished Human Interaction\n" + report)
        #expect(RowGeometry.shape(of: open.kind) == .divider, "never a bubble")

        let rows = await RowPreparation.prepare(
            [folded, open],
            workerName: "Atlas",
            width     : 600,
            style     : TranscriptStyle(),
            cache     : LayoutMeasurementCache(),
            pipeline  : MarkdownContent()
        ).rows
        let (shut, opened) = (rows[0].geometry, rows[1].geometry)
        #expect(opened.text == shut.text, "the label stays where it was")
        #expect(opened.blocks[1].minY > opened.text.maxY && opened.height > shut.height)
        #expect(opened.height >= opened.blocks[1].maxY)
    }

    @Test func noChangesIsStillAReportTheRowShowsOnceOpened() async throws {
        let open = try await Self.handBackRows("No changes made.").open
        #expect(open.disclosure == true)
        let text = RowPreparation.preparedText(
            for       : open,
            workerName: "Atlas",
            pipeline  : MarkdownContent()
        )
        #expect(text.blocks.last?.string == "No changes made.")
    }

    @Test func withoutAReportTheRowNeverOpens() async throws {
        for summary in ["", "Human control ended. Recording is incomplete; inspect the current state.\n"] {
            let row = try await Self.handBackRows(summary).open
            #expect(row.disclosure == nil, "not expandable")
            let text = RowPreparation.preparedText(
                for       : row,
                workerName: "Atlas",
                pipeline  : MarkdownContent()
            )
            #expect(text.string == "Finished Human Interaction")
            #expect(text.blocks.map(\.kind) == [.text])
            #expect(row.copyText == "Finished Human Interaction")
        }
    }

    @MainActor
    @Test func theKeyboardReachesTheRowAndReturnOpensAndFoldsIt() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await Self.handBack(fixture)
        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(
            x     : 0,
            y     : 0,
            width : 600,
            height: 500
        )
        controller.view.layoutSubtreeIfNeeded()
        controller.open(
            fixture.conversation,
            workerName   : "Atlas",
            appearance   : TranscriptFixture.appearance,
            readingAnchor: nil,
            readingOffset: 0
        )
        await controller.settle()
        func press(_ codes: [UInt16]) throws {
            for code in codes {
                let event = try #require(NSEvent.keyEvent(
                    with                       : .keyDown,
                    location                   : .zero,
                    modifierFlags              : [],
                    timestamp                  : 0,
                    windowNumber               : 0,
                    context                    : nil,
                    characters                 : "",
                    charactersIgnoringModifiers: "",
                    isARepeat                  : false,
                    keyCode                    : code
                ))
                controller.collectionView.keyDown(with: event)
            }
        }
        func row() throws -> TranscriptItem {
            try #require(controller.rows.map(\.item).first(where: Self.isHandBack))
        }
        #expect(try row().disclosure == false)

        func focused() -> TranscriptItem.ID? {
            controller.collectionView.selectionIndexPaths.first.map { controller.rows[$0.item].item.id }
        }

        // Up from the answer lands on the row, which a plain separator would let the keyboard pass.
        try press([126, 126, 36])
        await controller.settle()
        #expect(try row().disclosure == true)
        #expect(try focused() == row().id, "the opened row keeps the keyboard")

        // Return again folds it, the row still focused.
        try press([36])
        await controller.settle()
        #expect(try row().disclosure == false)
        #expect(try focused() == row().id, "the folded row keeps the keyboard")
    }
}
