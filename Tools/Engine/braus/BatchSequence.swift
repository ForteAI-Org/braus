import AutomationRuntime
import EngineCore
import Memory
import PerceptionCore

/// BatchSequence executes each step once under the shared admission and continuation policy.
/// Its caller owns the shared Seat and cleanup. Earlier effects are never rolled back or replayed.
enum BatchSequence {

    struct PolicyResult {
        let conclusion: BatchConclusion
        let attempted: Int
        let verified: Int
        let failure: (any Error)?
    }

    /// Runs the same policy as MCP, using one preparation reading before each command.
    @MainActor
    static func runPolicy(
        _ steps: [BatchStep],
        expectations: [ScreenExpectation?],
        entryScene: SceneSnapshot,
        bundleID: String? = nil,
        prepare: (Int, BatchStep) async throws -> SceneSnapshot,
        windowNumber: () -> Int? = { nil },
        perform: (Int, BatchStep) async throws -> ActOutcome
    ) async throws -> PolicyResult {
        let began = ContinuousClock.now
        let deadline = began.advanced(by: BatchPolicy.timeCap)
        let facts = steps.enumerated().map { index, step in
            step.facts(expectation: expectations.indices.contains(index) ? expectations[index] : nil)
        }
        let plan = BatchPolicy.BatchPlanFacts(steps: facts, bundleID: bundleID ?? entryScene.bundleID)
        var decision = BatchPolicy.validate(plan, entryScene: entryScene)
        var earlier: [Outcome] = []
        var attempted = 0
        func result(_ conclusion: BatchConclusion, failure: (any Error)? = nil) -> PolicyResult {
            PolicyResult(conclusion: conclusion, attempted: attempted,
                         verified: earlier.filter { $0.effect == .confirmed }.count, failure: failure)
        }
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return result(.stopped(at: index, reason: .error), failure: CancellationError()) }
            if AutomationCallInterruption.current?.wasInterrupted == true { decision = .stop(.personInControl) }
            else if InterruptibleWait.current?.stopRequested == true { decision = .stop(.timeCap) }
            if case .stop(let reason) = decision { return result(.stopped(at: index, reason: reason)) }
            do {
                let scene = try await prepare(index + 1, step)
                try Task.checkCancellation()
                let target = BatchPolicy.resolveTarget(of: index, in: plan, entryScene: entryScene, scene: scene)
                decision = BatchPolicy.beforeStep(index, of: plan, scene: scene, target: target,
                    commits: BatchPolicy.stepCommits(facts[index], target: target.element, scene: scene),
                    earlier: earlier, elapsed: began.duration(to: .now))
                if AutomationCallInterruption.current?.wasInterrupted == true { decision = .stop(.personInControl) }
                if case .stop(let reason) = decision { return result(.stopped(at: index, reason: reason)) }
                let beforeWindow = windowNumber()
                attempted += 1
                let rawResult = try await BatchStepBoundary.perform(until: deadline) {
                    try await ScreenExpectation.$current.withValue(facts[index].expectation) {
                        try Task.checkCancellation()
                        return try await perform(index + 1, step)
                    }
                }
                let done = rawResult.withStatedCheck
                earlier.append(done.outcome)
                if Task.isCancelled { return result(.stopped(at: index, reason: .error), failure: CancellationError()) }
                let next = done.scene.map {
                    BatchPolicy.resolveTarget(of: index + 1, in: plan, entryScene: entryScene, scene: $0).isPresent
                } ?? false
                let announced: Bool
                if case .window? = facts[index].expectation { announced = true } else { announced = false }
                decision = BatchPolicy.afterStep(done.outcome,
                    expectedAbsent: BatchPolicy.expectedAbsent(facts[index], outcome: done),
                    unexpectedSurface: beforeWindow != windowNumber() && !announced, nextTargetPresent: next, isLastStep: index == steps.count - 1)
                if AutomationCallInterruption.current?.wasInterrupted == true { decision = .stop(.personInControl) }
                else if ContinuousClock.now >= deadline || InterruptibleWait.current?.stopRequested == true
                    || done.notSent == .humanIntervention { decision = .stop(.timeCap) }
                if case .stop(let reason) = decision { return result(.stopped(at: index, reason: reason)) }
            } catch {
                if Task.isCancelled { return result(.stopped(at: index, reason: .error), failure: CancellationError()) }
                let reason: BatchStopReason = BatchPolicy.stopReason(for: error, deadlineReached: ContinuousClock.now >= deadline,
                    personInControl: AutomationCallInterruption.current?.wasInterrupted == true)
                return result(.stopped(at: index, reason: reason), failure: reason == .error
                    ? BatchFailure(step: index + 1, total: steps.count, cause: error) : nil)
            }
        }
        return result(.ranToEnd)
    }

}

/// BatchFailure preserves the failed step and cause; previous steps may already have taken effect.
struct BatchFailure: Error, CustomStringConvertible {
    let step: Int
    let total: Int
    let cause: any Error

    var description: String {
        "batch stopped at step \(step)/\(total): \(cause). Later steps were not run; earlier effects remain."
    }
}
