import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// M2 through the engine: a click, a toggle and an input judged by comparing scenes conclude nothing from a
/// capture that says it is not whole. The check is unknown with `unattributed`, no effect is recorded, the
/// delivery is never confirmed absent; a direct read-back keeps its own verdict. Complete on both sides is
/// judged as before.
@Suite("The engine over partial captures (M2)")
struct PartialCaptureEngineTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls
    typealias RecordingObserver = ActionEngineTests.RecordingObserver

    private let pid: pid_t = 4242
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Export", number: 1)

    static let complete   = CaptureQuality(walkCompleted: true, windowFound: true)
    static let unanswered = CaptureQuality(walkCompleted: false, windowFound: true)
    static let budget     = CaptureQuality(walkCompleted: false, stoppedBy: .elementLimit, windowFound: true)

    private func element(_ id: String, _ label: String, x: Double, state: ControlState? = nil) -> SceneElement {
        SceneElement(id: id, kind: .control, label: label, bounds: NormalizedRect(x: x, y: 0.5, width: 0.05, height: 0.02),
                     state: state)
    }

    private var export: SceneElement { element("control|export", "Export", x: 0.8) }
    private var three: [SceneElement] {
        [element("a", "Annulla", x: 0.1), element("b", "Formato", x: 0.2), element("c", "Qualita", x: 0.3)]
    }

    private func window(_ elements: [SceneElement], _ capture: CaptureQuality, token: String) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Export",
                                             viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                                             elements: elements, token: SceneToken(rawValue: token)),
                        frame: frame, capture: capture)
    }

    private func engine(_ scenes: [PerceivedWindow], actuator: RecordingActuator, observer: RecordingObserver,
                        controls: FakeControls? = nil) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(scenes: ScriptedScenes(scenes), actuator: actuator,
                                               windows: ScriptedWindows([[mainWindow]]), controls: controls,
                                               observer: observer), pause: { _ in })
    }

    private func click(_ before: PerceivedWindow, _ after: PerceivedWindow)
        async -> (ActOutcome, RecordingActuator, RecordingObserver) {
        let actuator = RecordingActuator(), observer = RecordingObserver()
        let outcome = await engine([before, after], actuator: actuator, observer: observer)
            .act(ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: "Export", verb: .click))
        return (outcome, actuator, observer)
    }

    private func refused(_ outcome: ActOutcome, _ actuator: RecordingActuator, _ observer: RecordingObserver,
                         _ comment: String) {
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: "\(comment): \(outcome.message)"))
        #expect(outcome.check?.verdict == .unknown && outcome.check?.limits.contains(.unattributed) == true, Comment(rawValue: comment))
        #expect(outcome.message.contains("not read in full"), Comment(rawValue: outcome.message))
        #expect(actuator.confirmations == [.unknown], Comment(rawValue: "\(comment): never confirmed absent"))
        #expect(observer.records.last.map { $0.effect == nil } == true, Comment(rawValue: "\(comment): no effect recorded"))
    }

    @Test("a click: complete before and partial after is no disappearance; partial before and complete after no appearance; two partial reads alike no ghost; a budget stop refuses a flip")
    func clicks() async {
        var (outcome, actuator, observer) = await click(window([export] + three, Self.complete, token: "1"),
                                                         window([export], Self.unanswered, token: "2"))
        refused(outcome, actuator, observer, "complete→partial")
        (outcome, actuator, observer) = await click(window([export], Self.unanswered, token: "1"),
                                                     window([export] + three, Self.complete, token: "2"))
        refused(outcome, actuator, observer, "partial→complete")
        (outcome, actuator, observer) = await click(window([export] + three, Self.unanswered, token: "1"),
                                                     window([export] + three, Self.unanswered, token: "1"))
        refused(outcome, actuator, observer, "partial→partial, same token")
        let off = element("control|export", "Export", x: 0.8, state: .off)
        let on  = element("control|export", "Export", x: 0.8, state: .on)
        (outcome, actuator, observer) = await click(window([off], Self.complete, token: "1"), window([on], Self.budget, token: "2"))
        refused(outcome, actuator, observer, "budget-partial flip")
    }

    @Test("positive controls: complete on both sides judges a disappearance as passed and the same token as a ghost, as before")
    func completeClicks() async {
        let (gone, goneActuator, goneObserver) = await click(window([export] + three, Self.complete, token: "1"),
                                                              window([export], Self.complete, token: "2"))
        #expect(gone.kind == .foundActed && gone.check?.verdict == .passed, Comment(rawValue: gone.message))
        #expect(goneActuator.confirmations == [.observed])
        #expect(goneObserver.records.last?.effect == .elementsDisappeared(labels: ["Annulla", "Formato", "Qualita"]))
        let (ghost, ghostActuator, _) = await click(window([export], Self.complete, token: "1"), window([export], Self.complete, token: "1"))
        #expect(ghost.check?.verdict == .failed && ghostActuator.confirmations == [.absent], Comment(rawValue: ghost.message))
    }

    @Test("a toggle keeps the verdict of its direct read-back, but a partial capture records no effect from the scenes")
    func toggle() async {
        let off = element("control|facebook", "Facebook", x: 0.2, state: .off)
        let on  = element("control|facebook", "Facebook", x: 0.2, state: .on)
        for (capture, recordsFlip) in [(Self.unanswered, false), (Self.complete, true)] {
            let actuator = RecordingActuator(), observer = RecordingObserver()
            let outcome = await engine([window([off], Self.complete, token: "1"), window([on], capture, token: "2")],
                                       actuator: actuator, observer: observer, controls: FakeControls(toggle: .on))
                .act(ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: "Facebook", verb: .setToggle,
                                   desiredState: .on))
            #expect(outcome.check?.verdict == .passed, Comment(rawValue: outcome.message))
            #expect((observer.records.last?.effect != nil) == recordsFlip, "the scene's flip only from complete captures")
        }
    }

    @Test("a scoped toggle over a partial capture: a moved match in the scope is no read-back, nor is a homonym's flip")
    func scopedToggleOverPartialCapture() async {
        func mute(_ container: String, x: Double, _ state: ControlState) -> SceneElement {
            var control = element("control|mute", "Mute", x: x, state: state)
            control.role = "AXButton"
            control.container = container
            return control
        }
        let before = [mute("Bus", x: 0.1, .off), mute("Kick", x: 0.4, .off)]
        let cases: [(String, [SceneElement], CaptureQuality, ControlState?)] = [
            // The selected control read at its place in a partial capture: presence is reliable there.
            ("in place, partial", [mute("Kick", x: 0.4, .on)], Self.unanswered, .on),
            // One match in the scope, at another place, in a partial capture: the target may be in the unread part.
            ("moved, partial", [mute("Kick", x: 0.6, .on)], Self.unanswered, nil),
            // The same moved match in a whole capture is the only one there is.
            ("moved, complete", [mute("Bus", x: 0.1, .off), mute("Kick", x: 0.6, .on)], Self.complete, .on),
            // Only the homonym flipped: never the target's read-back.
            ("homonym, partial", [mute("Bus", x: 0.1, .on)], Self.unanswered, nil),
        ]
        for (name, after, capture, readBack) in cases {
            let actuator = RecordingActuator(), observer = RecordingObserver()
            let outcome = await engine([window(before, Self.complete, token: "1"), window(after, capture, token: "2")],
                                       actuator: actuator, observer: observer, controls: FakeControls())
                .act(ActionRequest(processID: pid, bundleID: "com.x", appName: "X", target: "Mute {Kick}",
                                   verb: .setToggle, desiredState: .on))
            #expect(outcome.check?.observed == readBack?.rawValue, Comment(rawValue: "\(name): \(outcome.message)"))
            #expect(outcome.check?.verdict == (readBack == .on ? .passed : .unknown), Comment(rawValue: name))
            #expect((observer.records.last?.effect != nil) == (capture == Self.complete), Comment(rawValue: name))
        }
    }

    @Test("an input judged by the scenes: a scroll over a partial capture is unattributable and never confirmed absent; over complete ones, a ghost as before")
    func input() async {
        for (capture, expected) in [(Self.unanswered, DeliveryEffect.unknown), (Self.complete, .absent)] {
            let actuator = RecordingActuator(), observer = RecordingObserver()
            let outcome = await engine([window(three, Self.complete, token: "1"), window(three, capture, token: "1")],
                                       actuator: actuator, observer: observer)
                .deliver(InputRequest(processID: pid, bundleID: "com.x", appName: "X", input: .scroll(lines: -3, over: nil)))
            #expect(actuator.confirmations == [expected], Comment(rawValue: outcome.message))
            #expect(outcome.check?.verdict == (capture == Self.complete ? .failed : .unknown), Comment(rawValue: outcome.message))
        }
    }
}
