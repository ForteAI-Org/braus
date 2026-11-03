import CoreGraphics
import Switches
import EngineCore
import PerceptionCore
import Testing
@testable import Engine

struct GestureExpectTests {
    private func scene(_ value: String?) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Panel",
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                SceneElement(id: "display", kind: .control, label: "Display",
                    bounds: .init(x: 0, y: 0, width: 1, height: 1), role: "AXTextField", value: value)])
    }

    @Test func finalValueDecidesAndSavedCheckContainsNoValue() {
        let expected = ScreenExpectation.element(label: "Display", expect: .value("123"))
        let outcome = ActOutcome(.actedUnverified, "Delivered", check: .init(condition: .structuralEffect,
            method: .sceneDifference, verdict: .unknown, limits: [.noExpectation], performed: .requested))
        for (value, verdict) in [("123", OperationCheck.Verdict.passed), ("124", .failed)] {
            let result = ActionEngine.expectationOutcome(expected, outcome: outcome, before: scene("12"),
                after: scene(value), windows: nil, comparable: true)
            #expect(result.check?.verdict == verdict)
            #expect(result.check?.expected == "element")
            #expect(result.check?.observed?.contains("123") != true)
            #expect(result.check?.limits.contains(.noExpectation) == false)
        }
        let unread = ActionEngine.expectationOutcome(expected, outcome: outcome, before: scene("12"),
            after: scene(nil), windows: nil, comparable: true)
        #expect(unread.check?.verdict == .unknown)
        #expect(unread.check?.limits.contains(.readbackUnavailable) == true)
        let partial = ActionEngine.expectationOutcome(expected, outcome: outcome, before: scene("12"),
            after: scene("123"), windows: nil, comparable: false)
        #expect(partial.check?.verdict == .unknown)
        let already = ActionEngine.expectationOutcome(expected, outcome: outcome, before: scene("123"),
            after: scene("123"), windows: nil, comparable: true)
        #expect(already.kind == .actedUnverified)
        #expect(already.check?.verdict == .failed)
        #expect(already.noop == .statePresent)
    }
    @Test func boundExpectationIsCheckedEvenWithTheSchemaOff() async {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["expect": "off"])) {
            let before = PerceivedWindow(scene: scene("12"), frame: .zero)
            let after = PerceivedWindow(scene: scene("124"), frame: .zero)
            let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([after]),
                actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]])),
                pause: { _ in })
            let trace = VerdictTrace()
            trace.record(before: before, target: nil, method: .sceneDifference) { _ in
                ActOutcome(.foundActed, "Read", scene: after.scene)
            }
            let outcome = ActOutcome(.foundActed, "Changed", scene: after.scene,
                check: .init(condition: .structuralEffect, method: .sceneDifference,
                    verdict: .passed, performed: .requested))
            let result = await ScreenExpectation.$current.withValue(.element(label: "Display", expect: .value("123"))) {
                await VerdictTrace.$current.withValue(trace) {
                    await engine.concluded(outcome, settles: ActionEngine.SettleTrail(), in: 42)
                }
            }
            #expect(result.check?.verdict == .failed)
        }
    }

}

struct ActionVerdictExpectationTests {
    @Test func observerReceivesTheFinalExpectationCheck() async throws {
        let element = SceneElement(id: "display", kind: .control, label: "Display",
            bounds: .init(x: 0, y: 0, width: 1, height: 1), role: "AXTextField", value: "12")
        let before = PerceivedWindow(scene: SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Panel",
            viewportPixelSize: .init(width: 100, height: 100), elements: [element]), frame: .zero)
        var changed = element
        changed.value = "123"
        let after = PerceivedWindow(scene: SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Panel",
            viewportPixelSize: .init(width: 100, height: 100), elements: [changed]), frame: .zero)
        let observer = ActionEngineTests.RecordingObserver()
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([after]),
            actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]),
            observer: observer), pause: { _ in })
        let trace = VerdictTrace()
        trace.hold(ActionRecord(bundleID: "test.app", element: element, verb: .click,
            effect: .valueChanged(label: "Display", value: "123"), windowTitleAfter: nil,
            before: before, after: after))
        let outcome = ActOutcome(.foundActed, "Changed", scene: after.scene,
            check: .init(condition: .structuralEffect, method: .sceneDifference,
                verdict: .passed, limits: [.noExpectation], performed: .requested))
        let final = await ScreenExpectation.$current.withValue(.element(label: "Display", expect: .value("123"))) {
            await VerdictTrace.$current.withValue(trace) {
                await engine.concluded(outcome, settles: ActionEngine.SettleTrail(), in: 42)
            }
        }
        for record in trace.heldRecords() { await engine.publish(record, outcome: final, ending: nil) }
        let check = try #require(observer.records.last?.check)
        #expect(check.verdict == .passed)
        #expect(check.expected == "element")
        #expect(!check.limits.contains(.noExpectation))
        #expect(check.observed?.contains("123") != true)
    }
}
