@testable import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
import Testing

@MainActor
@Suite("Menu second look")
struct MenuSecondLookTests {
    final class Settler: Settling, @unchecked Sendable {
        var caps: [Duration] = []
        var onSecond: (@Sendable () -> Void)?
        func settle(in processID: pid_t, cap: Duration) async -> SettleResult {
            caps.append(cap)
            if caps.count == 2 { onSecond?() }
            return caps.count == 1 ? .capped : .settled
        }
    }

    @Test("cancellation after dispatch retains the sent gesture")
    func cancelledPress() async throws {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MenuBarCommand.observedOutcome("Open", outcome: ActOutcome(.foundActed, "Pressed"),
                processID: 42, before: [], signature: { _ in [] }, observe: {
                    Issue.record("Cancelled observation should not run")
                    throw CancellationError()
                })
        }
        let result = try await task.value
        #expect(result.outcome.gesture == .sent)
        #expect(result.scene == nil)
    }

    @Test("changing windows remain distinct from an unreadable observation", arguments: [false, true])
    func changingWindows(usesSettler: Bool) async throws {
        var census = 0
        let result = try await MenuBarCommand.observedOutcome("Open", outcome: ActOutcome(.foundActed, "Pressed"),
            processID: 42, before: [], settling: usesSettler ? Settler() : nil, signature: { _ in
                [String(census)]
            }, secondLookCap: .milliseconds(450), observe: {
                census += 1
                return SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                    viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
            })
        #expect(result.outcome.effect == .unknown(.stillChanging))
    }

    @Test("late windows are counted again, with a two second budget")
    func lateWindow() async throws {
        let settling = Settler()
        var signatures = 0
        var observations = 0
        let scene = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
        let result = try await MenuBarCommand.observedOutcome("File > Open", outcome: ActOutcome(.foundActed, "Pressed"),
            processID: 42, before: ["main"], settling: settling,
            signature: { _ in
                signatures += 1
                return settling.caps.count >= 2 ? ["main", "dialog"] : ["main"]
            }, gestureEnded: .now - .milliseconds(600), observe: {
                observations += 1
                return scene
            })
        #expect(result.check?.verdict == .passed)
        #expect(settling.caps.count == 2)
        #expect(observations == 2)
        #expect(signatures >= 3)
        if let cap = settling.caps.last { #expect(cap >= .milliseconds(1350) && cap <= .milliseconds(1400)) }
    }
    @Test("a perceived press checks the final scene and performs one second look")
    func perceivedPress() async throws {
        let settler = Settler()
        var reads = 0
        let result = try await PerceivedCommand.perform(bundleID: "com.x", recorder: nil, perceive: {
            reads += 1
            let element = SceneElement(id: "option", kind: .control, label: "Option",
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), role: "AXCheckBox", state: reads >= 3 ? .on : .off)
            return PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
                elements: reads >= 3 ? [element, SceneElement(id: "dialog", kind: .control, label: "Dialog",
                    bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), role: "AXButton")] : [element]), frame: .zero,
                capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                        windowRole: "AXWindow", nodesVisited: 2, elementsEmitted: 1))
        }) { observe in
            try await MenuBarCommand.observedOutcome("'Open'", outcome: ActOutcome(.foundActed, "Pressed"),
                processID: 42, before: ["main"], settling: settler, signature: { _ in ["main"] }, observe: observe)
        }
        #expect(result.check?.condition == .structuralEffect && result.check?.verdict == .passed)
        #expect(result.lookedAgain && reads == 3 && settler.caps.count == 2)
    }

    @Test("takeover cuts a menu second look without cancelling the owner")
    func takeover() async throws {
        let wait = InterruptibleWait()
        try await InterruptibleWait.$current.withValue(wait) {
            let settler = Settler()
            settler.onSecond = { wait.requestStop() }
            let result = try await MenuBarCommand.observedOutcome("File > Open", outcome: ActOutcome(.foundActed, "Pressed"),
                processID: 42, before: [], settling: settler, signature: { _ in [] }, observe: {
                    SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
                })
            #expect(result.scene == nil && !result.lookedAgain)
            #expect(result.check?.limits.contains(.noAfterScene) == true)
            #expect(!Task.isCancelled && !wait.isOpen)
        }
    }

}
