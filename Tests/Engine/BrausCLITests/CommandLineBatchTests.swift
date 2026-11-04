//
//  CommandLineBatchTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import TestScratch
import PerceptionCore
@testable import braus
@testable import SQLiteMemory
import Testing

/// How `braus batch` is recorded (review F05 of plan D1): one batch call with its steps planned under it,
/// each step started before it acts and ended by its command, the steps never run skipped, and the
/// batch's end with the summary its steps allow. The steps here are the commands' recording without a
/// Seat: each counts its gesture and ends its call as `ActCommand` and `SelectCommand` do.
@Suite("braus batch recorded as one batch with its steps")
struct CommandLineBatchTests {

    private let app = AppContextIdentity(bundleID: "com.apple.TextEdit")

    private func plan() throws -> BatchPlan {
        try BatchPlan(arguments: ["batch", "TextEdit", "--window", "Untitled", "--seat", "--",
                                  "act", "Next", "--then", "select", "Format", "Bold", "--then", "act", "Third"])
    }

    /// Entry and refreshed scenes are required by the production batch policy, even for a recording fixture.
    private func entryScene() -> SceneSnapshot {
        SceneSnapshot(bundleID: app.bundleID, appName: "TextEdit", windowTitle: "Untitled",
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                .init(id: "next", kind: .control, label: "Next", bounds: .init(x: 0, y: 0, width: 0.2, height: 0.2)),
                .init(id: "format", kind: .control, label: "Format", bounds: .init(x: 0.3, y: 0, width: 0.2, height: 0.2)),
                .init(id: "third", kind: .control, label: "Third", bounds: .init(x: 0.6, y: 0, width: 0.2, height: 0.2))
            ])
    }

    /// These recording fixtures claim confirmation only when their synthetic oracle supplies it.
    private func checked(_ kind: ActOutcomeKind = .foundActed) -> ActOutcome {
        let check: OperationCheck = kind == .foundActed
            ? .init(condition: .structuralEffect, method: .sceneDifference, verdict: .passed, performed: .requested)
            : .unchecked(performed: .none, limits: [.targetNotResolved])
        return ActOutcome(kind, "Answered.", scene: entryScene(), check: check)
    }

    /// A memory of its own, whose lock budget is short so a held lock refuses fast.
    private func memory() -> MemoryService {
        let directory = Scratch.directory("command-line-batch")
        let store = SQLiteMemoryStore.Configuration(
            lockBudget: .milliseconds(100),
            retryPause: .milliseconds(5),
            maximumRetryPause: .milliseconds(10)
        )
        return MemoryService(
            directory: directory,
            configuration: MemoryService.Configuration(store: store, essentialAttempts: 1, essentialCycles: 1)
        )
    }

    private func recorders(_ memory: MemoryService, count: Int) -> (parent: CallRecorder, children: [CallRecorder]) {
        let brain  = BrainMemory(brains: memory, applications: memory, clock: { memory.clock.brainNow() })
        // The context every command line call of the process has.
        let parent = CallRecorder(memory: memory, brain: brain, context: CommandLineTrace.context())
        let children = (0..<count).map {
            CallRecorder(memory: memory, brain: brain, context: parent.context.child($0))
        }
        return (parent, children)
    }

    private func status(_ memory: MemoryService, _ recorder: CallRecorder) async throws -> AgentCallStatus? {
        try await memory.call(recorder.eventID)?.progress.status
    }

    @Test("a command line call names its process's session, so the contract admits it: an act begins and ends")
    func commandLineCallHasASession() async throws {
        let memory   = memory()
        let recorder = recorders(memory, count: 0).parent
        try await recorder.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: app)
        try await CommandLineCall.end(recorder, outcome: ActOutcome(.foundActed, "clicked"), tool: .act)
        #expect(try await status(memory, recorder) == .completed)
        #expect(try await memory.event(recorder.eventID)?.sessionID == CommandLineTrace.session)
        await memory.close()
    }

    @Test("three steps planned, the second failing: one completed, one failed, one skipped, all under one batch whose end says so; no gesture for the third and no check on the batch")
    func stopAtTheSecondStep() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        var gestures: [String] = []
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                entryScene: entryScene(), prepare: { _, _ in entryScene() }) {
                number, step, recorder in
                gestures.append(step.summary)
                if number == 2 {
                    try? await recorder.end(.failed, result: .error(message: "the menu did not open"), tool: .select)
                    throw AutomationFailure("the menu did not open")
                }
                let done = checked()
                try await CommandLineCall.end(recorder, outcome: done, tool: .act)
                return done
            }
            Issue.record("the batch did not stop")
        } catch let failure as BatchFailure {
            #expect(failure.step == 2 && failure.total == 3)
            #expect((failure.cause as? AutomationFailure)?.description == "the menu did not open")
        }
        #expect(gestures.count == 2, "the third step never acted")
        #expect(try await status(memory, children[0]) == .completed)
        #expect(try await status(memory, children[1]) == .failed)
        #expect(try await status(memory, children[2]) == .skipped)
        for child in children {
            #expect(try await memory.event(child.eventID)?.parentEventID == parent.eventID)
        }
        let batch = try #require(try await memory.call(parent.eventID))
        #expect(batch.progress.status == .completed)
        guard case .batch(let stopped, let attempted, let verified)? = batch.progress.result else {
            Issue.record("the batch's end has no summary: \(String(describing: batch.progress.result))")
            return
        }
        #expect(stopped && attempted == 2 && verified == 1)
        #expect(try await memory.perform { try await $0.facts.verifications(of: parent.eventID) }.isEmpty,
                "the container proves nothing itself")
        await memory.close()
    }

    @Test("a step that answers without its effect stops the batch: completed with that outcome, the rest skipped")
    func stopOnAnUnacceptedOutcome() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        var performed = 0
        try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
            entryScene: entryScene(), prepare: { _, _ in entryScene() }) { number, _, recorder in
            performed += 1
            let done = checked(number == 2 ? .honestMiss : .foundActed)
            try await CommandLineCall.end(recorder, outcome: done, tool: number == 2 ? .select : .act)
            return done
        }
        #expect(performed == 2)
        #expect(try await memory.call(parent.eventID)?.progress.batchConclusion == .stopped(at: 1, reason: .targetMissing))
        #expect(try await memory.call(parent.eventID)?.progress.result?.isExactly(.batch(stopped: true, attempted: 2, verified: 1)) == true)
        #expect(try await status(memory, children[1]) == .completed)
        #expect(try await status(memory, children[2]) == .skipped)
        #expect(try await status(memory, parent) == .completed)
        await memory.close()
    }

    @Test("a batch the memory does not confirm does nothing and leaves nothing behind")
    func unconfirmedBatchDoesNothing() async throws {
        let memory = memory()
        _ = try await memory.ready()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        let lock = try SQLiteConnection(path: memory.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        var gestures = 0
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                entryScene: entryScene(), prepare: { _, _ in entryScene() }) { _, _, _ in
                gestures += 1
                return ActOutcome(.foundActed, "Completed.", scene: entryScene())
            }
            Issue.record("the batch ran unconfirmed")
        } catch let failure as ActFailure {
            #expect(failure.kind == .refused)
        }
        try lock.execute("COMMIT")
        lock.close()
        #expect(gestures == 0)
        #expect(try await memory.calls(inTrace: CommandLineTrace.trace).isEmpty)
        await memory.close()
    }

    @Test("a step whose end is not saved stops the batch: nothing is repeated, the later steps never run, and the records left say incomplete")
    func unsavedStepEnd() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        var lock: SQLiteConnection?
        var gestures = 0
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                entryScene: entryScene(), prepare: { _, _ in entryScene() }) { number, _, recorder in
                gestures += 1
                if number == 2 {
                    lock = try SQLiteConnection(path: memory.url.path)
                    try lock?.execute("BEGIN IMMEDIATE")
                }
                let done = checked()
                try await CommandLineCall.end(recorder, outcome: done, tool: number == 2 ? .select : .act)
                return done
            }
            Issue.record("the batch went on after an unsaved end")
        } catch let failure as BatchFailure {
            #expect(failure.cause is CommandLineCall.Unsaved)
        }
        try lock?.execute("COMMIT")
        lock?.close()
        #expect(gestures == 2)
        #expect(await memory.status().suspended != nil)
        await memory.close()

        let reopened = MemoryService(directory: memory.directory)
        #expect(try await reopened.call(parent.eventID)?.progress.status == .started, "the batch stays incomplete")
        #expect(try await reopened.call(children[0].eventID)?.progress.status == .completed)
        #expect(try await reopened.call(children[1].eventID)?.progress.status == .started)
        #expect(try await reopened.call(children[2].eventID)?.progress.status == .planned)
        await reopened.close()
    }

    @Test("an act step the brokered session refuses by throwing ends its call as failed, and the steps after it are skipped")
    func refusedSeatActEndsItsCall() async throws {
        let memory = memory()
        let steps  = try plan().steps
        let (parent, children) = recorders(memory, count: 3)
        let request = ActionRequest(processID: 1, bundleID: app.bundleID, appName: "TextEdit", target: "Next",
                                    verb: .click)
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                entryScene: entryScene(), prepare: { _, _ in entryScene() }) { _, _, recorder in
                try await ActCommand.perform(request, recorder: recorder, begun: true) { _ in
                    throw AutomationFailure("The seat is waiting for the person.")
                }
            }
            Issue.record("the batch went on after a refusal")
        } catch let failure as BatchFailure {
            #expect(failure.cause is AutomationFailure)
        }
        #expect(try await status(memory, children[0]) == .failed, "a refused act is never left started")
        #expect(try await status(memory, children[1]) == .skipped)
        #expect(try await status(memory, children[2]) == .skipped)
        await memory.close()
    }
}

