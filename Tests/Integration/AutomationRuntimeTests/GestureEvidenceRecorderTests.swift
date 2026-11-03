@testable import AutomationRuntime
import EngineCore
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

@Suite("Gesture evidence recorder")
struct GestureEvidenceRecorderTests {
    @Test func inputReachesTheArchive() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        let before = W.window([W.open]), after = W.window([W.open, W.save])
        try await recorder.begin(.insertText(text: "fixture", expectedValue: nil), app: AppContextIdentity(bundleID: W.bundle))
        let evidence = SceneEvidence.observe(before: before, after: after, target: nil,
                                             learnableEffect: .elementsAppeared(labels: ["Save"]))
        await recorder.record(InputRecord(bundleID: W.bundle, input: .insertText("fixture", expecting: nil),
            target: nil, before: before, after: after, effect: evidence.learnableEffect, evidence: evidence))
        try await recorder.end(.completed, result: .outcome(.foundActed, message: "Changed"), tool: .insertText)
        #expect(await memory.flush(within: .seconds(5)))
        let store = try await SQLiteMemoryStore.open(at: memory.url)
        let counts = try await store.read { snapshot in
            try snapshot.query("SELECT (SELECT count(*) FROM memory_gesture_evidence), (SELECT count(*) FROM memory_gesture_changes)") {
                [$0.integer(0), $0.integer(1)]
            }
        }
        #expect(counts == [[1, 1]])
        await memory.close()
    }
}
