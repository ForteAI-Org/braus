import AutomationRuntime
import EngineCore
import Memory
import SQLiteMemory
import Testing

struct ActionVerdictRecordingTests {
    @Test func observedExpectationBecomesAVerificationFact() async throws {
        let memory = try W.service()
        let recorder = W.recorder(memory)
        let check = OperationCheck(condition: .structuralEffect, method: .controlValue, verdict: .passed,
            expected: "element", observed: OutcomeText.expectationValueExpected, performed: .requested)
        try await recorder.begin(.act(target: "Open", verb: .click, value: nil, section: nil),
            app: AppContextIdentity(bundleID: W.bundle))
        await recorder.record(ActionRecord(bundleID: W.bundle, element: W.open, verb: .click,
            effect: nil, windowTitleAfter: nil, check: check))
        try await recorder.end(.completed, result: .outcome(.foundActed, message: "Verified"), tool: .act)
        #expect(await memory.flush(within: .seconds(5)))
        let verifications = try await memory.perform { try await $0.facts.verifications(of: recorder.eventID) }
        let saved = try #require(verifications.first)
        let fact = QualificationPolicy.VerificationFact(eventID: saved.event.eventID, condition: saved.check.condition,
            verdict: saved.check.verdict, performed: saved.check.performed, limits: saved.check.limits,
            hasExpectation: saved.check.expected != nil && !saved.check.limits.contains(.noExpectation))
        #expect(fact.hasExpectation)
        #expect(fact.isPositive)
        await memory.close()
    }
}
