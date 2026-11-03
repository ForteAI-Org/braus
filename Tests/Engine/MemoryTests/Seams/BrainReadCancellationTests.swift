import Foundation
import EngineCore
@testable import Memory
import PerceptionCore
import Testing

struct BrainReadCancellationTests {
    private func scene() -> SceneSnapshot {
        SceneSnapshot(bundleID: "example.editor", appName: "Editor", windowTitle: "Document",
                      viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
                      elements: [SceneElement(id: "control", kind: .control, label: "Open",
                                              bounds: Fixtures.rect(0.1, 0.1, 0.1, 0.1))])
    }

    @Test func stopBeforeEnrichmentDoesNoDerivedRead() async {
        let store = ReadStore()
        let memory = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let live = scene()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await memory.enrich(live)
        }
        #expect(await task.value == live)
        #expect(await store.reads == 0)
        #expect(await memory.diagnostics().failedReads == 0)
    }

    @Test func stopIsNotReportedAsMemoryFailure() async {
        let store = ReadStore(cancel: true)
        let memory = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let live = scene()
        #expect(await memory.enrich(live) == live)
        #expect(await memory.diagnostics().failedReads == 0)
    }

    @Test func nextReadingStartsFresh() async {
        let store = ReadStore()
        let memory = BrainMemory(brains: store, applications: store, clock: { .distantPast })
        let live = scene()
        let expected = await memory.enrich(live)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await memory.enrich(live)
        }
        _ = await task.value
        #expect(await memory.enrich(live) == expected)
        #expect(await store.reads == 2)
    }
}

private actor ReadStore: BrainReading, BrainApplicationStoring {
    private(set) var reads = 0
    let cancel: Bool
    init(cancel: Bool = false) { self.cancel = cancel }
    func brain(of bundleID: String) async throws -> UIBrain? {
        reads += 1
        if cancel { throw CancellationError() }
        return UIBrain()
    }
    func projection(of bundleID: String, for detections: [BrainDetection]) async throws -> UIBrain? {
        try await brain(of: bundleID)
    }
    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        BrainApplicationResult(receipt: .committed, applicationID: 1, outcome: .noEffect,
                               requestedAtMS: 0, effectiveAtMS: 0)
    }
    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
}
