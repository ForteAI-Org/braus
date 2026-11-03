import CoreGraphics
import EngineCore
@testable import Engine
import PerceptionCore
import Switches
import Testing

@Suite("Evidence record paths")
struct EvidencePathTests {
    @Test func toggleAndRefusal() async throws {
        var off = GestureEvidenceTests.element("toggle", value: "Option")
        off.kind = .control
        off.role = "AXCheckBox"
        off.state = .off
        var on = off
        on.state = .on
        let observer = ActionEngineTests.RecordingObserver()
        let engine = ActionEngine(.init(
            scenes: ActionEngineTests.ScriptedScenes([GestureEvidenceTests.window([off]), GestureEvidenceTests.window([on])]),
            actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]),
            controls: ActionEngineTests.FakeControls(toggle: .on), observer: observer), pause: { _ in })
        _ = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X", target: "Option",
                                          verb: .setToggle, desiredState: .on))
        let record = try #require(observer.records.last)
        #expect(record.evidence != nil)
        #expect(record.evidence?.learnableEffect == record.effect)
        let refused = ActionEngineTests.RecordingObserver()
        let other = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([GestureEvidenceTests.window([off])]),
            actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]), observer: refused), pause: { _ in })
        _ = await other.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X", target: "Option",
                                         verb: .setToggle))
        await other.record(ActionRecord(bundleID: "com.x", element: off, verb: .click, effect: nil,
            windowTitleAfter: nil, before: GestureEvidenceTests.window([off]), attempt: .notAttempted(reason: "refused")))
        let refusal = try #require(refused.records.last)
        #expect(refusal.after == nil && refusal.evidence == nil)
    }

    @Test func finalSecondLook() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["verdict_v2": "on", "second_look": "on"])) {
            var off = GestureEvidenceTests.element("toggle", value: "Option")
            off.kind = .control
            off.role = "AXCheckBox"
            off.state = .off
            var on = off
            on.state = .on
            let observer = ActionEngineTests.RecordingObserver()
            let actuator = SecondLookRecordTests.CountingActuator()
            let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([
                GestureEvidenceTests.window([off]), GestureEvidenceTests.window([off]), GestureEvidenceTests.window([on])]),
                actuator: actuator, windows: ActionEngineTests.ScriptedWindows([[]]), observer: observer,
                settling: SecondLookRecordTests.ScriptedSettler()), pause: { _ in })
            let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                         target: "Option", verb: .click))
            let record = try #require(observer.records.last)
            #expect(record.evidence?.lookedAgain == true)
            #expect(record.evidence?.waited == outcome.waited)
            #expect(record.evidence?.learnableEffect == record.effect)
            #expect(record.evidence?.verdictEffect?.kind == .state)
            #expect(actuator.attempts == 1)
        }
    }

    @Test func expectationRetainsEvidenceWithSecondLookOff() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["second_look": "off"])) {
            let before = GestureEvidenceTests.window([GestureEvidenceTests.element(value: "12")])
            let after = GestureEvidenceTests.window([GestureEvidenceTests.element(value: "123")])
            let observer = ActionEngineTests.RecordingObserver()
            let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([]),
                actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]),
                observer: observer), pause: { _ in })
            let trace = VerdictTrace()
            await ScreenExpectation.$current.withValue(.element(label: "Display", expect: .value("123"))) {
                await VerdictTrace.$current.withValue(trace) {
                    await engine.record(ActionRecord(bundleID: "com.x", element: before.scene.elements[0],
                        verb: .click, effect: nil, windowTitleAfter: after.scene.windowTitle,
                        before: before, after: after))
                }
            }
            #expect(observer.records.isEmpty)
            let held = try #require(trace.heldRecords().last)
            #expect(held.evidence?.comparable == true)
            #expect(held.evidence?.changes.count == 1)
            #expect(held.evidence?.learnableEffect == nil)
        }
    }

    @Test func popup() async throws {
        let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
        let popup = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56), title: nil, number: 9)
        let rows = [307.0, 335.0].enumerated().map { index, y in
            SceneElement(id: "row\(index)", kind: .text, label: index == 0 ? "48000" : "96000",
                bounds: NormalizedRect(x: 0.22, y: (y - 100) / 800, width: 0.05, height: 14.0 / 800))
        }
        let before = PerceivedWindow(scene: GestureEvidenceTests.window(rows).scene, frame: frame)
        let after = PerceivedWindow(scene: GestureEvidenceTests.window([]).scene, frame: frame)
        let observer = ActionEngineTests.RecordingObserver()
        let controls = ActionEngineTests.FakeControls()
        controls.menuItemPresses = true
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([before, after]),
            actuator: ActionEngineTests.RecordingActuator(),
            windows: ActionEngineTests.ScriptedWindows([[popup], []]), controls: controls, observer: observer),
            pause: { _ in })
        _ = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X", target: "96000", verb: .click))
        let record = try #require(observer.records.last)
        #expect(record.evidence != nil)
        #expect(record.evidence?.learnableEffect == record.effect)
    }

    @Test(arguments: [false, true])
    func input(isKey: Bool) async throws {
        let before = GestureEvidenceTests.window([GestureEvidenceTests.element()])
        let after = GestureEvidenceTests.window([GestureEvidenceTests.element(value: "123")])
        let observer = ActionEngineTests.RecordingObserver()
        let controls = ActionEngineTests.FakeControls()
        controls.focus = [.ordinary(TargetIdentity("field"))]
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([before, after]),
            actuator: ActionEngineTests.RecordingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]),
            controls: controls, observer: observer), pause: { _ in })
        let input: InputRequest.Input = isKey ? .pressKey(KeyChord(.return), times: 1) : .insertText("123", expecting: nil)
        _ = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X", input: input))
        let record = try #require(observer.inputs.last)
        #expect(record.evidence != nil)
        #expect(record.evidence?.learnableEffect == record.effect)
    }
}
