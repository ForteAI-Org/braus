import EngineCore
import Switches
import Testing

struct OutcomeConversionTests {
    @Test func refusalCauses() {
        let cases: [(NotSentCause, Recovery)] = [
            (.needsConsent, .askPerson), (.destructiveUnverifiable, .changeTarget(.destructive)),
            (.disabled, .changeTarget(.disabled)), (.targetUnreachable, .changeTarget(.unreachable)),
            (.seatNotReady, .retry), (.humanIntervention, .doNotRepeat),
            (.inputAuthorityExpired, .observe), (.other, .doNotRepeat)
        ]
        for (cause, recovery) in cases {
            let value = Outcome.converting(.refused, check: nil, notSent: cause, noop: nil, sceneAttached: false)
            #expect(value == Outcome(gesture: .notSent, effect: .notApplicable, recovery: recovery))
        }
    }

    @Test func ruleOrderAndScenePresence() {
        for scene in [false, true] {
            for performed in OperationCheck.Performed.allCases {
                for verdict in OperationCheck.Verdict.allCases {
                    for limit in OperationCheck.Limit.allCases {
                        let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                                                   verdict: verdict, limits: [limit], performed: performed)
                        let value = Outcome.converting(.actedUnverified, check: check, notSent: nil,
                                                       noop: nil, sceneAttached: scene)
                        #expect(!scene || value.recovery != .observe)
                        if performed == .uncertain || limit == .deliveryUncertain {
                            #expect(value.gesture == .uncertain)
                        } else if verdict == .failed {
                            #expect(value.effect == .absent)
                        }
                    }
                }
            }
            let expired = Outcome.converting(.refused, check: nil, notSent: .inputAuthorityExpired,
                                             noop: nil, sceneAttached: scene)
            #expect(expired.recovery == (scene ? .doNotRepeat : .observe))
        }
    }

    @Test func noopsRequireExplicitProof() {
        for noop in [nil, .listing, .substituted, .statePresent] as [NoopKind?] {
            let value = Outcome.converting(.actedNoop, check: nil, notSent: nil, noop: noop, sceneAttached: false)
            #expect(value.effect == (noop == .statePresent ? .confirmed : .notApplicable))
        }
    }
}

extension OutcomeConversionTests {
    @Test(arguments: OperationCheck.Verdict.allCases)
    func uncertainDeliveryKeepsTheObservedVerdict(_ verdict: OperationCheck.Verdict) {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["scene_after_uncertain": "on"])) {
            let check = OperationCheck(condition: .stateAfterGesture, method: .controlState,
                verdict: verdict, limits: [.deliveryUncertain], performed: .uncertain)
            let result = Outcome.converting(verdict == .passed ? .foundActed : .actedUnverified,
                check: check, notSent: nil, noop: nil, sceneAttached: true)
            #expect(result.gesture == .uncertain)
            #expect(result.effect == (verdict == .passed ? .confirmed : verdict == .failed ? .absent : .unknown(.notClassified)))
            #expect(result.recovery == (verdict == .passed ? .continue : .doNotRepeat))
        }
    }

    @Test func interruptedUncertainReadingCannotAskForARepeat() {
        SwitchBoard.$testing.withValue(SwitchBoard(values: ["scene_after_uncertain": "on"])) {
            let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                verdict: .unknown, limits: [.deliveryUncertain, .noAfterScene], performed: .uncertain)
            let result = Outcome.converting(.actedUnverified, check: check, notSent: nil, noop: nil, sceneAttached: false)
            #expect(result.row == "uncertain · unknown(not_readable) · do_not_repeat")
        }
    }
}
