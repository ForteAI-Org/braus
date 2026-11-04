import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

@MainActor
struct BatchRunnerTests {
    private func row(_ target: String) -> JSONValue {
        .object(["operation": .string("act"), "target": .string(target)])
    }

    private func run(_ session: BatchTestSession, rows: [JSONValue]) async throws -> JSONValue {
        try await AutomationTools(session: session).call("batch", .object([
            "steps": .array(rows)
        ]))
    }

    @Test func translatesLaterIDAndReturnsOnlyFinalScene() async throws {
        let session = BatchTestSession()
        session.results = [ActOutcome(.foundActed, "first", scene: BatchPolicyTests.scene([
            BatchPolicyTests.element("new|Next")
        ])), ActOutcome(.foundActed, "second", scene: BatchPolicyTests.scene())]
        let value = try await run(session, rows: [row("Next"), row("old|Next")])
        #expect(session.targets == ["Next", "Next"])
        let text = String(decoding: try JSONValue.canonicalEncoder().encode(value), as: UTF8.self)
        #expect(text.contains("1. "))
        #expect(text.contains("2. "))
        #expect(session.reads == 1)
    }

    @Test func policyStepsReachTaskStateBeforeReturning() async throws {
        let session = BatchTestSession()
        let tools = AutomationTools(session: session)
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await tools.call("batch", .object([
            "steps": .array([row("Next"), row("Next")])
        ]))
        #expect(inputs.count == 2)
        for input in inputs {
            guard case .callFinished(let tool, _, let outcome) = input.fact else {
                Issue.record("Expected a completed step fact")
                continue
            }
            #expect(tool == "act")
            #expect(outcome?.effect == .confirmed)
        }
        #expect(tools.latestScene != nil)
    }

    @Test func policyAdmissionReportsTypedFailure() async throws {
        let session = BatchTestSession()
        let tools = AutomationTools(session: session)
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await tools.call("batch", .object([
            "steps": .array([row("Missing")])
        ]))
        #expect(inputs.map(\.fact) == [.callFailed(tool: "batch", reason: "target_missing")])
    }

    @Test func policyTakeoverReportsOutcomeWithoutFailure() async throws {
        let session = BatchTestSession()
        let interruption = AutomationCallInterruption()
        session.results = [ActOutcome(.refused, "person_in_control", notSent: .humanIntervention)]
        session.afterStep = { interruption.interruptForHumanControl() }
        let tools = AutomationTools(session: session)
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await AutomationCallInterruption.$current.withValue(interruption) {
            try await tools.call("batch", .object([
                "steps": .array([row("Next"), row("Next")])
            ]))
        }
        #expect(session.targets.count == 1)
        #expect(inputs.map(\.fact) == [.callFinished(tool: "act", subject: nil,
            outcome: Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat))])
    }

    @Test func missingTargetDoesNotAct() async throws {
        let session = BatchTestSession()
        let value = try await run(session, rows: [row("Missing")])
        #expect(session.targets.isEmpty)
        #expect(String(decoding: try JSONValue.canonicalEncoder().encode(value), as: UTF8.self).contains("target_missing"))
    }

    @Test func takeoverStopsBeforeNextStep() async throws {
        let interruption = AutomationCallInterruption()
        let session = BatchTestSession()
        session.afterStep = { if session.targets.count == 2 { interruption.interruptForHumanControl() } }
        let value = try await AutomationCallInterruption.$current.withValue(interruption) {
            try await run(session, rows: [row("Next"), row("Next"), row("Next")])
        }
        #expect(session.targets.count == 2)
        let text = String(decoding: try JSONValue.canonicalEncoder().encode(value), as: UTF8.self)
        #expect(text.contains("person_in_control"))
        #expect(!text.contains("retry"))
    }

    @Test func committingWithoutExpectationRefusesWholeBatch() async throws {
        let session = BatchTestSession()
        session.entry = BatchPolicyTests.scene([BatchPolicyTests.element(label: "Send")])
        _ = try await run(session, rows: [row("Send")])
        #expect(session.targets.isEmpty)
    }

    @Test func batchIsPresentWithoutInlineContinuation() {
        let definitions = AutomationTools.definitions
        #expect(definitions.contains { $0["name"].string == "batch" })
        #expect(definitions.contains { $0["name"].string == "act" })
        #expect(definitions.allSatisfy { $0["inputSchema"]["properties"]["then"] == .null })
    }

}

@MainActor
final class BatchTestSession: AutomationSessionOperating {
    let id: UUID?
    var entry = BatchPolicyTests.scene()
    var results: [ActOutcome] = []
    var targets: [String] = []
    var reads = 0
    var suppliesChecks = true
    var onObserve: (() throws -> Void)?
    var afterStep: (() -> Void)?
    var memoryApplication: String? { entry.bundleID }

    init(id: UUID = UUID()) { self.id = id }
    func observe() async throws -> SceneSnapshot {
        reads += 1
        try onObserve?()
        return entry
    }
    func open(application: String, window: String?) async throws -> SceneSnapshot { entry }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        targets.append(target)
        let result = results.isEmpty ? ActOutcome(.foundActed, "clicked", scene: entry) : results.removeFirst()
        afterStep?()
        if suppliesChecks, result.kind == .foundActed, result.check == nil {
            return result.with(check: .init(condition: .structuralEffect, method: .sceneDifference,
                                           verdict: .passed, performed: .requested))
        }
        return result
    }
    func select(control: String, item: String) async throws -> ActOutcome {
        try await act(target: control, verb: .click, section: nil, desiredState: nil)
    }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await act(target: "input", verb: .click, section: section, desiredState: nil)
    }
    func menu(path: String) async throws -> ActOutcome {
        try await act(target: path, verb: .click, section: nil, desiredState: nil)
    }
    func close() async {}
}
