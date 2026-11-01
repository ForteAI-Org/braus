import Testing
@testable import Braus

struct ToolStepOutcomeTests {
    @Test func unknownEffectIsDone() {
        let steps = ToolStep.steps(from: [
            "→ act {\"target\":\"Control\"}",
            "← act {\"gesture\":\"sent\",\"effect\":\"unknown(not_classified)\",\"recovery\":\"do_not_repeat\"}"
        ])
        #expect(steps.count == 1)
        #expect(steps.first?.state == .done)
    }

    @Test(arguments: ["absent", "unknown(not_readable)"])
    func distinguishesAbsentFromUnknown(_ effect: String) {
        let steps = ToolStep.steps(from: [
            "→ act {\"target\":\"Control\"}",
            "← act {\"gesture\":\"sent\",\"effect\":\"\(effect)\",\"recovery\":\"do_not_repeat\"}"
        ])
        if effect == "absent" {
            guard case .failed = steps.first?.state else { Issue.record("Absent effect was not failed"); return }
        } else {
            #expect(steps.first?.state == .done)
        }
    }
}
