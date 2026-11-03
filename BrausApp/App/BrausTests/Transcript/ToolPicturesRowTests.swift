//
//  ToolPicturesRowTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import Foundation
import Testing
@testable import Braus

/// A tool line's pictures: a block under its summary, laid out small side by side above their label,
/// back on the line when the conversation is opened again, and enlarged over the window on request.
@Suite("Tool pictures: shown under the tool line and enlarged")
struct ToolPicturesRowTests {

    private static func png(width: Int, height: Int, mark: Int = 0) throws -> Data {
        try ToolPicturesTests.png(width: width, height: height, mark: mark)
    }

    private static func canvasLines(before: Data, after: Data) throws -> [String] {
        try ToolPicturesTests.canvasLines(before: before, after: after)
    }

    @Test("The prepared line has a pictures block under its summary, the after picture alone and no text, before the opened card")
    func preparedBlocks() throws {
        let lines = try Self.canvasLines(before: try Self.png(width: 160, height: 60),
                                         after: try Self.png(width: 160, height: 60, mark: 9))
        let item  = TranscriptItem(id: .toolRun(UUID()), kind: .toolRun(lines: lines, isExpanded: true, ending: .completed),
                                   date: .now, authorWorkerID: UUID(), continuesGroup: false)
        let text  = RowPreparation.preparedText(for: item, workerName: "Atlas", pipeline: MarkdownContent())
        guard text.blocks.count == 3, case .pictures(let shown) = text.blocks[1].kind else {
            Issue.record("expected summary, pictures, card: \(text.blocks.map(\.kind))")
            return
        }
        #expect(text.blocks[0].kind == .toolSummary && text.blocks[2].kind == .toolSteps)
        #expect(text.blocks[1].string.isEmpty && shown.label == "Timeline · lane 2")
        #expect(shown.pictures.count == 1)
        #expect(RowAction.actions(in: text) == [.openPictures(block: 1)])
        #expect(TranscriptWording.action(.openPictures(block: 1), in: text) == "Open pictures of Timeline · lane 2")
    }

    @Test("Side by side, at most the box and twice the pixel size, reduced in a narrow row; the line shows one")
    func geometry() throws {
        let wide  = ToolPictures.Picture(data: Data(), width: 400, height: 100)
        let small = ToolPictures.Picture(data: Data(), width: 30, height: 20)
        let roomy = RowGeometry.pictureFrames([wide, small], width: 500)
        #expect(roomy == [CGRect(x: 0, y: 0, width: 200, height: 50), CGRect(x: 208, y: 0, width: 60, height: 40)])
        let tight = RowGeometry.pictureFrames([wide, wide], width: 208)
        #expect(tight.map(\.width) == [100, 100] && tight.last?.maxX == 208)

        let lines = try Self.canvasLines(before: try Self.png(width: 160, height: 60),
                                         after: try Self.png(width: 160, height: 60, mark: 9))
        let item  = TranscriptItem(id: .toolRun(UUID()), kind: .toolRun(lines: lines, isExpanded: false, ending: .completed),
                                   date: .now, authorWorkerID: UUID(), continuesGroup: false)
        let text  = RowPreparation.preparedText(for: item, workerName: "Atlas", pipeline: MarkdownContent())
        let style = TranscriptStyle()
        let sizes = text.blocks.map { RowPreparation.measure($0.attributed(style), width: 400) }
        let row   = RowGeometry(item: item, rowWidth: 700, style: style, blocks: text.blocks.map(\.kind), sizes: sizes)
        let shown = row.pictureFrames[1]
        #expect(shown.count == 1 && shown[0].minY == row.blocks[1].minY)
        #expect(row.blocks[1].width >= shown[0].width && row.blocks[1].maxY >= shown[0].maxY)
        #expect(row.height >= shown[0].maxY)
    }

