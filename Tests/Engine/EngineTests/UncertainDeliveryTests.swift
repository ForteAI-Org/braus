import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Synchronization
import Testing

struct UncertainDeliveryTests {
    struct PostedFailure: Error, CustomStringConvertible {
        var description = "delivery stopped"
    }

    final class FailingActuator: Actuating, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
        let refusal: Bool
        let detail: String
        init(refusal: Bool = false, detail: String = "delivery stopped") {
            self.refusal = refusal
            self.detail = detail
        }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            lock.withLock { count += 1 }
            if refusal { throw GestureNotSent(reason: "human_intervention", sentence: "Stopped.") }
            throw PostedFailure(description: detail)
        }
    }

    private let element = SceneElement(id: "control|field", kind: .control, label: "Name",
        bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1), role: "AXTextField", value: "old")

    private func window(_ title: String, additional: [SceneElement] = []) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: title,
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [element] + additional),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test
    func inputsReadOnceWithoutAnotherGesture() async {
        let inputs: [InputRequest.Input] = [
            .insertText("new", expecting: "new"), .typeText("new", into: "Name", replacing: true),
            .pressKey(KeyChord(.tab), times: 2), .scroll(lines: -2, over: "Name"),
            .drag(from: "Name", to: .offset(dx: 10, dy: 10)), .contextMenu(on: "Name", item: "Copy")
        ]
        for input in inputs {
            let scenes = ActionEngineTests.ScriptedScenes([window("Before"), window("After")])
            let actuator = FailingActuator(detail: "'delivery stopped'")
            let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
                windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
            let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X", input: input))
            #expect(actuator.calls == 1)
            #expect(scenes.calls == 2)
            #expect(result.scene != nil)
            #expect(result.check?.performed == .uncertain)
        }
    }

    @Test(arguments: ["Before", "After"])
    func clickUsesItsOwnVerdict(_ title: String) async {
        let scenes = ActionEngineTests.ScriptedScenes([window("Before"), window(title)])
        let actuator = FailingActuator()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        let result = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X", target: "Name", verb: .click))
        #expect(result.scene != nil)
        #expect(result.outcome.row == (title == "After" ? "uncertain · confirmed · continue" : "uncertain · absent · do_not_repeat"))
        #expect(result.check?.limits.contains(.deliveryUncertain) == true)
        #expect(actuator.calls == 1)
    }

    @Test func refusalDoesNotReadAfterwards() async {
        let scenes = ActionEngineTests.ScriptedScenes([window("Before")])
        let actuator = FailingActuator(refusal: true)
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
            input: .pressKey(KeyChord(.tab), times: 1)))
        #expect(result.outcome.gesture == .notSent)
        #expect(scenes.calls == 1)
    }
}

extension UncertainDeliveryTests {
    @Test func classificationKeepsPartialCountsAndWords() {
        let refusal = GestureNotSent(reason: "human_intervention", sentence: "Stopped.")
        #expect(ActionEngine.delivery(after: refusal, sent: 0) == .notSent(refusal))
        #expect(ActionEngine.delivery(after: refusal, sent: 2) == .uncertain(
            UncertainDelivery(kind: .refusedAfterOthers, sentBefore: 2, detail: "\(refusal)")))
        #expect(ActionEngine.delivery(after: ActionEngine.TextStopped(reason: "focus moved", sentBefore: 3), sent: 3)
            == .uncertain(UncertainDelivery(kind: .stoppedBeforeText, sentBefore: 3, detail: "focus moved")))
    }

    @Test func judgeCannotPostAnotherGesture() async {
        let actuator = FailingActuator()
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([window("Before")]),
            actuator: actuator, windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        let uncertain = UncertainDelivery(kind: .failedAfterEvents, sentBefore: 0, detail: "private detail")
        let result = await engine.afterUncertainDelivery(uncertain, in: 42) {
            let delivery = await engine.send([.key(code: Key.escape)], to: 42)
            if case .notSent = delivery {} else { Issue.record("The judge allowed another gesture") }
            return ActOutcome(.actedUnverified, "read", check: .unchecked(performed: .requested))
        }
        #expect(actuator.calls == 0)
        #expect(result.check?.performed == .uncertain)
        #expect(result.message.contains("delivery failed: private detail"), "The producer keeps the diagnosis; model formatting removes it")
    }
}

