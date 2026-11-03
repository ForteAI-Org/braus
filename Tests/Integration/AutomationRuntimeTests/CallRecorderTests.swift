@testable import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

@Suite("Call recorder input perceptions")
struct CallRecorderTests {

    @Test func relationRecoveryRunsAfterEndWithoutAnOpenPause() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        try await recorder.end(.completed, result: nil, tool: .observe)
        _ = await recorder.observe(W.window([W.open]))
        await memory.scheduleRelationRecovery()
        #expect(await memory.flush(within: .seconds(5)))
        #expect(await memory.status().relationRecoveryPending == false)
        await memory.close()
    }

    @Test func answerClosesBeforeTheNextCall() async throws {
        let memory = try W.service()
        let first = W.recorder(memory)
        try await first.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        await first.holdPauseUntilAnswered()
        _ = await first.observe(W.window([W.open]))
        try await first.end(.completed, result: nil, tool: .observe)
        await first.answered()
        let status = await memory.status()
        #expect(status.pending + status.inFlight + status.written == 1)
        let next = W.recorder(memory)
        try await next.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        #expect(await memory.flush(within: .seconds(5)))
        #expect(await memory.status().written == 1)
        try await next.end(.completed, result: nil, tool: .observe)
        await memory.close()
    }

    @Test(arguments: [false, true])
    func perceptionAfterEndIsStandalone(keep: Bool) async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        try await recorder.end(.completed, result: nil, tool: .observe)
        if keep {
            await recorder.record(InputRecord(bundleID: W.bundle, input: .insertText("fixture", expecting: nil),
                target: nil, before: W.window([W.open]), after: W.window([W.save])))
        } else {
            _ = await recorder.observe(W.window([W.open]))
        }
        #expect(await memory.flush(within: .seconds(5)))
        let phase: CapturePhase = keep ? .before : .current
        let key = CaptureSampleKey(eventID: recorder.eventID, phase: phase)
        #expect(try await memory.perform { try await $0.scenes.associations(of: key) }.count == 1)
        await memory.close()
    }

    @Test func standaloneObserveDoesNotCloseHeldAnswer() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        await recorder.holdPauseUntilAnswered()
        try await recorder.end(.completed, result: nil, tool: .observe)
        _ = await recorder.observe(W.window([W.open]))
        #expect(await memory.flush(within: .seconds(1)))
        #expect(await memory.status().written == 0)
        await recorder.answered()
        #expect(await memory.flush(within: .seconds(5)))
        #expect(await memory.status().written == 1)
        await memory.close()
    }

    @Test
    func endClosesWithoutHold() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        _ = await recorder.observe(W.window([W.open]))
        #expect(try await memory.application(.observe(CaptureSampleKey(eventID: recorder.eventID, phase: .current))) == nil)
        try await recorder.end(.completed, result: nil, tool: .observe)
        #expect(await memory.flush(within: .seconds(5)))
        #expect(try await memory.application(.observe(CaptureSampleKey(eventID: recorder.eventID, phase: .current))) == nil)
        await memory.close()
    }

    @Test
    func derivedStartsAfterTheAnswer() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        await recorder.holdPauseUntilAnswered()
        _ = await recorder.observe(W.window([W.open]))
        try await recorder.end(.completed, result: nil, tool: .observe)
        #expect(await memory.status().written == 0)
        await recorder.answered()
        try await PauseTestWait.untilWritten(memory)
        #expect(await memory.flush(within: .seconds(5)))
        #expect(await memory.status().written == 1)
        await memory.close()
    }

    @Test
    func observeDoesNotWaitForBrain() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
        await memory.enqueue("slow test work") { _ in try await Task.sleep(for: .milliseconds(500)) }
        let started = ContinuousClock.now
        _ = await recorder.observe(W.window([W.open]))
        #expect(started.duration(to: .now) < .milliseconds(50))
        try await recorder.end(.completed, result: nil, tool: .observe)
        await memory.close()
    }

    @Test(arguments: [false, true])
    func inputUpdatesLastPerceived(hasAfter: Bool) async throws {
        let store = InputBrainStore()
        let brain = BrainMemory(
            brains      : store,
            applications: store,
            relations   : store,
            clock       : { Date(timeIntervalSince1970: 123) }
        )
        let memory = try W.service()
        let recorder = CallRecorder(
            memory : memory,
            brain  : brain,
            context: ActionContext(source: .app, streamID: "input-test")
        )
        let before = W.window([W.button("Before", x: 0.1)])
        let after = W.window([W.button("After", x: 0.4)])
        await recorder.record(InputRecord(
            bundleID: W.bundle,
            input   : .insertText("example", expecting: nil),
            target  : nil,
            before  : before,
            after   : hasAfter ? after : nil
        ))
        let seen = hasAfter ? after : before
        let enriched = await recorder.enrich(seen.scene)
        #expect(enriched.knowledge?.status == .nothing)
        let sample = CaptureSample(key: CaptureSampleKey(eventID: "expected", phase: .current), of: seen)
        let expected = SceneSkeleton.comparable(sample, minimization: ValueMinimization(), surface: nil)
        let reads = await store.reads
        #expect(reads.count == 1)
        #expect(reads.first?.skeleton == expected)
        #expect(reads.first?.isComplete == sample.quality.isComplete)
        #expect(reads.first?.bundleID == W.bundle)

        let otherToken = hasAfter ? before.scene : after.scene
        #expect(otherToken.token != seen.scene.token)
        #expect(await recorder.enrich(otherToken).knowledge == nil)
        var otherBundle = seen.scene
        otherBundle.bundleID = "com.example.Other"
        #expect(await recorder.enrich(otherBundle).knowledge == nil)
        #expect(await store.reads.count == 1)
        await memory.close()
    }
}

private actor InputBrainStore: BrainReading, BrainApplicationStoring, BrainRelationReading {

    struct Read: Sendable {
        let skeleton: SceneSkeleton
        let isComplete: Bool
        let bundleID: String
    }

    private(set) var reads: [Read] = []

    func brain(of bundleID: String) async throws -> UIBrain? { nil }

    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        throw UnexpectedWrite()
    }

    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }

    func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? {
        reads.append(Read(skeleton: skeleton, isComplete: isComplete, bundleID: bundleID))
        return "known"
    }

    func state(of sample: CaptureSampleKey) async throws -> String? { nil }

    func relations(
        from sceneID    : String,
        in bundleID     : String,
        elementKeys     : [String],
        includingContext: Bool
    ) async throws -> [BrainRelation] { [] }

    private struct UnexpectedWrite: Error {}
}
