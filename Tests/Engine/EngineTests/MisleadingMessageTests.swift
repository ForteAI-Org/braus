import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
import Switches
import Testing
@testable import Engine

struct MisleadingMessageTests {
    @Test func uncertainCausePreservesEvidence() throws {
        let error = GestureEffectUncertain(cause: "remote_content_refused.selection_not_verified", description: "fake-private-value")
        for prior in [nil, OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                                          expected: "fake-value", performed: .requested)] {
            let original = ActOutcome(.actedUnverified, "Historical bytes", check: prior)
            let result = ActionEngine.preservingCause(error, in: original)
            #expect(result.cause == error.cause)
            #expect(result.message == original.message)
            #expect(result.check?.performed == .uncertain)
            #expect(result.check?.limits.contains(.deliveryUncertain) == true)
            #expect(result.check?.condition == (prior?.condition ?? .structuralEffect))
            #expect(result.outcome.gesture == .uncertain)
            #expect(ActionEngine.preservingCause(NSError(domain: "fake", code: 1), in: original) == original)
        }
    }

    @Test(arguments: ["v1", "v2"])
    func openMenuWithVisibleChoice(_ arm: String) async throws {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": arm])) {
            let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let choice = SceneElement(id: "choice", kind: .control, label: "Blue",
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1), role: "AXMenuItem")
            let readback = SceneElement(id: "control", kind: .control, label: "Colour",
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1), role: "AXPopUpButton", value: "Blue")
            func window(_ elements: [SceneElement]) -> PerceivedWindow {
                PerceivedWindow(scene: SceneSnapshot(bundleID: "fake.app", appName: "Fake", windowTitle: "Window",
                    viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: elements), frame: frame)
            }
            let engine = ActionEngine(ActionEngine.Dependencies(
                scenes: ActionEngineTests.ScriptedScenes([window([readback])]),
                actuator: ActionEngineTests.RecordingActuator(),
                windows: ActionEngineTests.ScriptedWindows([[WindowRow(layer: 101, frame: frame, title: nil, number: 9)]]),
                controls: ActionEngineTests.FakeControls()
            ), pause: { _ in })
            let result = await engine.judged(.sent(.unattested),
                ActionRequest(processID: 42, bundleID: "fake.app", appName: "Fake", target: "Blue", verb: .click),
                element: choice, perceived: window([choice]))
            #expect(result?.check?.verdict == (arm == "v2" ? .passed : .failed))
            #expect(result?.check?.condition == (arm == "v2" ? .menuItemChosen : .menuClosedAfterChoice))
            #expect(result?.outcome.row == (arm == "v2" ? "sent · confirmed · continue" : "sent · absent · retry"))
        }
    }
}
