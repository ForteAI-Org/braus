//
//  HouseSignalsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppAdapters
import AppKit
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import SeatBroker
import Testing
@testable import Braus

/// The live signals the new look reads from a real turn: an approval waiting on the person, the step
/// a turn's tools are on, what the hero's body does, and what hovering its name tells.
@MainActor
@Suite("The new look's signals from a real turn", .serialized)
struct HouseSignalsTests {

    @Test("A request waits in the scope it was asked in, until it is answered")
    func waitingScopes() async throws {
        let approvals = AdapterApprovals()
        let scope     = UUID()
        let consent   = AdapterConsent(
            adapter  : "files",
            app      : "Finder",
            verb     : "move_to_trash",
            arguments: ["path": .string("/x")]
        )
        let unscoped = Task { await approvals.ask(consent) }
        let scoped   = Task { await ApprovalScope.$current.withValue(scope) { await approvals.ask(consent) } }
        while approvals.pending.count < 2 { await Task.yield() }
        #expect(approvals.waitingScopes == [scope])

        approvals.refuse(scope: scope)
        #expect(await scoped.value == false)
        #expect(approvals.waitingScopes.isEmpty)
        approvals.refuseAll()
        #expect(await unscoped.value == false)
    }

    @Test("A worker answering is busy, waiting while an approval waits in its conversation, and stopping the turn refuses it")
    func approvalTurnsTheWorkerBlue() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-house-signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at                         : root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appending(path: "claude")
        try Data(Self.standIn(root).utf8).write(to: agent)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: agent.path
        )
        let suite       = "braus-house-signals-\(UUID().uuidString)"
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
        let approvals = AdapterApprovals()
        let team      = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, agent) },
            bridgeExecutable: agent,
            preferences     : preferences,
            approvals       : approvals
        )
        await team.load()
        team.selection = worker
        await team.openSelectedConversation()
        let conversation = try #require(team.conversation?.id)
        let status       = { HouseRoster.workers(of: team).first { $0.id == worker }?.status }

        team.draft = "Empty the trash"
        await team.send()
        try await Self.wait { FileManager.default.fileExists(atPath: root.appending(path: "started").path) }
        #expect(status() == .busy)

        let asked = Task {
            await ApprovalScope.$current.withValue(conversation) {
                await approvals.ask(AdapterConsent(
                    adapter  : "files",
                    app      : "Finder",
                    verb     : "empty_trash",
                    arguments: [:]
                ))
            }
        }
        try await Self.wait { !approvals.pending.isEmpty }
        #expect(team.awaitingApproval == [worker])
        #expect(status() == .waiting)

        team.stopAnswering(worker)
        #expect(await asked.value == false, "the turn's host waits in the conversation's scope")
        #expect(team.awaitingApproval.isEmpty)
        try await Self.wait { !team.isAnswering(worker) }
        #expect(status() != .waiting)
        await team.closeAgentHosts()
    }

    @Test("The running step follows the turn's tool steps, and the turn ends with its reply")
    func runningStepFollowsTheTools() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say(
            "Export the stems",
            at: 0
        )
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
        #expect(controller.runningTurn == nil)

        let execution = UUID()
        let steps: [(text: String, step: String?)] = [
            ("", nil),
            ("→ open_session {\"app\":\"Pro Tools\"}", "Opening Pro Tools…"),
            ("← open_session {\"session\":\"s\"}", "Opened Pro Tools"),
            ("→ act {\"session\":\"s\",\"target\":\"Export\"}", "Pressing Export…"),
            // A step that failed is never the step: the one before it stays.
            ("← act {\"status\":\"honest_miss\",\"message\":\"No control named Export.\"}", "Opened Pro Tools"),
        ]
        for (index, entry) in steps.enumerated() {
            if entry.text.isEmpty {
                try await fixture.record(.executionStarted, subject: execution, at: 1)
            } else {
                try await fixture.record(.toolActivity, subject: execution, at: Double(index) + 1, text: entry.text)
            }
            controller.refresh()
            await controller.settle()
            #expect(controller.runningStep == entry.step, "\(entry.text)")
            #expect(controller.runningTurn?.hasReplied == false)
        }

        try await fixture.say(
            "Done: 12 stems.",
            at      : 10,
            byWorker: true
        )
        controller.refresh()
        await controller.settle()
        #expect(controller.runningTurn?.hasReplied == true)

        try await fixture.record(.executionCompleted, subject: execution, at: 11)
        controller.refresh()
        await controller.settle()
        #expect(controller.runningTurn == nil)
        #expect(controller.runningStep == nil)
        guard case .workerReply(_, false)? = controller.rows.last?.item.kind else {
            Issue.record("the turn ends with its reply last, which lands the hero's reply")
            return
        }
    }

    @Test("The hero acts a real turn out as the mockup does: reading, thinking, working, replying")
    func actionByPhase() {
        func action(
            isAnswering: Bool = true,
            isReading  : Bool = false,
            isLanding  : Bool = false,
            step       : String? = nil,
            hasReplied : Bool = false,
            running    : Bool = true
        ) -> WorkerAction? {
            HouseLiveConversation.action(
                isAnswering: isAnswering,
                isReading  : isReading,
                isLanding  : isLanding,
                turn       : running ? Self.turn(step: step, hasReplied: hasReplied) : nil
            )
        }
        #expect(action(isAnswering: false, running: false) == nil)
        #expect(action(isAnswering: false, step: "Opening Pro Tools…") == nil)
        #expect(action(isReading: true, running: false) == .reading, "right after the send")
        #expect(action(isReading: true) == .reading)
        #expect(action() == .thinking, "waiting for the first output")
        #expect(action(running: false) == .thinking)
        #expect(action(isReading: true, step: "Opening Pro Tools…") == .working)
        #expect(action(step: "Opened Pro Tools") == .working)
        #expect(action(step: "Opened Pro Tools", hasReplied: true) == .replying)
        #expect(action(isAnswering: false, isLanding: true, running: false) == .replying, "the reply lands")
    }

    @Test("Hovering a real worker's name tells its role, never the mock's category")
    func liveHelpTellsTheRole() {
        func hero(kind: String?) -> HouseHero {
            HouseHero(
                worker     : MockHouse.sample.workers[0],
                status     : .free,
                brows      : .idle,
                activity   : "Mixing",
                preparation: 0,
                kind       : kind
            )
        }
        #expect(!hero(kind: nil).role.isEmpty, "the mockup keeps its category's role")
        #expect(hero(kind: "Writes the copy").role == "Writes the copy")
        #expect(hero(kind: "").role.isEmpty, "a worker with no role tells nothing")
    }

    // MARK: Helpers

    /// A running turn with `step` and `hasReplied`, as the transcript's rows give it.
    private static func turn(
        step      : String?,
        hasReplied: Bool
    ) -> RunningTurn? {
        let lines = step == nil ? [] : ["→ open_session {\"app\":\"Pro Tools\"}"]
        var items: [TranscriptItem] = []
        if !lines.isEmpty {
            items.append(TranscriptItem(
                id            : .toolRun(UUID()),
                kind          : .toolRun(lines: lines, isExpanded: false, ending: nil),
                date          : .now,
                authorWorkerID: UUID(),
                continuesGroup: false
            ))
        }
        items.append(TranscriptItem(
            id            : .thinking(execution: UUID(), replies: hasReplied ? 1 : 0),
            kind          : .thinking,
            date          : .now,
            authorWorkerID: UUID(),
            continuesGroup: false
        ))
        return RunningTurn(items)
    }

    /// Waits until `condition` holds, ten seconds at most.
    private static func wait(for condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// A stand-in Claude Code that starts, says so in a `started` file, and works until it is stopped.
    private static func standIn(_ root: URL) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys, time
        sys.stdin.read()
        print(json.dumps({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5', 'session_id': 's1'}), flush=True)
        open(os.path.join('\(root.path)', 'started'), 'w').close()
        time.sleep(30)

        """
    }
}