extension CommandLineBatchTests {
    @Test @MainActor func policySummaryKeepsUnknownIntermediate() async throws {
        let memory = memory()
        let steps = try BatchPlan(arguments: ["batch", "TextEdit", "--window", "Untitled", "--seat", "--",
            "act", "Next", "--then", "act", "Next", "--then", "act", "Next"]).steps
        let scene = PerceptionCore.SceneSnapshot(bundleID: app.bundleID, appName: "TextEdit", windowTitle: "Untitled",
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                .init(id: "next", kind: .control, label: "Next", bounds: .init(x: 0, y: 0, width: 0.2, height: 0.2))
            ])
        let (parent, children) = recorders(memory, count: steps.count)
        do {
            try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                entryScene: scene, prepare: { _, _ in scene }) { number, _, recorder in
                    let done = ActOutcome(number == 2 ? .actedUnverified : .foundActed, "answered", scene: scene,
                        check: .init(condition: .structuralEffect, method: .sceneDifference,
                                     verdict: number == 2 ? .unknown : .passed, performed: .requested))
                    try await CommandLineCall.end(recorder, outcome: done, tool: .act)
                    return done
                }
        }
        let call = try #require(try await memory.call(parent.eventID))
        #expect(call.progress.batchConclusion == .ranToEnd)
        #expect(call.progress.result?.isExactly(.batch(stopped: false, attempted: 3, verified: 2)) == true)
        await memory.close()
    }
}


