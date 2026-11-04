import AutomationRuntime
import EngineCore
import Memory
import PerceptionCore
import Testing
@testable import braus

@Suite("Batch command")
struct BatchTests {

    private let header = ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--allow-unvalidated-build", "--"]

    @Test("the requested sequence preserves labels and shares one application and window")
    func parsesSequence() throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then",
            "act", "Auto-create sub paths", "--verb", "set_toggle", "--value", "on", "--then", "act", "Create"
        ])
        #expect(plan.application == "Pro Tools")
        #expect(plan.invocation.options["window"] == "New Paths")
        #expect(plan.steps.count == 3)
        guard case .select(let control, let item) = plan.steps[0], case .act(let action) = plan.steps[1] else {
            Issue.record("wrong step types")
            return
        }
        #expect(control == "Mono" && item == "Stereo")
        #expect(action.target == "Auto-create sub paths")
        #expect(action.verb == .setToggle && action.desiredState == .on)
        #expect(plan.invocation.options["verb"] == nil)
    }

    @Test("invalid later steps and options reject the whole plan before execution", arguments: [
        ["act", "Create", "--then"],
        ["act", "Create", "--then", "act", "Cancel", "--verb", "typo"],
        ["act", "Create", "--then", "select", "Mono"],
        ["act", "Create", "--then", "act", "Auto-create sub paths", "--verb", "set_toggle"],
        ["act", "Create", "--window", "I/O Setup"],
        ["act", "Create", "--dry-run"],
        ["act", "Create", "--value", "on"],
        ["act", "Create", "--section", "one", "--section", "two"],
        ["act", "Create", "--section", "--then", "act", "Cancel"],
        ["select", "Mono", "Stereo", "--allow-destructive"],
        ["select", "Mono", ""],
        ["--then", "act", "Create"],
        []
    ])
    func rejectsMalformedSteps(_ steps: [String]) {
        #expect(throws: (any Error).self) { try BatchPlan(arguments: header + steps) }
    }

    @Test("batch requires a named window, Seat, delimiter and supported shared options", arguments: [
        ["batch", "Pro Tools", "--seat", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--dry-run", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "--seat", "--", "act", "Create"],
        ["batch", "Pro Tools", "--window", "New Paths", "--seat", "--seet", "--", "act", "Create"]
    ])
    func rejectsMalformedHeader(_ words: [String]) {
        #expect(throws: (any Error).self) { try BatchPlan(arguments: words) }
    }

    private func scene(_ labels: [String] = ["Mono", "Auto-create sub paths", "Create", "First", "Next", "Submit"]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test.batch", appName: "Fixture", windowTitle: "New Paths",
            viewportPixelSize: .init(width: 100, height: 100), elements: labels.enumerated().map { index, label in
                SceneElement(id: "target-\(index)", kind: .control, label: label,
                    bounds: .init(x: Double(index) * 0.1, y: 0, width: 0.1, height: 0.1), role: "AXButton")
            })
    }

    private func confirmed(scene: SceneSnapshot) -> ActOutcome {
        ActOutcome(.foundActed, "Synthetic oracle confirmed the effect.", scene: scene,
            check: .init(condition: .structuralEffect, method: .sceneDifference,
                         verdict: .passed, performed: .requested))
    }

    @MainActor
    @Test("steps run once in order; an explicitly already-set toggle continues")
    func orderedExecution() async throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then",
            "act", "Auto-create sub paths", "--verb", "set_toggle", "--value", "on", "--then", "act", "Create"
        ])
        let entry = scene()
        let expected = ScreenExpectation.element(label: "Create", expect: .present)
        var calls: [Int] = []
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil, expected],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            if number == 3 { #expect(ScreenExpectation.current == expected) }
            if number == 2 {
                return ActOutcome(.actedNoop, "The toggle is already on.", scene: entry,
                    check: .init(condition: .requestedStateAlreadyPresent, method: .controlState,
                                 verdict: .passed, expected: "on", observed: "on", performed: .none),
                    noop: .statePresent)
            }
            return confirmed(scene: entry)
        }
        #expect(calls == [1, 2, 3])
        #expect(result.conclusion == .ranToEnd)
        #expect(result.attempted == 3 && result.verified == 3)
        #expect(result.failure == nil)
    }

    @MainActor
    @Test("a refusal, ambiguity, miss, generic no-op or dry run stops with its typed policy reason", arguments: [
        ActOutcomeKind.ambiguous, .honestMiss, .refused, .actedNoop, .dryRun
    ])
    func stopsOnOutcome(_ kind: ActOutcomeKind) async throws {
        let plan = try BatchPlan(arguments: header + [
            "select", "Mono", "Stereo", "--then", "act", "Auto-create sub paths", "--then", "act", "Create"
        ])
        let entry = scene()
        var calls: [Int] = []
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil, nil],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            return number == 2 ? ActOutcome(kind, "Answered.", scene: entry) : confirmed(scene: entry)
        }
        let reason: BatchStopReason = kind == .ambiguous ? .ambiguous : kind == .honestMiss ? .targetMissing : .refused
        #expect(result.conclusion == .stopped(at: 1, reason: reason))
        #expect(result.attempted == 2 && result.verified == 1)
        #expect(result.failure == nil)
        #expect(calls == [1, 2])
    }

    @MainActor
    @Test("an unknown effect proceeds only when the next target is visible", arguments: [false, true])
    func unknownEffectRequiresNextTarget(_ nextVisible: Bool) async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Next"])
        let entry = scene()
        let after = scene(nextVisible ? ["First", "Next"] : ["First"])
        var calls: [Int] = []
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil],
            entryScene: entry, prepare: { number, _ in number == 1 ? entry : after }) { number, _ in
            calls.append(number)
            return number == 1
                ? ActOutcome(.actedUnverified, "No effect could be attributed.", scene: after,
                             check: .unchecked(performed: .requested))
                : confirmed(scene: after)
        }
        #expect(calls == (nextVisible ? [1, 2] : [1]))
        #expect(result.conclusion == (nextVisible ? .ranToEnd : .stopped(at: 0, reason: .unknownWithoutNextTarget)))
        #expect(result.attempted == (nextVisible ? 2 : 1))
        #expect(result.verified == (nextVisible ? 1 : 0))
        #expect(result.failure == nil)
    }

    @MainActor
    @Test("a committing final step requires an expectation and confirmed earlier effects")
    func finalCommitGates() async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Submit"])
        let entry = scene()
        let expected = ScreenExpectation.element(label: "Submitted", expect: .present)
        var calls: [Int] = []
        let missing = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            return confirmed(scene: entry)
        }
        #expect(missing.conclusion == .stopped(at: 0, reason: .committingNotLast))
        #expect(missing.attempted == 0 && calls.isEmpty)
        let unknown = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, expected],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            return ActOutcome(.actedUnverified, "Unknown effect.", scene: entry,
                              check: .unchecked(performed: .requested))
        }
        #expect(unknown.conclusion == .stopped(at: 1, reason: .committingAfterUnconfirmed))
        #expect(unknown.attempted == 1 && unknown.verified == 0 && calls == [1])
        calls.removeAll()
        let successful = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, expected],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            if number == 2 { #expect(ScreenExpectation.current == expected) }
            return self.confirmed(scene: entry)
        }
        #expect(successful.conclusion == .ranToEnd)
        #expect(successful.attempted == 2 && successful.verified == 2 && calls == [1, 2])
    }

    @MainActor
    @Test("a thrown delivery error retains its step and stops without cancelling the task")
    func thrownFailure() async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Create"])
        let entry = scene()
        var calls: [Int] = []
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil],
            entryScene: entry, prepare: { _, _ in entry }) { number, _ in
            calls.append(number)
            throw CancellationError()
        }
        let error = try #require(result.failure as? BatchFailure)
        #expect(error.step == 1 && error.total == 2)
        #expect(error.cause is CancellationError)
        #expect(!Task.isCancelled)
        #expect(result.conclusion == .stopped(at: 0, reason: .error))
        #expect(result.attempted == 1 && result.verified == 0 && calls == [1])
    }

    @Test("actual cancellation after the first step prevents the next action")
    func cancellation() async throws {
        let plan = try BatchPlan(arguments: header + ["act", "First", "--then", "act", "Create"])
        let task = Task { @MainActor in
            let entry = scene()
            var calls: [Int] = []
            let result = try await BatchSequence.runPolicy(plan.steps, expectations: [nil, nil],
                entryScene: entry, prepare: { _, _ in entry }) { number, _ in
                calls.append(number)
                withUnsafeCurrentTask { $0?.cancel() }
                return confirmed(scene: entry)
            }
            #expect(result.conclusion == .stopped(at: 0, reason: .error))
            #expect(result.failure is CancellationError)
            #expect(!(result.failure is BatchFailure))
            #expect(result.attempted == 1 && result.verified == 1)
            return calls
        }
        #expect(try await task.value == [1])
    }
}
