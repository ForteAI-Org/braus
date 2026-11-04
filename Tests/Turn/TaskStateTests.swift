import LocalMCP
import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import Memory
import ModelTransports
import Testing
@testable import Turn

@Suite("TaskState")
struct TaskStateTests {
    @Test func catalogueKeysAreUnique() {
        let keys = ModelText.catalogue.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func nineSectionsInOrderWithTags() throws {
        let state = TaskStateFixtures.state()
        let tags = ["request", "facts", "decisions", "failedAttempts", "loaded", "todo",
                    "lastOutcome", "scene", "goal", "personIntervention"]
        let rendered = state.rendered()
        var end = rendered.startIndex
        for tag in tags {
            let opening = try #require(rendered.range(of: "<\(tag)>", range: end..<rendered.endIndex))
            let closing = try #require(rendered.range(of: "</\(tag)>", range: opening.upperBound..<rendered.endIndex))
            end = closing.upperBound
        }
        #expect(state.sections.count == 10)
    }

    @Test func requestIsVerbatim() {
        let request = "  Preserve café\r\n<request> & {words}\n\tend  "
        let state = TaskStateFixtures.state([.init(fact: .request(request), origin: .runner,
                                                 sequence: nil, key: "t1.request")])
        #expect(state.sections[.request]?.lines == [[.operand(request)]])
        #expect(state.rendered().contains(request))
        #expect(state.sections[.request]?.lines.first?.first.map { Data($0.text.utf8) } == Data(request.utf8))
    }

    @Test func everyTodoItemHasAState() {
        let state = TaskStateFixtures.state()
        #expect(state.check(latestSceneRevision: nil).isEmpty)
        let rows = state.sections[.todo]?.lines ?? []
        #expect(rows.count == 3)
        for (index, status) in ["done", "in_progress", "pending"].enumerated() {
            #expect(rows[index].contains(.literal(status)))
        }
        var incomplete = state.sections
        incomplete[.todo] = nil
        #expect(state.checkSections(incomplete).contains(.todoItemWithoutState(.init(rawValue: "r1"))))
    }

    @Test func failuresAreAllThere() {
        let state = TaskStateFixtures.state()
        #expect(state.sections[.failedAttempts]?.provenance == [1, 2])
        #expect(state.sections[.failedAttempts]?.lines.count == 2)
        var incomplete = state.sections
        incomplete[.failedAttempts] = nil
        #expect(state.checkSections(incomplete) == [.missingFailure(call: 1), .missingFailure(call: 2)])
    }

    @Test @MainActor func sceneIsTheLatest() {
        var latest: TaskStateScene? = .init(revision: 1, text: "Whole first scene")
        let providing: LatestSceneProviding = { latest }
        var state = TaskState()
        if let scene = providing() { state.setScene(scene) }
        latest = .init(revision: 2, text: "Whole latest scene")
        if let scene = providing() { state.setScene(scene) }
        state.setScene(.init(revision: 1, text: "Old scene"))
        #expect(state.sections[.scene]?.lines == [[.operand("Whole latest scene")]])
        #expect(state.check(latestSceneRevision: 2).isEmpty)
        #expect(state.check(latestSceneRevision: 3) == [.staleScene(revision: 2)])
        #expect(TaskState().check(latestSceneRevision: 1) == [.staleScene(revision: 0)])
    }

    @Test func sizeWithinBudget() {
        for inputs in TaskStateFixtures.tasks {
            let state = TaskStateFixtures.state(inputs)
            #expect(AutomationRuntime.TokenEstimate.tokens(in: state.rendered()) < 3000)
            #expect(state.check(latestSceneRevision: nil).isEmpty)
            print("TaskState fixture: \(state.rendered().utf8.count) bytes, \(AutomationRuntime.TokenEstimate.tokens(in: state.rendered())) tokens")
        }
        #expect(TaskState().check(latestSceneRevision: nil).isEmpty)
        let state = TaskStateFixtures.state([.init(fact: .request(String(repeating: "a", count: 14_000)),
            origin: .runner, sequence: nil, key: "long.request")])
        #expect(state.check(latestSceneRevision: nil) == [.overBudget(tokens: AutomationRuntime.TokenEstimate.tokens(in: state.rendered()))])
        #expect(AutomationRuntime.TokenEstimate.tokens(in: "") == 0)
        #expect(AutomationRuntime.TokenEstimate.tokens(in: "12345") == 2)
        #expect(AutomationRuntime.TokenEstimate.tokens(in: "é🙂abc") == 2)
    }

    @Test func decisionsCarryTheReason() {
        let state = TaskStateFixtures.state()
        #expect(state.sections[.decisions]?.lines.contains { $0.contains(.operand("Verify before continuing")) } == true)
        var stopped = state
        stopped.apply(TaskStateFixtures.todo(3, change: .stopped))
        #expect(stopped.sections[.decisions]?.lines.count == 2)
    }

    @Test func netFactsNotChronicle() {
        let state = TaskStateFixtures.state([
            TaskStateFixtures.call(1, outcome: TaskStateFixtures.absent),
            TaskStateFixtures.call(2, outcome: TaskStateFixtures.confirmed)
        ])
        #expect(state.sections[.facts]?.lines.count == 1)
        #expect(state.sections[.facts]?.provenance == [2])
        #expect(state.rendered().contains(TaskStateFixtures.confirmed.row))
        #expect(state.sections[.failedAttempts]?.provenance == [1])
    }

    @Test func digestBecomesPersonIntervention() {
        var state = TaskState()
        state.setPersonIntervention(digest: "Selected Submit.\nUnobserved: completion.\nDetails: §2")
        #expect(state.sections[.personIntervention]?.lines == [[.operand("Selected Submit.\nUnobserved: completion.\nDetails: §2")]])
        #expect(state.rendered().contains("Unobserved"))
        state.setPersonIntervention(digest: "No changes made.")
        #expect(state.sections[.personIntervention]?.unobserved.isEmpty == false)
    }

    @Test func redoneClosedItemIsFlagged() {
        let state = TaskStateFixtures.state()
        #expect(state.redoneClosedItem(firstAction: TaskStateFixtures.call(5, subject: "Prepare",
            outcome: TaskStateFixtures.confirmed)) == .init(rawValue: "r1"))
        #expect(state.redoneClosedItem(firstAction: TaskStateFixtures.call(5,
            outcome: TaskStateFixtures.confirmed)) == nil)
        #expect(state.redoneClosedItem(firstAction: TaskStateFixtures.call(5, subject: "prepare",
            outcome: TaskStateFixtures.confirmed)) == nil)
        #expect(state.redoneClosedItem(firstAction: TaskStateFixtures.call(5, subject: "Prepare",
            outcome: .init(gesture: .notSent, effect: .absent, recovery: .retry))) == nil)
    }

    @Test func bytesAreStable() {
        #expect(Data(TaskStateFixtures.state().rendered().utf8) == Data(TaskStateFixtures.state().rendered().utf8))
        #expect(TaskStateFixtures.state().rendered().contains("c3"))
    }

    @Test func unobservedOutcomesStayExplicit() {
        let state = TaskStateFixtures.state([TaskStateFixtures.call(1, outcome: TaskStateFixtures.uncertain)])
        #expect(state.sections[.facts]?.unobserved.isEmpty == false)
        #expect(state.sections[.failedAttempts]?.lines.isEmpty == true)
        #expect(state.sections[.lastOutcome]?.lines.first?.contains(.literal(TaskStateFixtures.uncertain.row)) == true)
    }

    @Test func notSentIsRetainedAsFailure() {
        let state = TaskStateFixtures.state([TaskStateFixtures.call(1,
            outcome: .init(gesture: .notSent, effect: .notApplicable, recovery: .askPerson))])
        #expect(state.sections[.failedAttempts]?.provenance == [1])
        #expect(state.check(latestSceneRevision: nil).isEmpty)
    }

    @Test func applyIsIdempotent() {
        var state = TaskStateFixtures.state()
        let before = state
        for input in TaskStateFixtures.tasks[0] { state.apply(input) }
        #expect(state == before)
    }

    @Test func outcomesWithoutGesturesDoNotInventFacts() {
        let input = TaskStateInput(fact: .callFinished(tool: "status", subject: nil, outcome: nil),
                                   origin: .dispatcher, sequence: 1, key: "c1.finished")
        let state = TaskStateFixtures.state([input])
        #expect(state.sections[.facts]?.lines.isEmpty == true)
        #expect(state.sections[.lastOutcome]?.unobserved.isEmpty == false)
        #expect(state.check(latestSceneRevision: nil).isEmpty)
    }

    @Test func loadedItemsAreNetFacts() {
        let state = TaskStateFixtures.state((1...2).map {
            .init(fact: .loaded(.guide(id: "editing", section: "Submission")), origin: .dispatcher,
                  sequence: $0, key: "c\($0).guide")
        })
        #expect(state.sections[.loaded]?.lines.count == 1)
        #expect(state.sections[.loaded]?.provenance == [2])
    }

    @Test func newTaskDoesNotInheritPreviousTaskEvidence() {
        var state = TaskStateFixtures.state()
        state.setScene(.init(revision: 2, text: "Whole current scene"))
        let request = TaskStateInput(fact: .request("Review the next item."), origin: .runner,
                                     sequence: nil, key: "t3.request")
        state.apply(request)
        let revision = TodoRevision(taskID: "next-task", number: 1, change: .drafted,
                                    rows: TaskStateFixtures.rows, recordedAtMS: 0)
        state.apply(.init(fact: .todo(TodoEvent(revision, origin: .model)), origin: .runner,
                          sequence: nil, key: "todo.next-task.1"))
        #expect(state.sections[.facts]?.lines.isEmpty == true)
        #expect(state.sections[.failedAttempts]?.lines.isEmpty == true)
        #expect(state.sections[.decisions]?.lines.isEmpty == true)
        #expect(state.sections[.personIntervention]?.lines.isEmpty == true)
        #expect(state.sections[.request]?.lines == [[.operand("Review the next item.")]])
        #expect(state.sections[.scene]?.lines == [[.operand("Whole current scene")]])
        #expect(state.check(latestSceneRevision: 2).isEmpty)
        let before = state
        for input in TaskStateFixtures.tasks[0] { state.apply(input) }
        #expect(state == before)
    }
}