    @Test("A reopened conversation draws the stored pictures on the tool line")
    @MainActor
    func reopened() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let before = try Self.png(width: 160, height: 60)
        let after  = try Self.png(width: 160, height: 60, mark: 100)
        let turn   = UUID()
        try await fixture.say("Move the clip on lane 2.", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        for (index, line) in try Self.canvasLines(before: before, after: after).enumerated() {
            try await fixture.record(.toolActivity, subject: turn, at: 2 + Double(index), text: line)
        }
        try await fixture.say("The clip moved right.", at: 6, byWorker: true)
        try await fixture.record(.executionCompleted, subject: turn, at: 7)

        let controller = TranscriptController(source: fixture.store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        let line  = try #require(controller.rows.first { if case .toolRun = $0.item.kind { true } else { false } })
        let shown = line.text.blocks.compactMap { block -> ToolPictures? in
            if case .pictures(let pictures) = block.kind { pictures } else { nil }
        }
        #expect(shown.map { $0.pictures.map(\.data) } == [[after]])
        #expect(line.geometry.pictureFrames[1].count == 1)
    }

    @Test("A click on the pictures in the transcript asks for them enlarged")
    @MainActor
    func clickEnlarges() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let turn = UUID()
        try await fixture.say("Move the clip on lane 2.", at: 0)
        try await fixture.record(.executionStarted, subject: turn, at: 1)
        let lines = try Self.canvasLines(before: try Self.png(width: 160, height: 60),
                                         after: try Self.png(width: 160, height: 60, mark: 100))
        for (index, line) in lines.enumerated() {
            try await fixture.record(.toolActivity, subject: turn, at: 2 + Double(index), text: line)
        }
        try await fixture.record(.executionCompleted, subject: turn, at: 7)

        let controller = TranscriptController(source: fixture.store)
        // On screen and key, as the conversation window is when a person clicks in it.
        let window     = TestInputWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 600),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView          = controller.view
        defer { window.close() }
        for _ in 0..<100 where !window.isKeyWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(window.isKeyWindow)
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        window.contentView?.layoutSubtreeIfNeeded()

        var opened: PicturesEnlargement?
        controller.onOpenPictures = { opened = $0 }
        func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let strip  = try #require(views(in: controller.view).compactMap { $0 as? ToolPicturesView }.first)
        let middle = strip.convert(NSPoint(x: strip.bounds.width / 4, y: strip.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(window.contentView!.convert(middle, from: nil)) === strip)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: TestInputWindow.clickNumber,
                                                        clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        #expect(opened?.opener === strip && opened?.images.count == 1)
    }

    @Test("A row shows its pictures in a view per block and gives them to enlarge, grown from the small ones")
    @MainActor
    func rowViewShowsAndEnlarges() async throws {
        let lines = try Self.canvasLines(before: try Self.png(width: 160, height: 60),
                                         after: try Self.png(width: 160, height: 60, mark: 9))
        let item  = TranscriptItem(id: .toolRun(UUID()), kind: .toolRun(lines: lines, isExpanded: false, ending: .completed),
                                   date: .now, authorWorkerID: UUID(), continuesGroup: false)
        let prepared = await RowPreparation.prepare([item], workerName: "Atlas", width: 700, style: TranscriptStyle(),
                                                    cache: LayoutMeasurementCache(), pipeline: MarkdownContent())
        let row  = try #require(prepared.rows.first)
        let view = TranscriptRowView(frame: NSRect(x: 0, y: 0, width: 700, height: row.geometry.height))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        content.addSubview(view)
        let window = TranscriptFixture.offscreenWindow(for: content, size: content.frame.size)
        defer { window.close() }
        view.configure(row, style: TranscriptStyle(), workerName: "Atlas", avatar: nil, selection: nil)

        let strip = try #require(view.subviews.compactMap { $0 as? ToolPicturesView }.first)
        #expect(strip.shownImages.count == 1)
        #expect(strip.frame.origin == row.geometry.pictureFrames[1][0].origin)
        view.focusedAction = .openPictures(block: 1)
        #expect(strip.isFocused)

        let enlargement = try #require(view.enlargement(ofPictures: 1))
        #expect(enlargement.label == "Pictures of Timeline · lane 2")
        #expect(enlargement.images.count == 1 && enlargement.opener === strip)
        #expect(view.enlargement(ofPictures: 0) == nil, "the summary shows no pictures")
    }
}