extension UncertainDeliveryTests {
    @Test(arguments: ["toggle", "arrows", "typeAhead", "submenu"])
    func actionSitesAttachTheirReading(_ site: String) async {
        let extra = site == "arrows" ? [SceneElement(id: "text|other", kind: .text, label: "Other",
            bounds: NormalizedRect(x: 0.2, y: 0.35, width: 0.2, height: 0.1))] : []
        let scenes = ActionEngineTests.ScriptedScenes([
            window("Before", additional: extra), window("After", additional: extra)
        ])
        let actuator = FailingActuator(detail: "'delivery stopped'")
        let controls = ActionEngineTests.FakeControls(values: site == "arrows" ? ["Other"] : [nil])
        if site == "submenu" {
            controls.submenu = MenuItemNavigation(hasSubmenu: true, row: 1, submenuFrame: nil)
        }
        let rows: [WindowRow] = site == "toggle" ? [] : [WindowRow(layer: 101,
            frame: CGRect(x: 100, y: 60, width: 400, height: 300), title: nil, number: 2)]
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([rows]), controls: controls), pause: { _ in })
        let result = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
            target: "Name", verb: site == "toggle" ? .setToggle : .click, desiredState: .on))
        #expect(actuator.calls == 1)
        #expect(result.scene != nil)
        #expect(result.check?.performed == .uncertain)
        #expect(scenes.calls == (site == "toggle" ? 3 : 2), "Toggle targeting adds its mandatory fresh read before the uncertain delivery")
    }
}

extension UncertainDeliveryTests {
    final class StoppingActuator: Actuating, @unchecked Sendable {
        let wait: InterruptibleWait
        let fails: Bool
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        init(_ wait: InterruptibleWait, fails: Bool) { self.wait = wait; self.fails = fails }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            lock.withLock { count += 1 }
            wait.requestStop()
            #expect(!Task.isCancelled)
            #expect(!wait.isOpen)
            if fails { throw PostedFailure() }
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    @Test(arguments: [false, true])
    func takeoverDuringRightClickNeverChoosesOrEscapes(_ fails: Bool) async {
        let wait = InterruptibleWait()
        let actuator = StoppingActuator(wait, fails: fails)
        let scenes = ActionEngineTests.ScriptedScenes([window("Before"), window("After")])
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        await InterruptibleWait.$current.withValue(wait) {
            let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                input: .contextMenu(on: "Name", item: "Copy")))
            #expect(result.scene == nil)
            #expect(result.outcome.row == (fails ? "uncertain · unknown(not_readable) · do_not_repeat"
                : "sent · unknown(not_readable) · observe"))
            #expect(actuator.calls == 1)
            #expect(scenes.calls == 1)
            #expect(!Task.isCancelled)
            #expect(!wait.isOpen)
        }
    }

    @Test func stopBeforeFirstPostLeavesOpeningReadAlone() async {
        let wait = InterruptibleWait()
        wait.requestStop()
        let scenes = ActionEngineTests.ScriptedScenes([window("Before")])
        let actuator = FailingActuator()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        await InterruptibleWait.$current.withValue(wait) {
            let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                input: .pressKey(KeyChord(.tab), times: 1)))
            #expect(result.notSent == .humanIntervention)
            #expect(result.outcome.gesture == .notSent)
            #expect(scenes.calls == 1)
            #expect(actuator.calls == 0)
        }
    }
}

