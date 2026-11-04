import AutomationRuntime
import EngineCore
import Memory
import Foundation
import PerceptionCore
import Testing

@Suite struct BatchPolicyTests {
    static func element(_ id: String = "old|Next", label: String = "Next", role: String = "AXButton") -> SceneElement {
        SceneElement(id: id, kind: .control, label: label,
                     bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), role: role)
    }

    static func scene(_ elements: [SceneElement] = [element()], app: String = "test.batch") -> SceneSnapshot {
        SceneSnapshot(bundleID: app, appName: "Fixture", windowTitle: "Document",
                      viewportPixelSize: .init(width: 800, height: 600), elements: elements)
    }

    private var scene: SceneSnapshot {
        SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Main",
                      viewportPixelSize: .init(width: 100, height: 100), elements: [])
    }
    private func step(_ target: String? = nil, expect: ScreenExpectation? = nil) -> BatchPolicy.StepFacts {
        .init(kind: .act, target: target, expectation: expect)
    }
    @Test func afterStepTable() {
        let cases: [(Outcome, Bool, Bool, Bool, BatchPolicy.Decision)] = [
            (.init(gesture: .sent, effect: .confirmed, recovery: .continue), false, false, false, .proceed),
            (.init(gesture: .sent, effect: .absent, recovery: .doNotRepeat), true, false, false, .proceed),
            (.init(gesture: .sent, effect: .absent, recovery: .doNotRepeat), false, false, true, .stop(.expectedAbsent)),
            (.init(gesture: .sent, effect: .unknown(.notClassified), recovery: .doNotRepeat), false, false, true, .proceed),
            (.init(gesture: .sent, effect: .unknown(.notReadable), recovery: .observe), false, false, false, .stop(.unknownWithoutNextTarget)),
            (.init(gesture: .notSent, effect: .notApplicable, recovery: .changeTarget(.ambiguous)), false, false, true, .stop(.ambiguous)),
            (.init(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat), false, false, true, .stop(.refused)),
            (.init(gesture: .sent, effect: .confirmed, recovery: .continue), false, true, true, .stop(.unexpectedSurface))
        ]
        for (outcome, absent, surface, next, expected) in cases {
            #expect(BatchPolicy.afterStep(outcome, expectedAbsent: absent, unexpectedSurface: surface,
                                          nextTargetPresent: next) == expected)
        }
    }
    @Test func entryAndLiveCommitGate() {
        let plan = BatchPolicy.BatchPlanFacts(steps: [step("Delete"), step("Next")], bundleID: scene.bundleID)
        #expect(BatchPolicy.validate(plan, entryScene: scene) == .stop(.committingNotLast))
        #expect(BatchPolicy.validate(.init(steps: Array(repeating: step(), count: 21), bundleID: scene.bundleID), entryScene: scene) == .stop(.refused))
        let final = BatchPolicy.BatchPlanFacts(steps: [step(), step("Next", expect: .window(title: "Done", open: true))], bundleID: scene.bundleID)
        for effect: Outcome.Effect in [.absent, .unknown(.notClassified)] {
            #expect(BatchPolicy.beforeStep(1, of: final, scene: scene, target: .notNeeded, commits: true,
                earlier: [.init(gesture: .sent, effect: effect, recovery: .doNotRepeat)], elapsed: .zero) == .stop(.committingAfterUnconfirmed))
        }
        #expect(BatchPolicy.beforeStep(0, of: plan, scene: scene, target: .notNeeded, commits: false,
                                       earlier: [], elapsed: .seconds(13)) == .stop(.timeCap))
        var pipeScene = scene
        pipeScene.elements = [Self.element("control|a b", label: "A | B")]
        let pipePlan = BatchPolicy.BatchPlanFacts(steps: [step(), step("A | B")], bundleID: scene.bundleID)
        #expect(BatchPolicy.resolveTarget(of: 1, in: pipePlan, entryScene: scene, scene: pipeScene).isPresent)
        let unseenID = BatchPolicy.BatchPlanFacts(steps: [step(), step("control|a b")], bundleID: scene.bundleID)
        #expect(BatchPolicy.resolveTarget(of: 1, in: unseenID, entryScene: scene, scene: pipeScene) == .missing)
        var duplicateEntry = pipeScene
        var sibling = pipeScene.elements[0]
        sibling.bounds = .init(x: 0.6, y: 0.6, width: 0.1, height: 0.1)
        duplicateEntry.elements.append(sibling)
        #expect(BatchPolicy.resolveTarget(of: 1, in: unseenID, entryScene: duplicateEntry, scene: pipeScene) == .ambiguous(2))
        var other = scene
        other.bundleID = "other.app"
        #expect(BatchPolicy.beforeStep(0, of: plan, scene: other, target: .notNeeded, commits: false,
                                       earlier: [], elapsed: .zero) == .stop(.otherApp))
    }
    @Test func expectedAbsenceRequiresTheOriginalTypedPredicateFact() {
        let check = OperationCheck(condition: .structuralEffect, method: .sceneDifference,
            verdict: .failed, performed: .requested)
        let already = ActOutcome(.actedUnverified, "Unchanged", check: check, noop: .statePresent)
        #expect(!BatchPolicy.expectedAbsent(step(), outcome: already))
        #expect(BatchPolicy.expectedAbsent(step(expect: .element(label: "Gone", expect: .absent)), outcome: already))
        #expect(!BatchPolicy.expectedAbsent(step(expect: .element(label: "Gone", expect: .absent)),
            outcome: ActOutcome(.actedUnverified, OutcomeText.expectationAlreadySatisfied, check: check)))
        #expect(!BatchPolicy.expectedAbsent(step(expect: .element(label: "Gone", expect: .absent)),
            outcome: ActOutcome(.actedUnverified, "Unchanged", noop: .statePresent)))
    }

    @Test func alreadySatisfiedFactMustMatchThePredicateMethodAndFailedCheck() {
        let cases: [(ScreenExpectation, OperationCheck.Method)] = [
            (.window(title: "Export", open: false), .windowCensus),
            (.element(label: "Name", expect: .value("Wanted")), .controlValue),
            (.element(label: "Enabled", expect: .state(.on)), .controlState),
            (.element(label: "Gone", expect: .absent), .sceneDifference)
        ]
        for (expectation, method) in cases {
            let facts = step(expect: expectation)
            let check = OperationCheck(condition: .structuralEffect, method: method, verdict: .failed, performed: .requested)
            let actual = ActOutcome(.actedUnverified, "Not a new effect", check: check, noop: .statePresent)
            #expect(BatchPolicy.expectedAbsent(facts, outcome: actual))
            let wrong = OperationCheck(condition: .structuralEffect, method: .none, verdict: .failed, performed: .requested)
            #expect(!BatchPolicy.expectedAbsent(facts, outcome: actual.with(check: wrong)))
            let unknown = OperationCheck(condition: .structuralEffect, method: method, verdict: .unknown, performed: .requested)
            #expect(!BatchPolicy.expectedAbsent(facts, outcome: actual.with(check: unknown)))
            let unbound = OperationCheck(condition: .none, method: method, verdict: .failed, performed: .requested)
            #expect(!BatchPolicy.expectedAbsent(facts, outcome: actual.with(check: unbound)))
        }
    }

    @Test func expectationLimitAndCommittingKeys() {
        let oversized = BatchPolicy.BatchPlanFacts(steps: [step("Next", expect: .window(
            title: String(repeating: "x", count: Todo.expectedLimit + 1), open: true))], bundleID: scene.bundleID)
        #expect(BatchPolicy.validate(oversized, entryScene: scene) == .stop(.refused))
        #expect(BatchPolicy.stepCommits(.init(kind: .pressKey, chord: KeyChord(.return)), target: nil, scene: scene))
        #expect(!BatchPolicy.stepCommits(.init(kind: .menu, item: "Format > Font"), target: nil, scene: scene))
    }

}


