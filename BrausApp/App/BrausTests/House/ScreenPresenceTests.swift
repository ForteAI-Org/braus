//
//  ScreenPresenceTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import ChatCore
import ModelTransports
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

@Suite("ScreenPresence", .serialized)
@MainActor
struct ScreenPresenceTests {

    private static let click = "→ act {\"session\":\"s\",\"target\":\"New Track\"}"
    private static let done  = "← act {\"status\":\"found_acted\"}"

    private func report(
        _ tools  : [String],
        lastWords: String? = nil
    ) -> WorkerSpeech.Report {
        var report = WorkerSpeech.Report()
        for tool in tools {
            report.add(tool: tool)
        }
        report.lastWords = lastWords
        return report
    }

    @Test("A turn thinks until a tool call is under way, then says the call as its tool line does")
    func thinkingAndActing() {
        #expect(WorkerSpeech(report: nil, isAnswering: true) == .thinking)
        #expect(WorkerSpeech(report: report([Self.click]), isAnswering: true) == .acting("Pressing New Track…"))
        #expect(WorkerSpeech(report: report([Self.click, Self.done]), isAnswering: true) == .thinking)
        #expect(
            WorkerSpeech(report: report([Self.click, ToolStep.noteRecord("Arming it")]), isAnswering: true)
                == .acting("Pressing New Track…"),
            "a note is never the step"
        )
    }

    @Test("After its turn the worker says the first line of its last words, and nothing without them")
    func saying() {
        #expect(
            WorkerSpeech(report: report([], lastWords: "\n## **Done.** The `track` is armed\nShould I record?"), isAnswering: false)
                == .saying("Done. The track is armed")
        )
        #expect(WorkerSpeech(report: report([], lastWords: "- Armed it"), isAnswering: false) == .saying("Armed it"))
        #expect(WorkerSpeech(report: report([Self.click, Self.done]), isAnswering: false) == nil)
        #expect(WorkerSpeech(report: nil, isAnswering: false) == nil)

        var words = report([], lastWords: "I will press it")
        words.add(tool: Self.click)
        #expect(words.lastWords == nil, "words before a tool call introduce it")
    }

    @Test("A real turn reports what the screen window's bubble says: thinking, then its last words")
    func realTurnReports() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-screen-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appending(path: "claude")
        // A stand-in Claude Code that starts, waits for `go`, then answers in two lines and ends.
        let script = """
            #!/usr/bin/python3
            import json, os, sys, time
            sys.stdin.read()
            def say(event):
                event['session_id'] = 's1'
                print(json.dumps(event), flush=True)
            say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
            while not os.path.exists(os.path.join('\(root.path)', 'go')):
                time.sleep(0.01)
            say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': '**Done.** Armed\\nShall I record?'}]}})
            say({'type': 'result', 'is_error': False, 'result': 'ok', 'usage': {'input_tokens': 1, 'output_tokens': 1}})

            """
        try Data(script.utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )
        let suite       = "braus-screen-presence-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let store  = try WorkspaceStore.opening(in: root.appending(path: "store"))
        let worker = try await store.createWorker(
            name      : "Ada",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : worker,
            selection: ModelSelection(
                provider: .claudeCode,
                model   : "claude-sonnet-5",
                effort  : .low
            )
        )
        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences
        )
        await team.load()
        team.selection = worker
        await team.openSelectedConversation()
        let speech = { WorkerSpeech(report: team.turnReports[worker], isAnswering: team.isAnswering(worker)) }

        team.draft = "Arm the track"
        await team.send()
        #expect(speech() == .thinking)

        try Data().write(to: root.appending(path: "go"))
        for _ in 0..<1_000 where team.isAnswering(worker) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!team.isAnswering(worker))
        #expect(speech() == .saying("Done. Armed"))
        await team.closeAgentHosts()
    }

    @Test("The panel sits on the window's corner, half in and half out, and moves in to stay on screen")
    func panelOnTheCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let window  = CGRect(x: 400, y: 200, width: 720, height: 480)
        let panel   = ScreenPresenceView.panelFrame(around: window, in: visible)
        let figure  = CGRect(
            x     : panel.maxX - ScreenPresenceView.margin.right - ScreenPresenceView.figure.width,
            y     : panel.maxY - ScreenPresenceView.margin.top - ScreenPresenceView.figure.height,
            width : ScreenPresenceView.figure.width,
            height: ScreenPresenceView.figure.height
        )
        #expect(figure.minX < window.maxX && figure.maxX > window.maxX, "across the right edge")
        #expect(figure.minY < window.maxY && figure.maxY > window.maxY, "across the top edge")
        #expect(panel.size == ScreenPresenceView.size)

        let right = ScreenPresenceView.panelFrame(
            around: window.offsetBy(dx: visible.maxX - window.maxX, dy: 0),
            in    : visible
        )
        #expect(right.maxX == visible.maxX)
        let top   = ScreenPresenceView.panelFrame(
            around: window.offsetBy(dx: 0, dy: visible.maxY - window.maxY),
            in    : visible
        )
        #expect(top.maxY == visible.maxY)

        let narrowest = ScreenPresenceView.panelFrame(
            around: CGRect(origin: window.origin, size: WorkerScreenWindowController.minimumSize),
            in    : visible
        )
        let widest    = narrowest.maxX - ScreenPresenceView.size.width
            + (ScreenSpeechBubble.size.width - ScreenSpeechBubble.trailRoom - ScreenSpeechBubble.widest)
        #expect(widest > window.minX + 80, "the widest bubble stays clear of the traffic lights")
    }

    @Test("The bubble grows leftwards from its trail: a pill while thinking, one line at most as wide as it may be")
    func bubbleWidths() {
        #expect(ScreenSpeechBubble.width(of: .thinking) == ScreenSpeechBubble.thinking)
        #expect(ScreenSpeechBubble.width(of: .saying(String(repeating: "word ", count: 40))) == ScreenSpeechBubble.widest)
        let short = ScreenSpeechBubble.width(of: .acting("Pressing OK…"))
        #expect(short > ScreenSpeechBubble.thinking && short < ScreenSpeechBubble.widest)

        let bubble = ScreenSpeechBubble(frame: CGRect(origin: .zero, size: ScreenSpeechBubble.size))
        for speech in [WorkerSpeech.thinking, .acting("Pressing OK…"), .saying(String(repeating: "word ", count: 40))] {
            bubble.show(speech)
            #expect(bubble.balloonFrame.maxX == ScreenSpeechBubble.size.width - ScreenSpeechBubble.trailRoom)
            #expect(bubble.balloonFrame.width == ScreenSpeechBubble.width(of: speech))
        }
        bubble.show(nil)
        #expect(bubble.balloonFrame == .zero)
        #expect(bubble.hitTest(.zero) == nil, "the bubble never takes a click itself")
    }

    @Test("Only a bubble that says something takes a click; the click opens the conversation and closes it")
    func sayingOpensTheConversation() throws {
        let worker    = try #require(HouseFixture.workers.first)
        let container = NSView(frame: CGRect(origin: .zero, size: ScreenPresenceView.size))
        let presence  = ScreenPresenceView(worker: worker)
        container.addSubview(presence)
        presence.layoutSubtreeIfNeeded()
        var opened = 0
        presence.onOpen = { opened += 1 }

        presence.show(worker: worker, speech: .acting("Pressing OK…"))
        let balloon = CGPoint(
            x: presence.balloon.midX,
            y: presence.balloon.midY
        )
        #expect(!presence.balloon.isEmpty)
        #expect(presence.hitTest(balloon) == nil)
        #expect(presence.accessibilityLabel() == "\(worker.name), Pressing OK…")

        presence.show(worker: worker, speech: .saying("Done. Shall I record?"))
        #expect(presence.hitTest(balloon) === presence)
        #expect(presence.hitTest(CGPoint(x: 2, y: 2)) == nil, "the panel's clear parts take nothing")
        #expect(presence.accessibilityRole() == .button)

        #expect(presence.accessibilityPerformPress())
        #expect(opened == 1)
        #expect(presence.hitTest(balloon) == nil, "closed once the person opened the conversation")
        #expect(presence.accessibilityLabel() == worker.name)

        presence.show(worker: worker, speech: .saying("Done. Shall I record?"))
        #expect(presence.hitTest(balloon) == nil, "the same words stay closed")
        presence.show(worker: worker, speech: .thinking)
        presence.show(worker: worker, speech: .saying("Done. Shall I record?"))
        #expect(presence.hitTest(balloon) === presence, "said again after a new turn, they show again")
    }

    @Test("The worker's panel never takes the keyboard, stays on its window's Space and holds the presence")
    func panel() throws {
        let worker    = try #require(HouseFixture.workers.first)
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let controller = WorkerScreenWindowController(
            worker: worker,
            team  : TeamModel(
                store      : try WorkspaceStore.opening(in: directory),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
        )
        let panel = controller.presencePanel
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.contentView is NSHostingView<ScreenWorkerPresence>)
        #expect(panel.parent == nil, "attached only once the window is shown")
    }
}