@MainActor
@Suite("TaskState runner")
struct TaskStateRunnerTests {
    @Test func personInterventionFromReviewTurn() async throws {
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: URL(filePath: "/fake/task-state"))
        for reviewing in [false, true] {
            let transport = TurnTestTransport([[.delta("ok")]])
            _ = try await runner.run(.init(prompt: reviewing ? "digest" : "request",
                route: .modelLoop(transport: transport, contextWindow: nil),
                reviewingHumanIntervention: reviewing)) { _ in }
        }
        #expect(runner.currentTaskState?.sections[.request]?.lines == [[.operand("request")]])
        #expect(runner.currentTaskState?.sections[.personIntervention]?.lines == [[.operand("digest")]])
        try await runner.close()
    }

    @Test(arguments: [true, false])
    func turnRunnerCollectsStateWithoutInjectingMessages(_ allowsSuspension: Bool) async throws {
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: URL(filePath: "/fake/task-state"),
                                    allowsSuspension: allowsSuspension)
        var sceneReads = 0
        runner.latestScene = { sceneReads += 1; return nil }
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "observe", arguments: Data("{}".utf8)))],
            [.delta("ok")]
        ])
        var events: [TurnRunEvent] = []
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { events.append($0) }
        #expect(transport.messages.count == 2)
        #expect(transport.messages.first?.last?.text == "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\nHello")
        #expect(runner.currentTaskState != nil)
        #expect(sceneReads > 0)
        try await runner.close()
    }

    @Test func firstReviewTurnDoesNotReplaceTheRequest() async throws {
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: URL(filePath: "/fake/task-state"))
        _ = try await runner.run(.init(prompt: "digest",
            route: .modelLoop(transport: TurnTestTransport([[.delta("ok")]]), contextWindow: nil),
            reviewingHumanIntervention: true)) { _ in }
        #expect(runner.currentTaskState?.sections[.request]?.lines.isEmpty == true)
        #expect(runner.currentTaskState?.sections[.personIntervention]?.lines == [[.operand("digest")]])
        try await runner.close()
    }

    @Test func ordinaryStateReadsTheLatestWholeScene() async throws {
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: URL(filePath: "/fake/task-state"))
        var reads = 0
        runner.latestScene = {
            reads += 1
            return .init(revision: 2, text: "Whole scene")
        }
        let transport = TurnTestTransport([[.delta("ok")]])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        #expect(reads == 1)
        #expect(runner.taskStateProblems.isEmpty)
        #expect(runner.currentTaskState?.sections[.scene]?.lines == [[.operand("Whole scene")]])
        try await runner.close()
    }

    @Test func noFactFromLogText() async throws {
        let host = TestTurnHost()
        let tools = AutomationTools(session: TurnTestSession())
        let runner = TurnRunner(tools: tools,
            configuration: .init(workingDirectory: URL(filePath: "/fake/task-state"),
                                 bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true), host: host)
        let transport = TurnTestTransport([[.delta("ok")]])
        let expected = TaskStateFixtures.state([.init(fact: .request("Hello"), origin: .runner,
                                                     sequence: nil, key: "t1.request")])
        var recorded = false
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { event in
            if case .contextReset = event {
                do { try tools.record?("act Submit: sent · confirmed · continue") }
                catch { Issue.record(error) }
            }
            if case .tool = event { recorded = true }
        }
        #expect(recorded)
        #expect(runner.currentTaskState == expected)
        try await runner.close()
    }

    @Test func runnerRefreshesSceneAfterTurn() async throws {
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: URL(filePath: "/fake/task-state"))
        runner.latestScene = { .init(revision: 3, text: "Whole scene") }
        _ = try await runner.run(.init(prompt: "Hello",
            route: .modelLoop(transport: TurnTestTransport([[.delta("ok")]]), contextWindow: nil))) { _ in }
        #expect(runner.currentTaskState?.sections[.scene]?.lines == [[.operand("Whole scene")]])
        #expect(runner.currentTaskState?.check(latestSceneRevision: 3).isEmpty == true)
        try await runner.close()
    }
}


