import Testing
@testable import Braus

struct ToolStepOutcomeTests {
    @Test(arguments: ["confirmed", "absent", "unknown(not_readable)", "unknown(not_classified)", "not_applicable"])
    func succeedsOnlyWithConfirmationOrContinuation(_ effect: String) {
        for recovery in ["continue", "retry", "do_not_repeat", "observe", "ask_person"] {
            let steps = ToolStep.steps(from: [
                "→ act {\"target\":\"Control\"}",
                "← act {\"gesture\":\"sent\",\"effect\":\"\(effect)\",\"recovery\":\"\(recovery)\"}"
            ])
            #expect(steps.count == 1)
            if effect == "confirmed" || recovery == "continue" {
                #expect(steps.first?.state == .done)
            } else {
                guard case .failed = steps.first?.state else { Issue.record("Unconfirmed step was not failed"); continue }
            }
        }
    }
}