extension UncertainDeliveryTests {
    @Test func anotherToggleStateIsNotTheRequestedEffect() async {
        let scenes = ActionEngineTests.ScriptedScenes([window("Before"), window("After")])
        let controls = ActionEngineTests.FakeControls(toggle: .off)
        let engine = ActionEngine(.init(scenes: scenes, actuator: FailingActuator(),
            windows: ActionEngineTests.ScriptedWindows([[]]), controls: controls), pause: { _ in })
        let result = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
            target: "Name", verb: .setToggle, desiredState: .on))
        #expect(result.outcome.row == "uncertain · absent · do_not_repeat")
        #expect(result.check?.expected == "on")
        #expect(result.check?.observed == "off")
    }

    @Test func pureMarkKeepsTheSitesEvidence() {
        let prior = OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .passed,
            expected: "wanted", observed: "wanted", performed: .requested)
        let marked = ActionEngine.markedUncertain(ActOutcome(.foundActed, "read", scene: window("After").scene,
            check: prior), UncertainDelivery(kind: .failedAfterEvents, sentBefore: 2, detail: "producer detail"))
        #expect(marked.check?.verdict == prior.verdict)
        #expect(marked.check?.expected == prior.expected)
        #expect(marked.check?.observed == prior.observed)
        #expect(marked.check?.performed == .uncertain)
        #expect(marked.check?.limits == [.deliveryUncertain])
    }
}

extension UncertainDeliveryTests {
    final class TakeoverScenes: SceneProviding, @unchecked Sendable {
        let before: PerceivedWindow
        let wait: InterruptibleWait
        private let lock = NSLock()
        private var count = 0
        init(_ before: PerceivedWindow, wait: InterruptibleWait) { self.before = before; self.wait = wait }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            let call = lock.withLock { count += 1; return count }
            if call > 1 {
                wait.requestStop()
                try await Task.sleep(for: .seconds(30))
            }
            return before
        }
    }

    @Test func stopDuringUncertainReadingReturnsThroughTheCall() async {
        let wait = InterruptibleWait()
        let actuator = FailingActuator()
        let observer = ActionEngineTests.RecordingObserver()
        let engine = ActionEngine(.init(scenes: TakeoverScenes(window("Before"), wait: wait), actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]]), observer: observer), pause: { _ in })
        await InterruptibleWait.$current.withValue(wait) {
            let result = await engine.act(ActionRequest(processID: 42, bundleID: "com.x", appName: "X",
                target: "Name", verb: .click))
            #expect(result.scene == nil)
            #expect(result.outcome.row == "uncertain · unknown(not_readable) · do_not_repeat")
            #expect(!Task.isCancelled)
            #expect(actuator.calls == 1)
            #expect(observer.records.count == 1)
            #expect(observer.records.first?.attempt == .deliveryFailed("delivery stopped"))
        }
    }
}

extension UncertainDeliveryTests {
    struct SecureControls: ControlPressing {
        func pressControl(labelled label: String, in processID: pid_t) async -> Bool { false }
        func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
        func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
        func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? { nil }
        func focusedField(in processID: pid_t) async -> FocusedField { .secure(nil) }
        func focusedFieldValue(in processID: pid_t) async -> String? {
            Issue.record("A secure field must never be read back")
            return nil
        }
    }

    @Test func uncertainSecureTextIsNeverReadBack() async {
        var secure = element
        secure.role = "AXSecureTextField"
        let capture = PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Form",
            viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [secure]),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let inputs: [InputRequest.Input] = [.typeText("hidden", into: "Name", replacing: true),
                                            .insertText("hidden", expecting: "hidden")]
        for input in inputs {
            let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([capture]),
                actuator: FailingActuator(), windows: ActionEngineTests.ScriptedWindows([[]]),
                controls: SecureControls()), pause: { _ in })
            let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X", input: input))
            #expect(result.scene != nil)
            #expect(result.check?.expected == nil && result.check?.observed == nil)
            #expect(result.check?.limits.contains(.valueWithheld) == true)
            #expect(result.check?.performed == .uncertain)
        }
    }
}

