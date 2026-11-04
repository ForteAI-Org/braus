import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

@Suite("Final second look evidence")
struct SecondLookRecordTests {
    /// Counts every dispatch attempt, including a delivery that throws before recording a gesture.
    final class CountingActuator: Actuating, @unchecked Sendable {
        let base = ActionEngineTests.RecordingActuator()
        var attempts = 0
        var attemptsAtSecond: Int?
        var gestures: [Gesture] { base.gestures }
        var failure: (any Error)? {
            get { base.failure }
            set { base.failure = newValue }
        }
        var failsFrom: Int {
            get { base.failsFrom }
            set { base.failsFrom = newValue }
        }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            attempts += 1
            try await base.perform(gesture, in: processID)
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
            await base.confirm(effect, in: processID)
        }
        func lastDeliveryRoute(in processID: pid_t) async -> DeliveryRoute { base.route }
    }

    final class ScriptedSettler: Settling, @unchecked Sendable {
        var endings: [SettleResult] = [.capped, .settled]
        var caps: [Duration] = []
        var delay: Duration = .zero
        var onSecond: (@Sendable () -> Void)?
        func settle(in processID: pid_t, cap: Duration) async -> SettleResult {
            caps.append(cap)
            if caps.count == 1, delay > .zero {
                do { try await Task.sleep(for: delay) } catch { Issue.record("Initial wait was cancelled") }
            }
            if caps.count == 2 { onSecond?() }
            return endings.count > 1 ? endings.removeFirst() : endings[0]
        }
    }

    /// A slow before-reading must not spend the budget that starts after delivery.
    struct SlowBeforeScenes: SceneProviding {
        let scenes: ActionEngineTests.ScriptedScenes
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            if scenes.calls == 0 { try await Task.sleep(for: .milliseconds(80)) }
            return try await scenes.currentScene(of: processID)
        }
    }

    final class StopScenes: SceneProviding, @unchecked Sendable {
        let scenes: ActionEngineTests.ScriptedScenes
        let wait: InterruptibleWait
        init(_ scenes: ActionEngineTests.ScriptedScenes, wait: InterruptibleWait) {
            self.scenes = scenes
            self.wait = wait
        }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            if scenes.calls == 2 { wait.requestStop() }
            return try await scenes.currentScene(of: processID)
        }
    }

    private func window(_ state: ControlState) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [
                SceneElement(id: "button", kind: .control, label: "Option",
                    bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), state: state)
            ]), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    actor Signal {
        private var ready = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if ready { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func send() { ready = true; continuation?.resume(); continuation = nil }
    }

    @Test("an orphan rejudge cannot confirm or change settling evidence", arguments: [false, true])
    func orphanRejudge(cancel: Bool) async {
        let wait = InterruptibleWait()
        wait.open()
        let trace = VerdictTrace()
        trace.noteGestureEnded()
        let trail = ActionEngine.SettleTrail()
        let actuator = CountingActuator()
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([window(.off)]),
            actuator: actuator, windows: ActionEngineTests.ScriptedWindows([[]]),
            settling: ScriptedSettler()), pause: { _ in })
        let started = Signal()
        let release = Signal()
        let finished = Signal()
        trace.recordDirectRead {
            await started.send()
            await release.wait()
            await engine.confirm(.observed, in: 42)
            trail.note(.unavailable)
            trail.noteReadBackFromScene()
            await finished.send()
            return ActOutcome(.foundActed, "Seen")
        }
        let first = ActOutcome(.actedUnverified, "Waiting", check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
            limits: [.settleCapped], performed: .requested))
        let task = Task {
            await InterruptibleWait.$current.withValue(wait) {
                await VerdictTrace.$current.withValue(trace) {
                    await engine.concluded(first, settles: trail, in: 42)
                }
            }
        }
        await started.wait()
        if cancel { task.cancel() } else { wait.requestStop() }
        let result = await task.value
        await release.send()
        await finished.wait()
        #expect(result.scene == nil)
        #expect(!result.lookedAgain && !Task.isCancelled)
        #expect(result.outcome.row == "sent · unknown(not_readable) · observe")
        #expect(actuator.base.confirmations.isEmpty)
        #expect(trail.last == .capped && !trail.readBackFromScene)
    }

    @Test("two gestures on the same target keep separate records and only the last is rejudged")
    func repeatedTarget() {
        let trace = VerdictTrace()
        let before = window(.off)
        let after = window(.on)
        let element = before.scene.elements[0]
        func record(_ after: PerceivedWindow) -> ActionRecord {
            ActionRecord(bundleID: "com.x", element: element, verb: .click, effect: nil,
                windowTitleAfter: after.scene.windowTitle, before: before, after: after)
        }
        trace.noteGestureEnded()
        trace.hold(record(before))
        trace.noteGestureEnded()
        trace.hold(record(before))
        VerdictTrace.$isRejudging.withValue(true) { trace.hold(record(after)) }
        #expect(trace.heldRecords().count == 2)
        #expect(trace.heldRecords().first?.after == before)
        #expect(trace.heldRecords().last?.after == after)
    }

    @Test("one final record compares the late scene to the original, with one gesture")
    func finalRecord() async {
        let scenes = ActionEngineTests.ScriptedScenes([window(.off), window(.off), window(.on)])
        let actuator = CountingActuator()
        let observer = ActionEngineTests.RecordingObserver()
        let settler = ScriptedSettler()
        settler.delay = .milliseconds(60)
        settler.onSecond = { #expect(observer.records.isEmpty) }
        let engine = ActionEngine(.init(scenes: SlowBeforeScenes(scenes: scenes), actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), observer: observer, settling: settler), pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                    target: "Option", verb: .click))
        #expect(outcome.check?.verdict == .passed)
        #expect(actuator.gestures.count == 1 && actuator.attempts == 1)
        #expect(observer.records.count == 1)
        #expect(observer.records.first?.before == window(.off))
        #expect(observer.records.first?.after == window(.on))
        #expect(scenes.calls == 3)
        #expect(settler.caps.count == 2)
        if let cap = settler.caps.last {
            #expect(cap <= .milliseconds(940))
            #expect(cap >= .milliseconds(890))
        }
    }

    @Test("takeover cuts the second look without cancelling the caller or repeating input", arguments: [false, true])
    func stopped(uncertain: Bool) async {
        let wait = InterruptibleWait()
        await InterruptibleWait.$current.withValue(wait) {
            let scenes = ActionEngineTests.ScriptedScenes([window(.off), window(.off), window(.on)])
            let actuator = CountingActuator()
            if uncertain { actuator.failure = GestureEffectUncertain(cause: "test", description: "Uncertain") }
            let observer = ActionEngineTests.RecordingObserver()
            let settler = ScriptedSettler()
            settler.onSecond = { if !uncertain { wait.requestStop() } }
            let engine = ActionEngine(.init(scenes: StopScenes(scenes, wait: wait), actuator: actuator,
                windows: ActionEngineTests.ScriptedWindows([[]]), observer: observer, settling: settler), pause: { _ in })
            let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                        target: "Option", verb: .click))
            #expect(outcome.scene == nil)
            #expect(observer.records.count == 1 && observer.records.first?.after == nil)
            #expect(outcome.check?.limits.contains(.noAfterScene) == true)
            #expect(outcome.check?.performed == (uncertain ? .uncertain : .requested))
            #expect(!Task.isCancelled)
            #expect(outcome.outcome.row == (uncertain
                ? "uncertain · unknown(not_readable) · do_not_repeat"
                : "sent · unknown(not_readable) · observe"))
            #expect(settler.caps.count == (uncertain ? 1 : 2))
            #expect(actuator.gestures.count == (uncertain ? 0 : 1))
            #expect(actuator.attempts == 1)
        }
    }
    @Test("insert text rereads the value without another scene or gesture")
    func lateText() async {
        let controls = ActionEngineTests.FakeControls()
        controls.focus = [.ordinary(TargetIdentity("field"))]
        let scenes = ActionEngineTests.ScriptedScenes([window(.off)])
        let actuator = CountingActuator()
        let settler = ScriptedSettler()
        settler.onSecond = { controls.focused = "Done" }
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), controls: controls, settling: settler), pause: { _ in })
        let outcome = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                        input: .insertText("Done", expecting: "Done")))
        #expect(outcome.check?.verdict == .passed)
        #expect(actuator.gestures.count == 1 && actuator.attempts == 1)
        #expect(scenes.calls == 2)
    }

    @Test("without a settling role, polling ends on two equal readings")
    func polling() async {
        let scenes = ActionEngineTests.ScriptedScenes([window(.on), window(.on)])
        let actuator = CountingActuator()
        let pauses = SettlingTests.Pauses()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { pauses.slept.append($0) })
        let trace = VerdictTrace()
        trace.noteGestureEnded()
        let settles = ActionEngine.SettleTrail()
        settles.note(.capped)
        let first = ActOutcome(.actedUnverified, "Waiting", check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
            limits: [.settleCapped], performed: .requested))
        trace.record(before: window(.off), target: nil, method: .sceneDifference) { after in
            ActOutcome(.foundActed, "Seen", scene: after.scene, check: OperationCheck(
                condition: .structuralEffect, method: .sceneDifference, verdict: .passed, performed: .requested))
        }
        let outcome = await VerdictTrace.$current.withValue(trace) {
            await engine.concluded(first, settles: settles, in: 42)
        }
        #expect(outcome.check?.verdict == .passed && outcome.lookedAgain)
        #expect(scenes.calls == 2)
        #expect(pauses.slept == [.milliseconds(250)])
        #expect(actuator.gestures.isEmpty)
    }

    @Test("an unknown second result never earns a third look")
    func onlyOnce() async {
        let scenes = ActionEngineTests.ScriptedScenes([window(.off)])
        let actuator = CountingActuator()
        let settler = ScriptedSettler()
        settler.endings = [.capped, .capped]
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), settling: settler), pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                    target: "Option", verb: .click))
        #expect(outcome.check?.verdict == .unknown && outcome.lookedAgain)
        #expect(settler.caps.count == 2 && scenes.calls == 3)
        #expect(actuator.gestures.count == 1 && actuator.attempts == 1)
    }

    @Test("a seen effect after uncertain delivery has no second look")
    func uncertainConfirmed() async {
        let scenes = ActionEngineTests.ScriptedScenes([window(.off), window(.on)])
        let actuator = CountingActuator()
        actuator.failure = GestureEffectUncertain(cause: "test", description: "Uncertain")
        let settler = ScriptedSettler()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), settling: settler), pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                    target: "Option", verb: .click))
        #expect(outcome.check?.verdict == .passed && outcome.check?.performed == .uncertain)
        #expect(!outcome.lookedAgain)
        #expect(settler.caps.count == 1 && scenes.calls == 2)
    }

    @Test("an uncertain popup rereads its control once and never sends another key")
    func popupReadBack() async {
        let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
        let popup = WindowRow(layer: 101, frame: CGRect(x: 300, y: 300, width: 220, height: 56), title: nil, number: 9)
        let rows = [307.0, 335.0].enumerated().map { index, y in
            SceneElement(id: "row\(index)", kind: .text, label: index == 0 ? "48000" : "96000",
                bounds: NormalizedRect(x: 0.22, y: (y - 100) / 800, width: 0.05, height: 14.0 / 800))
        }
        let before = PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: rows), frame: frame)
        let scenes = ActionEngineTests.ScriptedScenes([before])
        let controls = ActionEngineTests.FakeControls(values: ["48000", nil, "96000"])
        let actuator = CountingActuator()
        actuator.failure = GestureEffectUncertain(cause: "test", description: "Uncertain")
        actuator.failsFrom = 1
        let observer = ActionEngineTests.RecordingObserver()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[popup], [popup], []]), controls: controls, observer: observer),
            pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                    target: "96000", verb: .click))
        #expect(outcome.check?.verdict == .passed && outcome.check?.performed == .uncertain)
        #expect(outcome.lookedAgain && actuator.gestures.count == 1 && actuator.attempts == 2)
        #expect(scenes.calls == 2 && observer.records.count == 1)
        if case .deliveryFailed? = observer.records.first?.attempt {} else { Issue.record("Lost uncertain delivery") }
    }

    @Test("composed typing shares one trace across its gestures")
    func composedTyping() async {
        func field(_ value: String) -> PerceivedWindow {
            PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [
                    SceneElement(id: "field", kind: .control, label: "Name",
                        bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1), role: "AXTextField", value: value)
                ]), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let scenes = ActionEngineTests.ScriptedScenes([field(""), field(""), field("Done")])
        let actuator = CountingActuator()
        let observer = ActionEngineTests.RecordingObserver()
        let settler = ScriptedSettler()
        settler.onSecond = {
            #expect(actuator.gestures.count > 1)
            actuator.attemptsAtSecond = actuator.attempts
        }
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), controls: ActionEngineTests.FakeControls(),
            observer: observer, settling: settler), pause: { _ in })
        let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                                                      input: .typeText("Done", into: "Name", replacing: true)))
        #expect(result.lookedAgain && result.check?.verdict == .passed)
        #expect(scenes.calls == 3 && settler.caps.count == 2)
        #expect(actuator.attemptsAtSecond == actuator.attempts)
        #expect(observer.inputs.count == 1 && observer.inputs.first?.after == field("Done"))
    }

}

@Suite("Second look trace isolation")
struct VerdictTraceIsolationTests {
    @Test("a following action cannot borrow the previous action's judge")
    func isolated() async {
        let snapshot = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
        let scenes = ActionEngineTests.ScriptedScenes([PerceivedWindow(scene: snapshot, frame: .zero)])
        let actuator = SecondLookRecordTests.CountingActuator()
        let settling = SecondLookRecordTests.ScriptedSettler()
        settling.endings = [.capped, .settled, .capped]
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), settling: settling), pause: { _ in })
        _ = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                                             input: .pressKey(KeyChord(.character("x")), times: 1)))
        let reads = scenes.calls
        _ = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                                             input: .pressKey(KeyChord(.tab), times: 1)))
        #expect(scenes.calls == reads + 2)
        #expect(actuator.gestures.count == 2)
        #expect(settling.caps.count == 3)
        #expect(VerdictTrace.current == nil)

    }
}
