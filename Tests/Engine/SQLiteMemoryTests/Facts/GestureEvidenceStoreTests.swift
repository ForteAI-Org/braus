import CoreGraphics
import EngineCore
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

@Suite("Gesture evidence storage")
struct GestureEvidenceStoreTests {
    @Test(arguments: [true, false])
    func persisted(comparable: Bool) async throws {
        let memory = try await TaskFixtures.open22()
        let call = "gesture"
        _ = try await memory.facts.open(OperationOpening(call: OperationFactRepositoryTests.click(call),
                                                        startedAtMS: TaskFixtures.t0))
        func window(_ value: String) -> PerceivedWindow {
            PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: ["display", "other"].map { id in
                    SceneElement(id: id, kind: .text, label: value,
                        bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                        role: "AXStaticText", value: value, container: "Report.docx") }), frame: .zero,
                capture: comparable ? .unknown : CaptureQuality(walkCompleted: false, windowFound: true))
        }
        let evidence = SceneEvidence.observe(before: window("12"), after: window("123"), target: nil, learnableEffect: .valueChanged(label: "12", value: "123"))
            .withWait(lookedAgain: true, waited: .milliseconds(123), ending: .capped)
        let end = AgentCallTransition(call, AgentCallProgress(.completed,
            result: .outcome(.foundActed, message: "Changed"), endedAtMS: TaskFixtures.t0 + 1))
        let conclusion = try OperationConclusion(end: end, gestureEvidence: evidence)
        #expect(try await memory.facts.conclude(conclusion) == .committed)
        #expect(try await memory.facts.conclude(conclusion) == .alreadyApplied)
        #expect(try await memory.count("SELECT count(*) FROM memory_gesture_evidence WHERE comparable = \(comparable ? 1 : 0)") == 1)
        #expect(try await memory.count("SELECT count(*) FROM memory_gesture_changes") == (comparable ? 2 : 0))
        #expect(try await memory.count("SELECT count(*) FROM memory_gesture_evidence WHERE looked_again = 1 AND settle_ending = 'capped' AND settle_waited_ms = 123 AND verdict_differs_from_learning = 0") == 1)
        if comparable {
            #expect(try await memory.count("SELECT count(*) FROM memory_gesture_changes WHERE kind = 'native_text' AND subject_key = 'text.AXStaticText@c1#1' AND stability = 'instance_value' AND family = 'valueChanged'") == 1)
            #expect(try await memory.count("SELECT count(*) FROM memory_gesture_evidence WHERE verdict_change_position = 0") == 1)
        }
        let changed = evidence.withWait(lookedAgain: true, waited: .milliseconds(124), ending: .capped)
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(OperationConclusion(end: end, gestureEvidence: changed))
        }
        #expect(try await memory.count("SELECT count(*) FROM memory_gesture_changes") == (comparable ? 2 : 0))
    }
}


extension GestureEvidenceStoreTests {
    @Test(arguments: [String(repeating: "R", count: 600), "R" + String(repeating: "\u{301}", count: 600)])
    func largeEvidenceAndLongRolesDoNotRejectConclusion(role: String) async throws {
        let memory = try await TaskFixtures.open22()
        let call = "large-gesture"
        _ = try await memory.facts.open(OperationOpening(call: OperationFactRepositoryTests.click(call),
                                                        startedAtMS: TaskFixtures.t0))
        func window(_ value: String) -> PerceivedWindow {
            PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                viewportPixelSize: .init(width: 100, height: 100), elements: (0..<300).map { index in
                    SceneElement(id: "field\(index)", kind: .text, label: value,
                        bounds: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                        role: role, value: value)
                }), frame: .zero)
        }
        let evidence = SceneEvidence.observe(before: window("12"), after: window("123"), target: nil,
                                              learnableEffect: nil)
        #expect(evidence.changes.count == 300)
        #expect(evidence.changes.allSatisfy { $0.subject.unicodeScalars.count <= 512 })
        let end = AgentCallTransition(call, AgentCallProgress(.completed,
            result: .outcome(.foundActed, message: "Changed"), endedAtMS: TaskFixtures.t0 + 1))
        let conclusion = try OperationConclusion(end: end, gestureEvidence: evidence)
        #expect(try await memory.facts.conclude(conclusion) == .committed)
        #expect(try await memory.facts.conclude(conclusion) == .alreadyApplied)
        #expect(try await memory.count("SELECT count(*) FROM memory_gesture_changes") == 64)
        #expect(try await memory.count("SELECT count(*) FROM memory_call_recording_gaps WHERE part = 'samples' AND detail = 'Gesture changes truncated: 236 omitted.'") == 1)
    }
}
