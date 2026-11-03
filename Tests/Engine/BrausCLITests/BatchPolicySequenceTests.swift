import AutomationRuntime
import EngineCore
import Memory
import PerceptionCore
import Testing
@testable import braus

struct BatchPolicySequenceTests {
    private var scene: SceneSnapshot {
        SceneSnapshot(bundleID: "test.batch", appName: "Fixture", windowTitle: "Document",
            viewportPixelSize: .init(width: 100, height: 100), elements: [
                SceneElement(id: "next", kind: .control, label: "Next",
                    bounds: .init(x: 0, y: 0, width: 0.2, height: 0.2), role: "AXButton")
            ])
    }

    @Test func unknownIntermediateCountsOnlyConfirmed() async throws {
        let plan = try BatchPlan(arguments: ["batch", "Fixture", "--window", "Document", "--seat", "--",
            "act", "Next", "--then", "act", "Next", "--then", "act", "Next"])
        var performed = 0
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: plan.expectations,
            entryScene: scene, prepare: { _, _ in scene }) { _, _ in
                performed += 1
                return ActOutcome(performed == 2 ? .actedUnverified : .foundActed, "step", scene: scene,
                    check: .init(condition: .structuralEffect, method: .sceneDifference,
                                 verdict: performed == 2 ? .unknown : .passed, performed: .requested))
            }
        #expect(performed == 3)
        #expect(result.verified == 2)
        #expect(result.conclusion == .ranToEnd)
    }

    @Test func expectationParsingRemainsAvailableWithoutGestureArm() throws {
        let plan = try BatchPlan(arguments: ["batch", "Fixture", "--window", "Document", "--seat", "--",
            "act", "Next", "--expect", "{\"element\":\"Done\",\"present\":true}"])
        #expect(plan.expectations == [.element(label: "Done", expect: .present)])
    }
}


extension BatchPolicySequenceTests {
    @Test func finalUnknownDoesNotNeedAnotherTarget() async throws {
        let plan = try BatchPlan(arguments: ["batch", "Fixture", "--window", "Document", "--seat", "--",
                                            "act", "Next"])
        let result = try await BatchSequence.runPolicy(plan.steps, expectations: [], entryScene: scene,
            prepare: { _, _ in scene }) { _, _ in
                ActOutcome(.actedUnverified, "Unknown", scene: scene)
            }
        #expect(result.conclusion == .ranToEnd)
        #expect(result.attempted == 1)
        #expect(result.verified == 0)
    }
}