extension BatchPolicyTests {
    @Test func ordinaryErrorsRemainErrorsAfterDeadline() {
        #expect(BatchPolicy.stopReason(for: AutomationFailure("Unavailable"), deadlineReached: true,
                                       personInControl: false) == .error)
        #expect(BatchPolicy.stopReason(for: CancellationError(), deadlineReached: true,
                                       personInControl: false) == .timeCap)
        #expect(BatchPolicy.stopReason(for: CancellationError(), deadlineReached: false,
                                       personInControl: false) == .error)
        #expect(BatchPolicy.stopReason(for: AutomationFailure("Unavailable"), deadlineReached: true,
                                       personInControl: true) == .personInControl)
    }
}

extension BatchPolicyTests {
    @Test func foregroundSceneCannotOverrideTheOriginalWindowCensus() {
        let check = OperationCheck(condition: .structuralEffect, method: .windowCensus,
            verdict: .failed, performed: .requested)
        let step = BatchPolicy.StepFacts(kind: .act, target: "Next", expectation: .window(title: "Export", open: false))
        let before = Self.scene()
        #expect(before.windowTitle != "Export")
        let notSatisfied = ActOutcome(.actedUnverified, "Export remains open", scene: before, check: check)
        #expect(!BatchPolicy.expectedAbsent(step, outcome: notSatisfied))
        let alreadySatisfied = ActOutcome(.actedUnverified, "Already closed", scene: before,
            check: check, noop: .statePresent)
        #expect(BatchPolicy.expectedAbsent(step, outcome: alreadySatisfied))
    }
}
