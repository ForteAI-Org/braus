import Testing
@testable import Braus

struct ToolStepOutcomeTests {
    @Test func omittedContentIsNotShownAsLiteralTypedText() {
        let lines = [#"→ insert_text {"text":"[withheld]"}"#,
                     #"← insert_text {"gesture":"sent","effect":"unknown(not_watched)","message":"Value unverified","recovery":"do_not_repeat"}"#]
        let shown = TranscriptWording.toolSteps(ToolStep.steps(from: lines), ending: .completed)[0]
        #expect(shown.contains("Content omitted"))
        #expect(!shown.contains("[withheld]"))
        #expect(!shown.contains("“Content omitted”"))
        #expect(ToolStep.copyText(of: lines, isExpanded: true, ending: .completed, detailed: true)
            .contains("[withheld]"))
    }

    private func step(gesture: String, effect: String, recovery: String = "continue") -> ToolStep {
        ToolStep.steps(from: [
            #"→ act {"target":"prova-t2-b.rtf","verb":"double_click"}"#,
            "← act {\"gesture\":\"\(gesture)\",\"effect\":\"\(effect)\",\"recovery\":\"\(recovery)\",\"message\":\"Observe before retrying\"}"
        ])[0]
    }

    @Test func sceneChangeDoesNotConfirmUncertainDelivery() {
        let read = step(gesture: "uncertain", effect: "confirmed", recovery: "observe")
        guard case .uncertain = read.state else { Issue.record("Lost delivery uncertainty"); return }
        #expect(TranscriptWording.toolSteps([read], ending: .completed)[0].contains("Result unverified"))
        #expect(TranscriptWording.toolSteps([read], ending: .completed)[0].contains("Observe before retrying"))
    }

    @Test func continuationAdviceIsNotVerification() {
        for recovery in ["continue", "retry", "do_not_repeat", "observe", "ask_person"] {
            guard case .uncertain = step(gesture: "sent", effect: "unknown(not_watched)", recovery: recovery).state
            else { Issue.record("Recovery advice promoted an unknown effect to success"); continue }
        }
        #expect(step(gesture: "sent", effect: "confirmed").state == .done)
        guard case .failed = step(gesture: "not_sent", effect: "absent").state else {
            Issue.record("An unsent input was not distinguished")
            return
        }
    }

    @Test func sentInputWithNoObservedEffectIsNotDisplayedAsUnsent() {
        let sent = step(gesture: "sent", effect: "absent")
        guard case .unchanged = sent.state else {
            Issue.record("A delivered input with no observed change was called unsent")
            return
        }
        let shown = TranscriptWording.toolSteps([sent], ending: .completed)[0]
        #expect(shown.contains("No observable change"))
        #expect(!shown.contains("Could not"))
        guard case .failed = step(gesture: "not_sent", effect: "absent").state else {
            Issue.record("An unsent input must remain a refusal")
            return
        }
    }

    @Test func completedTaskKeepsVerificationScopeAndReadablePlan() {
        let lines = [
            #"→ plan {"rows":[{"id":"r1","title":"Check the missing file"}]}"#,
            #"← plan {"rows":[{"id":"r1","title":"Check the missing file","status":"pending"}]}"#,
            "Plan: r1 pending",
            #"→ end {"outcome":"completed"}"#,
            "Plan updated: r1 abandoned",
            #"← end {"outcome":"completed","completion_evidence":{"checks":"unknown","goal_match":"not_assessed"}}"#
        ]
        let steps = ToolStep.steps(from: lines)
        #expect(steps.count == 2)
        let shown = TranscriptWording.toolSteps(steps, ending: .completed).joined(separator: "\n")
        #expect(shown.contains("Check the missing file"))
        #expect(!shown.contains("r1"))
        #expect(shown.contains("Some checks remain unverified"))
        #expect(shown.contains("Overall goal not independently assessed"))
    }
}
