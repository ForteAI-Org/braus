import EngineCore
import Testing
@testable import Memory

struct QualificationC2Tests {
    @Test func onlyPassedRowsCoverUnprovenSteps() throws {
        let part = try ProcedurePart(partID: "p", routeID: "v", kind: .subprocedure, parentPartID: "v/procedure",
            firstPosition: 0, lastPosition: 0, stepID: nil, bundleID: nil, label: "Save", declaredOutcome: .completed)
        for verdict in [VerificationVerdict.passed, .failed, .unknown] {
            let step = QualificationPolicy.StepFacts(position: 0, callEventID: "c", status: .completed,
                hasRecordingGap: false, verifications: [],
                rowCheck: .init(itemID: "r1", verdict: verdict, expectationRevision: 1))
            let result = QualificationPolicy.evaluate(.init(part: part, attemptEnd: .completed,
                interpretationState: .ended, steps: [step]))
            #expect(result.verdict == (verdict == .passed ? .admitted : .refused))
        }
        #expect(QualificationPolicy.earlierVersions.contains("qualification-c-1"))
    }
    @Test func instanceValueNeedsAnExpectationOrRepetition() throws {
        let part = try ProcedureConstructionTests.part()
        let positive = ProcedureConstructionTests.verification(.structuralEffect)
        for verified in [false, true] {
            let step = QualificationPolicy.StepFacts(position: 0, callEventID: "c", status: .completed,
                hasRecordingGap: false, verifications: [positive], hasInstanceValue: true,
                hasVerifiedExpectation: verified)
            let result = QualificationPolicy.evaluate(.init(part: part, attemptEnd: .completed,
                interpretationState: .ended, steps: [step]))
            #expect(result.verdict == (verified ? .admitted : .refused))
        }
    }

}
