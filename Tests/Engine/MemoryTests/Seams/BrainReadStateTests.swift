import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Synchronization
import Testing

struct BrainReadStateTests {
    @Test(.timeLimit(.minutes(1)))
    func stopDuringStateRead() async {
        let store = Store()
        let memory = BrainMemory(brains: store, applications: store, relations: store, clock: { .distantPast })
        let live = SceneSnapshot(bundleID: "example.editor", appName: "Editor", windowTitle: "Document",
                                 viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
                                 elements: [SceneElement(id: "open", kind: .control, label: "Open",
                                                         bounds: Fixtures.rect(0.1, 0.1, 0.1, 0.1))])
        let wait = InterruptibleWait()
        let control = BrainReadControl(shouldStop: { wait.stopRequested })
        let finished = Mutex(false)
        let published = Mutex(0)
        wait.open()
        let caller = Task {
            let result = await wait.reading {
                let result = await BrainReadControl.$current.withValue(control) {
                    await memory.enrich(live, sample: CaptureSampleKey(eventID: "sample", phase: .current))
                }
                finished.withLock { $0 = true }
                return result
            }
            if result != nil { published.withLock { $0 += 1 } }
            return result
        }
        while !store.entered.withLock({ $0 }) { await Task.yield() }
        let stoppedAt = ContinuousClock.now
        wait.requestStop()
        #expect(await caller.value == nil)
        let callerDelay = stoppedAt.duration(to: .now)
        #expect(!caller.isCancelled)
        await store.release()
        while !finished.withLock({ $0 }) { await Task.yield() }
        let workDelay = stoppedAt.duration(to: .now)
        print("Stopped read: caller returned in \(callerDelay); derived work ended in \(workDelay)")
        #expect(workDelay >= callerDelay)
        #expect(await store.relationReads == 0)
        #expect(published.withLock { $0 } == 0)
        #expect(await memory.diagnostics().failedReads == 0)
        let fresh = await memory.enrich(live, state: nil)
        #expect(fresh.knowledge?.status == .unrecognized)
    }

    private actor Store: BrainReading, BrainApplicationStoring, BrainRelationReading {
        nonisolated let entered = Mutex(false)
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var relationReads = 0

        func brain(of bundleID: String) async throws -> UIBrain? { UIBrain() }
        func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
        func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
            BrainApplicationResult(receipt: .committed, applicationID: 1, outcome: .noEffect,
                                   requestedAtMS: 0, effectiveAtMS: 0)
        }
        func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? { nil }
        func state(of sample: CaptureSampleKey) async throws -> String? {
            await withCheckedContinuation {
                continuation = $0
                entered.withLock { $0 = true }
            }
            return "state"
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
        func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                       includingContext: Bool) async throws -> [BrainRelation] {
            relationReads += 1
            return []
        }
    }
}