extension CommandLineBatchTests {
    @Test @MainActor func missingEntrySkipsAllChildren() async throws {
        let memory = memory()
        let steps = try plan().steps
        let (parent, children) = recorders(memory, count: steps.count)
        do {
            await #expect(throws: (any Error).self) {
                try await CommandLineBatch.run(steps, app: app, parent: parent, children: children) { _, _, _ in
                    Issue.record("No step may start without an entry scene")
                    return ActOutcome(.refused, "Unavailable")
                }
            }
        }
        for child in children { #expect(try await status(memory, child) == .skipped) }
        await memory.close()
    }
}


extension CommandLineBatchTests {
    @Test @MainActor func uncertainAcknowledgementDoesNotBecomeAConfirmedStoredStep() async throws {
        let memory = memory()
        let steps = try BatchPlan(arguments: ["batch", "TextEdit", "--window", "Untitled", "--seat", "--",
            "act", "Next"]).steps
        let (parent, children) = recorders(memory, count: steps.count)
        var sent = 0
        try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
            entryScene: entryScene(), prepare: { _, _ in entryScene() }) { _, _, recorder in
            sent += 1
            let done = ActOutcome(.foundActed, "Acknowledged without an oracle", scene: entryScene(),
                check: .unchecked(performed: .uncertain))
            try await CommandLineCall.end(recorder, outcome: done, tool: .act)
            return done
        }
        #expect(sent == 1)
        let batch = try #require(try await memory.call(parent.eventID))
        #expect(batch.progress.batchConclusion == .ranToEnd)
        #expect(batch.progress.result?.isExactly(.batch(stopped: false, attempted: 1, verified: 0)) == true)
        let checks = try await memory.perform { try await $0.facts.verifications(of: children[0].eventID) }
        #expect(checks.count == 1 && checks.first?.check.performed == .uncertain && checks.first?.check.verdict == .unknown)
        await memory.close()
    }
}


