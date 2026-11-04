import AutomationRuntime
import AutomationMCP
import LocalMCP
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Synchronization
import Testing

struct BrainReadRecorderTests {
    @Test @MainActor
    func abandonedResultNeverReachesModelOrLatestScene() async throws {
        let service = try W.service()
        let wait = InterruptibleWait()
        let store = StoppedProjection(stop: wait)
        let brain = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let recorder = CallRecorder(memory: service, brain: brain,
            context: ActionContext(source: .app, streamID: "reader", traceID: "late-scene", sessionID: "s1"))
        let session = Session(recorder: recorder)
        let tools = AutomationTools(session: session)
        do {
            try await recorder.begin(.act(target: "Open", verb: .click, value: nil, section: nil),
                                     app: AppContextIdentity(bundleID: W.bundle))
            let result = try await InterruptibleWait.$current.withValue(wait) {
                try await tools.call("act", .object([
                    "target": .string("Open")
                ]))
            }
            #expect(!String(describing: result).contains("Late scene canary"))
            #expect(tools.latestScene == nil)
            #expect(session.gestures == 1)
            #expect(await store.reads == 1)
            #expect(wait.stopRequested)
            #expect(!Task.isCancelled)
            let outcome = try #require(session.outcome)
            try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message),
                                   tool: .act, check: outcome.check)
            #expect(await brain.diagnostics().failedReads == 0)
        } catch {
            await service.close()
            throw error
        }
        await service.close()
    }

    @Test @MainActor
    func expiredBatchStepRetainsItsCompletedScene() async throws {
        let service = try W.service()
        let store = StoppedProjection()
        let brain = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let recorder = CallRecorder(memory: service, brain: brain,
            context: ActionContext(source: .app, streamID: "reader", traceID: "batch-cap", sessionID: "s1"))
        let session = Session(recorder: recorder)
        do {
            let result = try await BatchStepBoundary.perform(until: .now) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while InterruptibleWait.current?.stopRequested != true && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                try #require(InterruptibleWait.current?.stopRequested == true)
                return try await session.act(target: "Open", verb: .click, section: nil, desiredState: nil)
            }
            #expect(result.scene?.windowTitle == "Late scene canary")
            #expect(session.gestures == 1)
            #expect(await store.reads == 1)
        } catch {
            await service.close()
            throw error
        }
        await service.close()
    }

    @MainActor
    private final class Session: AutomationSessionOperating {
        let id: UUID? = UUID()
        let recorder: CallRecorder
        var gestures = 0
        var outcome: ActOutcome?
        init(recorder: CallRecorder) { self.recorder = recorder }
        func open(application: String, window: String?) async throws -> SceneSnapshot { throw CancellationError() }
        func observe() async throws -> SceneSnapshot { throw CancellationError() }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            let result = try await PerceivedCommand.perform(bundleID: W.bundle, recorder: recorder,
                perceive: { W.window([W.open], title: "Late scene canary") }) { observe in
                    self.gestures += 1
                    let check = OperationCheck(condition: .windowSetChanged, method: .windowCensus,
                                               verdict: .unknown, performed: .requested)
                    return ActOutcome(.actedUnverified, "Completed", scene: try await observe(), check: check)
                }
            outcome = result
            return result
        }
        func select(control: String, item: String) async throws -> ActOutcome { throw CancellationError() }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw CancellationError() }
        func close() async {}
    }

    @Test func essentialFactsAndCleanupSurvive() async throws {
        let service = try W.service()
        let store = StoppedProjection()
        let brain = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let recorder = CallRecorder(memory: service, brain: brain,
            context: ActionContext(source: .app, streamID: "reader", traceID: "stop", sessionID: "s1"))
        let wait = InterruptibleWait()
        wait.requestStop()
        do {
            try await InterruptibleWait.$current.withValue(wait) {
                try await recorder.begin(.observe(full: false), app: AppContextIdentity(bundleID: W.bundle))
                let scene = await recorder.observe(W.window([W.open]))
                #expect(scene == W.window([W.open]).scene)
                #expect(!Task.isCancelled)
                try await recorder.end(.completed, result: nil, tool: .observe)
            }
            #expect(await store.reads == 0)
            #expect(await service.flush(within: .seconds(5)))
            let call = try #require(try await service.call(recorder.eventID))
            #expect(call.progress.status == .completed)
            let status = await service.status()
            #expect(status.state == .open && status.failed == 0)
            #expect(await recorder.lastObservation != nil)
            #expect(await brain.diagnostics().failedReads == 0)
        } catch {
            await service.close()
            throw error
        }
        await service.close()
    }
}

private actor StoppedProjection: BrainReading, BrainApplicationStoring {
    private(set) var reads = 0
    let stop: InterruptibleWait?
    init(stop: InterruptibleWait? = nil) { self.stop = stop }
    func brain(of bundleID: String) async throws -> UIBrain? {
        reads += 1
        stop?.requestStop()
        return UIBrain()
    }
    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        BrainApplicationResult(receipt: .committed, applicationID: 1, outcome: .noEffect,
                               requestedAtMS: 0, effectiveAtMS: 0)
    }
    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
}
