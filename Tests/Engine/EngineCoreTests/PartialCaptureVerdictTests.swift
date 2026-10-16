import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

/// M2: a scene comparison concludes nothing from a capture that says it is not whole. Partial, failed or
/// inconsistent on either side is `unattributable` before the tokens are compared; complete on both sides and
/// the legacy unknown quality are judged as before.
@Suite("Verdicts over partial captures (M2)")
struct PartialCaptureVerdictTests {

    static let complete     = CaptureQuality(walkCompleted: true, windowFound: true)
    static let unanswered   = CaptureQuality(walkCompleted: false, windowFound: true)
    static let budget       = CaptureQuality(walkCompleted: false, stoppedBy: .elementLimit, windowFound: true)
    static let failed       = CaptureQuality(walkCompleted: false, windowFound: false)
    static let inconsistent = CaptureQuality(walkCompleted: true, stoppedBy: .deadline, windowFound: true)

    private static func element(_ id: String, _ label: String, state: ControlState? = nil) -> SceneElement {
        SceneElement(id: id, kind: .control, label: label, bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.05, height: 0.02),
                     state: state)
    }

    private static let three = [element("a", "Esporta"), element("b", "Annulla"), element("c", "Formato")]

    private static func window(_ elements: [SceneElement], _ capture: CaptureQuality, token: String) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Export",
                                             viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
                                             elements: elements, token: SceneToken(rawValue: token)),
                        frame: CGRect(x: 0, y: 0, width: 1000, height: 800), capture: capture)
    }

    private static func judged(_ before: PerceivedWindow, _ after: PerceivedWindow, targetID: String? = nil)
        -> ActVerification.Verdict {
        let comparable = ActVerification.comparable(before: before.capture, after: after.capture)
        let effect = comparable
            ? SceneDifference.effect(before: before.scene, after: after.scene, targetID: targetID) : nil
        return ActVerification.verdict(before: before, after: after, effect: effect)
    }

    @Test("a capture refuses a comparison when it is partial, whatever the cause, failed or inconsistent; complete and unknown do not",
          arguments: [(complete, false), (unanswered, true), (budget, true), (failed, true), (inconsistent, true),
                      (CaptureQuality.unknown, false)])
    func refusal(capture: CaptureQuality, refuses: Bool) {
        #expect(ActVerification.refusesComparison(capture) == refuses)
    }

    @Test("partial before, complete after: a branch readable again is no element that appeared")
    func partialThenComplete() {
        let verdict = Self.judged(Self.window([], Self.unanswered, token: "1"), Self.window(Self.three, Self.complete, token: "2"))
        #expect(verdict == .unattributable)
    }

    @Test("complete before, partial after: elements not read are no elements that disappeared")
    func completeThenPartial() {
        let verdict = Self.judged(Self.window(Self.three, Self.complete, token: "1"), Self.window([], Self.unanswered, token: "2"))
        #expect(verdict == .unattributable)
    }

    @Test("two partial captures with the same token are no proof that nothing changed: unattributable, never a ghost")
    func samePartialToken() {
        let verdict = Self.judged(Self.window(Self.three, Self.unanswered, token: "1"), Self.window(Self.three, Self.unanswered, token: "1"))
        #expect(verdict == .unattributable)
    }

    @Test("a budget stop, a failed capture or inconsistent facts on either side refuse even the same element's flip",
          arguments: [budget, failed, inconsistent])
    func refusedFlip(capture: CaptureQuality) {
        let off = [Self.element("sw", "Facebook", state: .off)], on = [Self.element("sw", "Facebook", state: .on)]
        #expect(Self.judged(Self.window(off, capture, token: "1"), Self.window(on, Self.complete, token: "2"), targetID: "sw")
            == .unattributable)
        #expect(Self.judged(Self.window(off, Self.complete, token: "1"), Self.window(on, capture, token: "2"), targetID: "sw")
            == .unattributable)
    }

    @Test("positive controls: complete on both sides, or the legacy unknown quality, is judged as before",
          arguments: [complete, CaptureQuality.unknown])
    func asBefore(capture: CaptureQuality) {
        #expect(Self.judged(Self.window(Self.three, capture, token: "1"), Self.window(Self.three, capture, token: "1")) == .ghost)
        #expect(Self.judged(Self.window(Self.three, capture, token: "1"), Self.window([], capture, token: "2"))
            == .landed(.elementsDisappeared(labels: ["Annulla", "Esporta", "Formato"]), matchesExpectation: true))
    }
}
