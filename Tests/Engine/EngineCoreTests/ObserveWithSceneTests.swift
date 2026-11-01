import EngineCore
import Testing

struct ObserveWithSceneTests {
    @Test func everyKindAndLimitRespectsAttachedScene() {
        for kind in ActOutcomeKind.allCases {
            for performed in OperationCheck.Performed.allCases {
                for verdict in OperationCheck.Verdict.allCases {
                    for first in OperationCheck.Limit.allCases {
                        for second in OperationCheck.Limit.allCases {
                            let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                                verdict: verdict, limits: [first, second], performed: performed)
                            let value = Outcome.converting(kind, check: check, notSent: nil,
                                                           noop: nil, sceneAttached: true)
                            #expect(value.recovery != .observe)
                            #expect(value.gesture != .uncertain || value.recovery != .continue || value.effect == .confirmed)
                            #expect(value.gesture != .notSent || value.effect != .confirmed)
                        }
                    }
                }
            }
        }
    }

    @Test func evidenceOrderAndSafeRetry() {
        func convert(_ verdict: OperationCheck.Verdict, _ limits: [OperationCheck.Limit],
                     observed: String? = nil, scene: Bool = false) -> Outcome {
            Outcome.converting(.actedUnverified,
                check: OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                    verdict: verdict, observed: observed, limits: limits, performed: .requested),
                notSent: nil, noop: nil, sceneAttached: scene)
        }
        #expect(convert(.failed, [], observed: "unchanged").recovery == .retry)
        #expect(convert(.failed, [], observed: "another family").recovery == .doNotRepeat)
        #expect(convert(.failed, [.unattributed, .settleCapped]).effect == .absent)
        #expect(convert(.unknown, [.unattributed, .settleCapped]).effect == .unknown(.notClassified))
        #expect(convert(.unknown, [.settleUnwatched, .settleCapped]).effect == .unknown(.stillChanging))
        for limit in [OperationCheck.Limit.settleCapped, .settleUnwatched, .noAfterScene, .readbackUnavailable] {
            #expect(convert(.unknown, [limit]).recovery == .observe)
            #expect(convert(.unknown, [limit], scene: true).recovery == .doNotRepeat)
        }
    }

    @Test func copiedOutcomeKeepsCauseAndNoop() {
        let result = ActOutcome(.refused, "Original.", notSent: .needsConsent,
                                noop: .statePresent, cause: "endpoint_refused#42")
            .with(scene: nil).with(message: "Changed.").with(check: .unchecked(performed: .none))
        #expect(result.notSent == .needsConsent)
        #expect(result.noop == .statePresent)
        #expect(result.cause == "endpoint_refused")
        #expect(result.outcome.recovery == .askPerson)
    }
}