extension UncertainDeliveryTests {
    @Test(arguments: [OperationCheck.Verdict.passed, .failed])
    func uncertainRowsRespectObservedVerdict(_ verdict: OperationCheck.Verdict) async {
        let result = ActOutcome(.actedUnverified, "menu receipt", check: OperationCheck(
            condition: .menuItemChosen, method: .controlValue, verdict: verdict,
            limits: [.deliveryUncertain], performed: .uncertain))
        #expect(result.outcome.row == (verdict == .passed ? "uncertain · confirmed · continue" : "uncertain · absent · do_not_repeat"))
    }

    @Test func uncertainMarkPreservesJudgeCause() {
        let result = ActionEngine.markedUncertain(ActOutcome(.actedUnverified, "read", cause: "human_intervention"),
            UncertainDelivery(kind: .failedAfterEvents, sentBefore: 1, detail: "stopped"))
        #expect(result.cause == "human_intervention")
    }

    @Test func lateStopPreservesVerifiedOutcome() async {
        let wait = InterruptibleWait()
        wait.open()
        wait.requestStop()
        let verified = ActOutcome(.foundActed, "verified", scene: window("After").scene,
            check: OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .passed,
                                  expected: "wanted", observed: "wanted", performed: .requested))
        await InterruptibleWait.$current.withValue(wait) {
            #expect(ActionEngine.stoppedOutcome(verified) == verified)
        }
    }
}

extension UncertainDeliveryTests {
    final class CancellableScenes: SceneProviding {
        let before: PerceivedWindow
        let state = Synchronization.Mutex((reads: 0, entered: false, cancelled: false))
        init(_ before: PerceivedWindow) { self.before = before }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            let reads = state.withLock { $0.reads += 1; return $0.reads }
            if reads > 1 {
                state.withLock { $0.entered = true }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch is CancellationError {
                    state.withLock { $0.cancelled = true }
                    throw CancellationError()
                }
            }
            return before
        }
    }

    @Test func turnCancellationReachesReadingAfterGesture() async {
        let scenes = CancellableScenes(window("Before"))
        let actuator = ActionEngineTests.RecordingActuator()
        let engine = ActionEngine(.init(scenes: scenes, actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        let call = Task {
            await InterruptibleWait.$current.withValue(InterruptibleWait()) {
                await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                    input: .pressKey(KeyChord(.tab), times: 1)))
            }
        }
        while !scenes.state.withLock({ $0.entered }) { await Task.yield() }
        call.cancel()
        let result = await call.value
        let deadline = ContinuousClock.now + .milliseconds(200)
        while !scenes.state.withLock({ $0.cancelled }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(scenes.state.withLock { $0.cancelled })
        #expect(result.scene == nil)
        #expect(actuator.gestures.count == 1)
    }
}

extension UncertainDeliveryTests {
    final class PartialTextActuator: Actuating, @unchecked Sendable {
        let sentBefore: Int
        private let state = Synchronization.Mutex(0)
        var calls: Int { state.withLock { $0 } }
        init(sentBefore: Int) { self.sentBefore = sentBefore }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            state.withLock { $0 += 1 }
            throw ActionEngine.TextStopped(reason: "focus moved", sentBefore: sentBefore)
        }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    @Test(arguments: [1, 3])
    func partialTextIsNotReplayed(_ sentBefore: Int) async {
        let actuator = PartialTextActuator(sentBefore: sentBefore)
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([window("Before")]),
            actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
            input: .typeText("new", into: "Name", replacing: true)))
        #expect(result.scene != nil)
        #expect(result.check?.performed == .uncertain)
        #expect(result.check?.limits.contains(.deliveryUncertain) == true)
        #expect(result.outcome.recovery == .doNotRepeat)
        #expect(result.message.contains("delivery failed: focus moved"))
        #expect(actuator.calls == 1, "the partial input is never sent again during its read-back")
    }
}
