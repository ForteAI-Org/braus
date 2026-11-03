import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Switches
import Testing

@Suite("Second look")
struct SecondLookTests {
    @Test("qualification preserves a seen effect", arguments: [SettleResult.settled, .capped, .unavailable],
          [OperationCheck.Verdict.passed, .failed, .unknown])
    func qualification(ending: SettleResult, verdict: OperationCheck.Verdict) {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["verdict_v2": "on"])) {
            let first = ActOutcome(verdict == .passed ? .foundActed : .actedUnverified, "Evidence", check:
                OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: verdict,
                               performed: .requested))
            let result = ActionEngine.qualified(first, after: ending, cap: .milliseconds(300))
            #expect(result.check?.verdict == (ending == .settled ? verdict : verdict == .passed ? .passed : .unknown))
            #expect(result.message == first.message)
            #expect(result.check?.methodVersion == "engine-oracle-2")
            #expect(ending == .settled || result.check?.limits.contains(ending == .capped ? .settleCapped : .settleUnwatched) == true)
        }
    }

    @Test("off retains the original scene qualification and version")
    func off() {
        for values in [[:], ["verdict_v2": "off", "second_look": "off"]] {
            SwitchBoard.$testing.withValue(SwitchBoard(values: values)) {
                #expect(!SecondLook.isEnabled)
                let first = ActOutcome(.foundActed, "Evidence", check:
                    OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .passed,
                                   performed: .requested))
                let result = ActionEngine.qualified(first, after: .capped, cap: .milliseconds(300))
                #expect(result.check?.verdict == .unknown)
                #expect(result.check?.methodVersion == "engine-oracle-1")
                #expect(result.message.contains("ended at its cap (300 ms)"))
            }
        }
    }
}

@Suite("Second look eligibility")
struct SecondLookEligibilityTests {
    @Test("only unknown sent effects are eligible", arguments: OperationCheck.Performed.allCases,
          OperationCheck.Verdict.allCases)
    func mode(performed: OperationCheck.Performed, verdict: OperationCheck.Verdict) {
        let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: verdict,
                                   limits: [.settleCapped], performed: performed)
        let expected: SecondLook? = verdict != .unknown || performed == .none ? nil
            : performed == .uncertain ? .readOnly : .wait
        #expect(SecondLook.mode(for: check, alreadyLooked: false) == expected)
        #expect(SecondLook.mode(for: check, alreadyLooked: true) == nil)
        #expect(SecondLook.mode(for: nil, alreadyLooked: false) == nil)
    }

    @Test("an unwatched wait qualifies, an ordinary unknown does not")
    func limits() {
        for limit in [OperationCheck.Limit.settleCapped, .settleUnwatched, .noAfterScene] {
            let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                                       limits: [limit], performed: .substitute)
            #expect(SecondLook.mode(for: check, alreadyLooked: false) == (limit == .noAfterScene ? nil : .wait))
        }
    }

    @Test("budget starts at the last gesture and clamps at zero")
    func remaining() {
        let ended = ContinuousClock.now
        #expect(SecondLook.remaining(budget: .seconds(1), since: ended, now: ended + .milliseconds(300)) == .milliseconds(700))
        #expect(SecondLook.remaining(budget: .seconds(1), since: ended, now: ended + .seconds(2)) == .zero)
    }

    @Test("cut keeps delivery and verdict and withdraws the scene", arguments: [false, true])
    func cut(uncertain: Bool) {
        let scene = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
        let first = ActOutcome(.actedUnverified, "Evidence", scene: scene, check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
            performed: uncertain ? .uncertain : .requested))
        let cut = SecondLook.cut(first)
        #expect(cut.scene == nil && !cut.lookedAgain)
        #expect(cut.check?.verdict == first.check?.verdict)
        #expect(cut.check?.performed == first.check?.performed)
        #expect(cut.check?.limits.contains(.noAfterScene) == true)
    }
}
