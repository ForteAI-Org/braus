import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

@Suite("Insert text read back")
struct InsertTextReadBackTests {
    @Test("read back records only the verdict and withholds values", arguments: ["matches", "differs", "not_read"])
    func valueIsWithheld(readback: String) async throws {
        let expected = "synthetic-expected-12345678"
        let observed = readback == "not_read" ? nil : readback == "matches" ? expected : "synthetic-observed-87654321"
        let controls = ActionEngineTests.FakeControls()
        controls.focus = [.ordinary(TargetIdentity("fixture-node"))]
        controls.focused = observed
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scene = PerceivedWindow(scene: SceneSnapshot(
            bundleID: "test.app", appName: "Test", windowTitle: "Editor",
            viewportPixelSize: .init(width: 800, height: 600), elements: []
        ), frame: frame)
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes: ActionEngineTests.ScriptedScenes([scene]),
            actuator: ActionEngineTests.RecordingActuator(),
            windows: ActionEngineTests.ScriptedWindows([[WindowRow(layer: 0, frame: frame, title: "Editor", number: 1)]]),
            controls: controls
        ), pause: { _ in })
        let outcome = await engine.deliver(InputRequest(
            processID: 4242, bundleID: "test.app", appName: "Test",
            input: .insertText("synthetic", expecting: expected)
        ))
        let check = try #require(outcome.check)
        #expect(check.verdict == (readback == "matches" ? .passed : readback == "differs" ? .failed : .unknown))
        #expect(check.expected == nil)
        // Schema 22 stores matches, differs or not_read in memory_gesture_evidence.readback.
        // Neither comparison value belongs in expected or observed.
        #expect(check.observed == nil)
        #expect(check.limits.contains(.readbackUnavailable) == (readback == "not_read"))
        #expect(check.limits.contains(.valueWithheld))
        for value in [expected, observed].compactMap({ $0 }) {
            for index in 0...(value.count - 8) {
                let start = value.index(value.startIndex, offsetBy: index)
                let end = value.index(start, offsetBy: 8)
                #expect(!outcome.message.contains(value[start..<end]))
            }
        }
    }

    @Test("uncompared and uncertain insertions keep values out of their checks", arguments: [false, true])
    func unconfirmedValuesAreWithheld(fails: Bool) async throws {
        let expected = "synthetic-private-expectation"
        let controls = ActionEngineTests.FakeControls()
        controls.focus = [.ordinary(TargetIdentity("fixture-node"))]
        controls.focused = expected
        let actuator = ActionEngineTests.RecordingActuator()
        if fails { actuator.failure = CocoaError(.userCancelled) }
        let scene = PerceivedWindow(scene: SceneSnapshot(
            bundleID: "test.app", appName: "Test", windowTitle: "Editor",
            viewportPixelSize: .init(width: 800, height: 600), elements: []
        ), frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let engine = ActionEngine(.init(
            scenes: ActionEngineTests.ScriptedScenes([scene]), actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), controls: controls
        ), pause: { _ in })
        let outcome = await {
            await engine.deliver(InputRequest(
                processID: 4242, bundleID: "test.app", appName: "Test",
                input: .insertText("synthetic", expecting: fails ? expected : nil)
            ))
        }()
        let check = try #require(outcome.check)
        #expect(check.verdict == (fails ? .passed : .unknown))
        #expect(check.expected == nil && check.observed == nil)
        #expect(check.limits.contains(.valueWithheld))
        #expect(!outcome.message.contains(expected))
    }

}
