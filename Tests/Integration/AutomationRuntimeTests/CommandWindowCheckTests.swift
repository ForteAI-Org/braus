//
//  CommandWindowCheckTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import PerceptionCore
import Testing

/// A menu command or a dialog button whose application's windows did not change, judged again on its own
/// window (`PerceivedCommand.checkedInWindow`): PhotoCraft opens its save panel as a sheet and draws its
/// Image Size dialog and its save prompt inside the window, so 21 of its 28 menu commands stayed unknown
/// (14 October 2026).
@Suite("A command judged on its own window when its windows did not change")
struct CommandWindowCheckTests {

    static func window(_ labels: [String]) -> PerceivedWindow {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "button|\(label)", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.1 + Double(index) * 0.2, y: 0.5, width: 0.1, height: 0.04),
                         role: "AXButton", labelOrigin: .title)
        }
        return PerceivedWindow(
            scene  : SceneSnapshot(bundleID: "ai.example.editor", appName: "Editor", windowTitle: "foto_3.png — Editor",
                                   viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200), elements: elements),
            frame  : CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                    nodesVisited: elements.count + 1, elementsEmitted: elements.count),
            surface: .window
        )
    }

    static func unknownWindows(limits: [OperationCheck.Limit] = [.commandEffectUnchecked],
                               performed: OperationCheck.Performed = .requested) -> OperationCheck {
        OperationCheck(condition: .windowSetChanged, method: .windowSignature, verdict: .unknown, expected: "windows changed",
                       limits: limits, performed: performed)
    }

    /// The command performed through `PerceivedCommand` with no recorder: `before` is perceived first, `after`
    /// once the command asks for it.
    static func perform(before: PerceivedWindow, after: PerceivedWindow, check: OperationCheck) async throws -> ActOutcome {
        let windows = Windows(before: before, after: after)
        return try await PerceivedCommand.perform(bundleID: "ai.example.editor", recorder: nil, perceive: { await windows.next() }) { observe in
            let scene = try await observe()
            return ActOutcome(.actedUnverified, "pressed File > Save a Copy…: no window opened, closed or was retitled; the scene "
                              + "shows whether it took effect. Do not press it again blind.", scene: scene, check: check)
        }
    }

    /// The window before the command, then the window after it for every later perception.
    actor Windows {
        private var before: PerceivedWindow?
        private let after: PerceivedWindow
        init(before: PerceivedWindow, after: PerceivedWindow) { self.before = before; self.after = after }
        func next() -> PerceivedWindow {
            defer { before = nil }
            return before ?? after
        }
    }

    @Test("a sheet or a dialog drawn in the window is a structural effect, passed, found window-wide with no expectation")
    func changeInPlacePasses() async throws {
        let outcome = try await Self.perform(before: Self.window(["Chiudi", "Crea nuovo livello"]),
                                             after: Self.window(["Chiudi", "Crea nuovo livello", "Cancel", "Save"]),
                                             check: Self.unknownWindows())
        #expect(outcome.kind == .foundActed)
        #expect(outcome.check?.condition == .structuralEffect)
        #expect(outcome.check?.method == .sceneDifference)
        #expect(outcome.check?.verdict == .passed)
        #expect(outcome.check?.observed == "elementsAppeared")
        #expect(outcome.check?.limits == [.windowWide, .noExpectation])
        #expect(outcome.check?.performed == .requested)
        #expect(outcome.message.hasPrefix("pressed File > Save a Copy…: no window opened or closed, the window changed in place"))
    }

    @Test("a discarded after-scene cannot turn an unverified command into a confirmed change")
    func discardedSceneStaysUnknown() async throws {
        let windows = Windows(before: Self.window(["Close"]), after: Self.window(["Close", "Cancel", "Save"]))
        let check = Self.unknownWindows(limits: [.noAfterScene, .commandEffectUnchecked])
        let outcome = try await PerceivedCommand.perform(
            bundleID: "ai.example.editor", recorder: nil, perceive: { await windows.next() }
        ) { observe in
            _ = try await observe()
            return ActOutcome(.actedUnverified, "Windows changed during observation.", check: check)
        }
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.check == check)
        #expect(outcome.scene == nil)
    }

    @Test("a window that did not change in place either stays unknown, as a command may act where no scene shows it")
    func noChangeStaysUnknown() async throws {
        let same = Self.window(["Chiudi", "Crea nuovo livello"])
        let outcome = try await Self.perform(before: same, after: same, check: Self.unknownWindows())
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.check == Self.unknownWindows())
    }

    @Test("M2: a capture before or after that was not read in full compares to nothing: the window check stays unknown",
          arguments: [CaptureQuality(walkCompleted: false, windowFound: true),
                      CaptureQuality(walkCompleted: false, stoppedBy: .elementLimit, windowFound: true)])
    func partialCaptureStaysUnknown(capture: CaptureQuality) async throws {
        func partial(_ window: PerceivedWindow) -> PerceivedWindow {
            PerceivedWindow(scene: window.scene, frame: window.frame, capture: capture, surface: window.surface)
        }
        let before = Self.window(["Chiudi"]), after = Self.window(["Chiudi", "Cancel", "Save"])
        #expect(try await Self.perform(before: partial(before), after: after, check: Self.unknownWindows()).check
            == Self.unknownWindows())
        #expect(try await Self.perform(before: before, after: partial(after), check: Self.unknownWindows()).check
            == Self.unknownWindows())
    }

    @Test("an uncertain delivery or another gesture is never judged again: the window cannot say the request did it")
    func uncertainDeliveryIsKept() async throws {
        let before = Self.window(["Chiudi"]), after = Self.window(["Chiudi", "Cancel", "Save"])
        let uncertain = Self.unknownWindows(limits: [.deliveryUncertain, .commandEffectUnchecked], performed: .uncertain)
        #expect(try await Self.perform(before: before, after: after, check: uncertain).check == uncertain)
        let passed = OperationCheck(condition: .windowSetChanged, method: .windowSignature, verdict: .passed, expected: "windows changed",
                                    observed: "windows changed", limits: [.commandEffectUnchecked], performed: .requested)
        #expect(try await Self.perform(before: before, after: after, check: passed).check == passed, "a passed window check stays as it is")
    }
}
