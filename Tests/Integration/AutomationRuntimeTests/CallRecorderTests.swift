import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing

@Suite("Call recorder input perceptions")
struct CallRecorderTests {

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
