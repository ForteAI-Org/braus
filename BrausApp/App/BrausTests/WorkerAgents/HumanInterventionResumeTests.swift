//
//  HumanInterventionResumeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import ChatCore
import ModelTransports
import AutomationRuntime
import SeatBroker
import Testing
@testable import Braus

@MainActor
@Suite(.serialized)
struct HumanInterventionResumeTests {
    @Test(arguments: ["yes", "stop", "preparation failure"])
    func newTurnUsesTheSameConversationOnlyForYes(ending: String) async throws {
        let resumes = ending == "yes"
        let standIn = try WorkerContextIsolationTests.StandIn()
        let suite = "braus-handoff-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            standIn.remove()
        }
        let script = WorkerContextIsolationTests.StandIn.script(standIn.root)
            .replacingOccurrences(of: "sys.stdin.read()", with: "prompt = sys.stdin.read()")
            .replacingOccurrences(of: "config = json.loads", with: """
            with open(os.path.join(root, 'prompt-%d' % call), 'w') as file:
                file.write(prompt)
            with open(os.path.join(root, 'args-%d' % call), 'w') as file:
                file.write(json.dumps(sys.argv))
            config = json.loads
            """)
        try Data(script.utf8).write(to: standIn.agent)
        let store = try WorkspaceStore.opening(in: standIn.root.appending(path: "store"))
        let worker = try await store.createWorker(
            name      : "Atlas",
            appearance: TemporaryStore.appearance()
        ).id
        try await store.configure(
            worker   : worker,
            selection: WorkerContextIsolationTests.selection
        )
        let conversation = try await store.createConversation(
            kind        : .direct,
            participants: [worker]
        ).id
        let team = TeamModel(
            store           : store,
            connections     : ModelSettingsStore(),
            broker          : SeatBroker(),
            agents          : { _ in (.claude, standIn.agent) },
            bridgeExecutable: standIn.agent,
            preferences     : preferences
        )
        await team.load()
        do {
            try await team.post(
                "Create a stereo track.",
                quote: nil,
                in   : conversation,
                by   : worker
            )
            _ = try await standIn.connection(of: 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while try await store.conversation(conversation)?.resumableSession(for: .claudeCode) != "s1",
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await store.conversation(conversation)?.resumableSession(for: .claudeCode) == "s1")
            let old = try #require(team.agentContext(of: conversation))
            try team.suspendHumanIntervention(of: worker)
            let summary = "Human control ended.\nclicked New Track\nFinal state: Stereo track"
            var entered = 0
            if ending != "stop" {
                let resume = Task {
                    try await team.resumeHumanIntervention(
                        of     : worker,
                        summary: summary
                    ) {
                        entered += 1
                        #expect(!old.host.isRunning)
                        let messages = try await store.messages(in: conversation)
                        #expect(messages.first?.delivery == .completed, "taking control marks no error")
                        if ending == "preparation failure" { throw CocoaError(.fileNoSuchFile) }
                    }
                }
                if resumes { try await resume.value }
                else { await #expect(throws: AutomationFailure.self) { try await resume.value } }
            } else {
                team.stopHumanIntervention(of: worker)
            }
            if resumes {
                _ = try await standIn.connection(of: 1)
                #expect(entered == 1)
                #expect(team.activeContext(of: worker) == conversation)
                #expect(team.agentContext(of: conversation)?.host === old.host)
                let prompt = try String(
                    contentsOf: standIn.root.appending(path: "prompt-1"),
                    encoding  : .utf8
                )
                let arguments = try String(
                    contentsOf: standIn.root.appending(path: "args-1"),
                    encoding  : .utf8
                )
                #expect(prompt.components(separatedBy: summary).count == 2, "the summary is sent once")
                #expect(arguments.contains("s1"))
                let messages = try await store.messages(in: conversation)
                #expect(messages.filter { $0.text == summary && $0.authorWorkerID == nil }.count == 1)
                #expect(messages.filter(\.endsHumanControl).map(\.text) == [summary])
                let rows = ConversationProjection.items(
                    messages: messages,
                    events  : [],
                    expanded: [],
                    now     : Date()
                )
                #expect(rows.filter { if case .humanControlFinished = $0.kind { true } else { false } }.count == 1)
                #expect(!rows.contains { $0.copyText.contains(summary) }, "no bubble shows the summary")
                await #expect(throws: CancellationError.self) {
                    try await team.resumeHumanIntervention(
                        of     : worker,
                        summary: summary
                    ) { Issue.record("A second handoff must not start") }
                }
                try standIn.go(1)
            }
            let ended = await WorkerContextIsolationTests.until { !team.isAnswering(worker) }
            #expect(ended)
            // The turn the person interrupted ends handed over, with no stopped or failed mark.
            let endings = try await store.events(matching: EventQuery(scope: .conversation(conversation)))
                .filter(\.type.isTerminal)
                .map(\.type)
            #expect(endings.first == .executionHandedToPerson)
            #expect(!endings.contains(.executionCancelled))
            if ending != "preparation failure" { #expect(!endings.contains(.executionFailed)) }
            let calls = try FileManager.default.contentsOfDirectory(atPath: standIn.root.appending(path: "log").path)
            #expect(calls.count == (resumes ? 2 : 1))
            #expect(entered == (ending == "stop" ? 0 : 1))
            // End Control leaves one stopped row and no message; Yes leaves only the finished row.
            let stops = ending == "stop" ? 1 : 0
            var stopped = 0
            let stopDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                stopped = try await store.events(matching: EventQuery(scope: .conversation(conversation)))
                    .filter { $0.type == .humanControlStopped }
                    .count
                if stopped == stops { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < stopDeadline
            #expect(stopped == stops)
            if ending == "stop" {
                let messages = try await store.messages(in: conversation)
                #expect(messages.filter(\.endsHumanControl).isEmpty, "End Control sends the worker nothing")
            }
        } catch {
            await team.closeAgentHosts()
            throw error
        }
        await team.closeAgentHosts()
    }
}