extension TaskStateTests {
    @Test func failureHistoryIsBoundedAndSizeStaysExact() {
        var state = TaskState()
        for index in 0..<600 {
            state.apply(.init(fact: .callFailed(tool: "act", reason: "Failure é🙂"), origin: .dispatcher,
                              sequence: index, key: "failure\(index)"))
        }
        #expect((state.sections[.failedAttempts]?.lines.count ?? 0) <= 128)
        #expect(state.sections[.failedAttempts]?.provenance.first == 472)
        #expect(state.droppedFailures == 472)
        let tokens = AutomationRuntime.TokenEstimate.tokens(in: state.rendered())
        #expect(state.check(ceilingTokens: 0, latestSceneRevision: nil) == [.overBudget(tokens: tokens)])
    }
}


extension TaskStateTests {
    @Test func inputKeyRetentionDropsOldestAndKeepsRecentDuplicatesIdempotent() {
        var state = TaskState()
        for index in 0..<2100 {
            state.apply(.init(fact: .request("Request \(index)"), origin: .runner,
                              sequence: nil, key: "request\(index)"))
        }
        #expect(state.retainedInputKeyCount == 2048)
        #expect(state.droppedInputKeys == 52)
        let previous = state
        state.apply(.init(fact: .request("Duplicate"), origin: .runner, sequence: nil, key: "request2099"))
        #expect(state == previous)
        #expect(state.check(ceilingTokens: 0, latestSceneRevision: nil) == [
            .overBudget(tokens: AutomationRuntime.TokenEstimate.tokens(in: state.rendered()))
        ])
    }
}


extension TaskStateTests {
    @Test func cachedSizeMatchesRenderingAcrossTypedUpdates() {
        for inputs in TaskStateFixtures.tasks {
            var state = TaskState()
            for input in inputs {
                state.apply(input)
                #expect(state.check(ceilingTokens: 0, latestSceneRevision: nil) == [
                    .overBudget(tokens: AutomationRuntime.TokenEstimate.tokens(in: state.rendered()))
                ])
            }
            state.setScene(.init(revision: 1, text: "Scene é🙂\r\nnext"))
            state.setPersonIntervention(digest: "Person edited a field")
            #expect(state.check(ceilingTokens: 0, latestSceneRevision: nil) == [
                .overBudget(tokens: AutomationRuntime.TokenEstimate.tokens(in: state.rendered()))
            ])
        }
    }
}