extension CommandLineBatchTests {
    @Test @MainActor func actualCancellationClosesTheParentAndSkipsAllLaterSteps() async throws {
        let memory = memory()
        let steps = try plan().steps
        let (parent, children) = recorders(memory, count: steps.count)
        var performed = 0
        let task = Task { @MainActor in
            do {
                try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                    entryScene: entryScene(), prepare: { _, _ in entryScene() }) { _, _, recorder in
                    performed += 1
                    let done = checked()
                    try await CommandLineCall.end(recorder, outcome: done, tool: .act)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return done
                }
                Issue.record("Actual cancellation was converted into a completed batch")
            } catch is CancellationError {
                #expect(Task.isCancelled)
            } catch { Issue.record("Unexpected cancellation result: \(error)") }
        }
        await task.value
        #expect(performed == 1)
        #expect(try await status(memory, children[0]) == .completed)
        for child in children.dropFirst() { #expect(try await status(memory, child) == .skipped) }
        let batch = try #require(try await memory.call(parent.eventID))
        #expect(batch.progress.status == .cancelled && batch.progress.result == nil && batch.progress.batchConclusion == nil)
        await memory.close()
    }

    @Test @MainActor func anAlreadyCancelledBatchWritesNothingAndSendsNothing() async throws {
        let memory = memory()
        let steps = try plan().steps
        let (parent, children) = recorders(memory, count: steps.count)
        var performed = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                    entryScene: entryScene(), prepare: { _, _ in entryScene() }) { _, _, _ in
                    performed += 1
                    return checked()
                }
                Issue.record("An already cancelled batch was admitted")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        }
        await task.value
        #expect(performed == 0)
        #expect(try await memory.calls(inTrace: CommandLineTrace.trace).isEmpty)
        await memory.close()
    }

    @Test @MainActor func aDriverCancellationErrorKeepsItsContextWithoutCancellingTheTask() async throws {
        let steps = try BatchPlan(arguments: ["batch", "TextEdit", "--window", "Untitled", "--seat", "--",
            "act", "Next"]).steps
        let result = try await BatchSequence.runPolicy(steps, expectations: [], entryScene: entryScene(),
            prepare: { _, _ in entryScene() }) { _, _ in throw CancellationError() }
        let failure = try #require(result.failure as? BatchFailure)
        #expect(!Task.isCancelled)
        #expect(failure.step == 1 && failure.total == 1 && failure.cause is CancellationError)
        #expect(result.conclusion == .stopped(at: 0, reason: .error))
    }
}


extension CommandLineBatchTests {
    @Test @MainActor func cancellationDuringPreparationNeverStartsACommand() async throws {
        let memory = memory()
        let steps = try plan().steps
        let (parent, children) = recorders(memory, count: steps.count)
        var prepared = 0, performed = 0
        let task = Task { @MainActor in
            do {
                try await CommandLineBatch.run(steps, app: app, parent: parent, children: children,
                    entryScene: entryScene(), prepare: { _, _ in
                        prepared += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        return entryScene()
                    }) { _, _, _ in
                    performed += 1
                    return checked()
                }
                Issue.record("A command was admitted after preparation cancelled its task")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        }
        await task.value
        #expect(prepared == 1 && performed == 0)
        for child in children { #expect(try await status(memory, child) == .skipped) }
        let batch = try #require(try await memory.call(parent.eventID))
        #expect(batch.progress.status == .cancelled && batch.progress.result == nil && batch.progress.batchConclusion == nil)
        await memory.close()
    }
}
