@testable import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing

@MainActor
@Suite("Menu expectations use actual before and after evidence")
struct MenuExpectationTests {
    private final class Settler: Settling, @unchecked Sendable {
        var calls = 0
        let first: SettleResult
        init(first: SettleResult = .settled) { self.first = first }
        func settle(in processID: pid_t, cap: Duration) async -> SettleResult {
            calls += 1
            return calls == 1 ? first : .settled
        }
    }

    private func window(_ value: String?, title: String = "Main", bundleID: String = "test.menu",
                        complete: Bool = true) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: bundleID, appName: "Menu", windowTitle: title,
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                SceneElement(id: "choice", kind: .control, label: "Choice",
                    bounds: .init(x: 0, y: 0, width: 1, height: 1), role: "AXTextField", value: value)
            ]), frame: .zero, capture: .init(walkCompleted: complete, windowFound: true,
                isGrantAvailable: true, windowRole: "AXWindow", nodesVisited: 1, elementsEmitted: 1))
    }

    private func perform(_ expectation: ScreenExpectation, before: PerceivedWindow, after: [PerceivedWindow],
                         windowsBefore: [String]? = nil, windowsAfter: [String]? = nil,
                         firstWait: SettleResult = .settled, uncertain: Bool = false) async throws -> (outcome: ActOutcome, presses: Int, reads: Int) {
        var reads = 0
        var presses = 0
        let settler = Settler(first: firstWait)
        let result = try await ScreenExpectation.$current.withValue(expectation) {
            try await PerceivedCommand.perform(bundleID: "test.menu", recorder: nil, perceive: {
                reads += 1
                return reads == 1 ? before : after[min(reads - 2, after.count - 1)]
            }) { observe in
                // This is the synthetic counterpart of the baseline collected immediately before AXPress.
                MenuBarCommand.expectationReadings?.windowsBefore = windowsBefore
                presses += 1
                return try await MenuBarCommand.observedOutcome("File > Change",
                    outcome: ActOutcome(.foundActed, "Pressed", check: uncertain
                        ? MenuBarCommand.windowCheck(.unknown, limits: [.deliveryUncertain], performed: .uncertain) : nil), processID: 42, before: ["original signature"],
                    settling: settler, signature: { _ in ["retitled signature"] },
                    windowTitles: { _ in windowsAfter }, observe: observe)
            }
        }
        #expect(MenuBarCommand.expectationReadings == nil)
        return (result, presses, reads)
    }

    @Test("a retitle cannot replace the bound element predicate", arguments: ["wanted", "wrong"])
    func elementPredicateControlsTheVerdict(_ value: String) async throws {
        let (result, presses, reads) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("old"), after: [window(value, title: "Renamed")])
        #expect(result.check?.verdict == (value == "wanted" ? .passed : .failed))
        #expect(result.check?.method == .controlValue)
        #expect(result.check?.limits.contains(.commandEffectUnchecked) == false)
        #expect(result.check?.expected == "element")
        #expect(result.check?.observed?.contains("wanted") == false)
        #expect(presses == 1 && reads == 2)
    }

    @Test("an AX timeout retains uncertain delivery independently of the observed predicate", arguments: ["wanted", "wrong"])
    func timeoutKeepsDeliveryUncertain(_ value: String) async throws {
        let (result, presses, _) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("old"), after: [window(value, title: "Renamed")], uncertain: true)
        #expect(result.outcome.gesture == .uncertain)
        #expect(result.outcome.effect == (value == "wanted" ? .confirmed : .absent))
        #expect(result.check?.performed == .uncertain)
        #expect(result.check?.limits.contains(.deliveryUncertain) == true)
        #expect(presses == 1)
    }

    @Test("a predicate already true before the command is not a new proved effect")
    func unchangedSatisfiedPredicateDoesNotProveTheCommand() async throws {
        let (result, presses, _) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("wanted"), after: [window("wanted")])
        #expect(result.kind == .actedUnverified && result.check?.verdict == .failed)
        #expect(result.noop == .statePresent)
        #expect(result.check?.observed == OutcomeText.expectationAlreadySatisfied)
        #expect(presses == 1)
    }

    @Test("another window is checked against the full census, not the foreground scene", arguments: [false, true])
    func closingAnotherWindowRequiresItsActualAbsence(_ closed: Bool) async throws {
        let (result, presses, _) = try await perform(.window(title: "Other", open: false),
            before: window("old"), after: [window("old", title: "Renamed Main")],
            windowsBefore: ["Main", "Other"], windowsAfter: closed ? ["Renamed Main"] : ["Renamed Main", "Other"])
        #expect(result.check?.verdict == (closed ? .passed : .failed))
        #expect(result.check?.method == .windowCensus)
        #expect(result.check?.expected == "window")
        #expect(presses == 1)
    }

    @Test("an unknown census cannot prove a window's absence", arguments: [false, true])
    func unreadableBeforeOrAfterCensusStaysUnknown(_ missingBefore: Bool) async throws {
        let (result, presses, _) = try await perform(.window(title: "Other", open: false),
            before: window("old"), after: [window("old")],
            windowsBefore: missingBefore ? nil : ["Main", "Other"], windowsAfter: missingBefore ? ["Main"] : nil)
        #expect(result.check?.verdict == .unknown)
        #expect(result.check?.limits.contains(.readbackUnavailable) == true)
        #expect(presses == 1)
    }

    @Test("partial captures and another app do not prove an element predicate", arguments: [false, true])
    func uncomparableReadingsStayUnknown(_ otherApp: Bool) async throws {
        let (result, presses, _) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("old"), after: [window("wanted", bundleID: otherApp ? "test.other" : "test.menu", complete: otherApp)])
        #expect(result.check?.verdict == .unknown)
        #expect(result.check?.observed == OutcomeText.expectationScenesIncomparable)
        #expect(presses == 1)
    }

    @Test("a second look checks the predicate again without another press", arguments: ["wanted", "wrong"])
    func secondLookUsesItsFinalPredicate(_ value: String) async throws {
        let (result, presses, reads) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("old"), after: [window(nil), window(value)], firstWait: .capped)
        #expect(result.check?.verdict == (value == "wanted" ? .passed : .failed))
        #expect(result.lookedAgain)
        #expect(presses == 1 && reads == 3)
    }

    @Test("a false menu expectation cannot authorize the next committing step")
    func batchCommitRequiresTheMenuPredicateToPass() async throws {
        let (result, _, _) = try await perform(.element(label: "Choice", expect: .value("wanted")),
            before: window("old"), after: [window("wrong", title: "Unrelated retitle")])
        let scene = window("wrong").scene
        let plan = BatchPolicy.BatchPlanFacts(steps: [
            .init(kind: .menu, item: "File > Change"),
            .init(kind: .pressKey, chord: .init(.return), expectation: .window(title: "Done", open: true))
        ], bundleID: "test.menu")
        let decision = BatchPolicy.beforeStep(1, of: plan, scene: scene, target: .notNeeded,
            commits: true, earlier: [result.outcome], elapsed: .zero)
        #expect(decision == .stop(.committingAfterUnconfirmed))
    }
}
