//
//  UncertainInputTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 08/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// PM-05: an uncertain input, a wrong or unreadable state, an interrupted batch and a wrong final result,
/// through the tools as a worker or an MCP client drives them, with the memory recording each call. The
/// session simulates a calculator for real: every key the tools send changes its display, so a test checks
/// the inputs sent, the effect they had, the state the caller could read, and what the call and the memory
/// say, never the text of a prompt.
@MainActor
@Suite("Uncertain input and resumption, through the tools with the memory")
struct UncertainInputTests {

    private static let bundle = "com.apple.calculator"
    private static let trace  = "calculator-trace"

    private func tools(_ session: CalculatorSession) async throws -> AutomationTools {
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "worker-1", traceID: Self.trace)
        _ = try await tools.call("plan", .object(["request": .string("Enter the calculator task once and inspect its result"),
            "rows": .array([.object(["title": .string("Enter and verify the calculator keys")])])]))
        return tools
    }

    private func batch(_ keys: [String], in session: CalculatorSession) -> JSONValue {
        .object(["steps"  : .array(keys.map { .object(["operation": .string("act"), "step": .string("r1"), "target": .string($0)]) })])
    }

    /// The batches of the trace, each with its steps in order, as the memory holds them.
    private func batches(_ session: CalculatorSession) async throws -> [(batch: AgentCall, steps: [AgentCall])] {
        let service = MemoryService.shared(for: session.directory)
        #expect(await service.flush(within: .seconds(10)))
        let status = await service.status()
        #expect(status.failed == 0 && status.partial == 0, "\(status.lastFailure ?? "")")
        var found: [(AgentCall, [AgentCall])] = []
        for call in try await service.calls(inTrace: Self.trace) where call.request.tool == .batch {
            found.append((call, try await service.ready().calls.steps(ofBatch: call.event.eventID)))
        }
        return found
    }

    /// No call of the trace is left planned or started once the producers are done.
    private func nothingUnfinished(_ session: CalculatorSession) async throws {
        let calls = try await MemoryService.shared(for: session.directory).calls(inTrace: Self.trace)
        let unfinished = calls.filter { $0.progress.status == .planned || $0.progress.status == .started }
        #expect(unfinished.isEmpty, "unfinished calls: \(unfinished.map { "\($0.request.tool) \($0.progress.status)" })")
    }

    @Test("the second key has no after scene: the batch stops without replay and records the remaining keys as never run")
    func unreadableAfterSceneStopsTheBatch() async throws {
        let session = try CalculatorSession()
        session.outcomes[2] = .actedUnverified
        session.unreadableAfterAt = 2
        let answer = try await (try await tools(session)).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2"], "the uncertain key is not sent again and no later key is sent")
        #expect(session.display == "12", "the key took effect")
        #expect(answer["status"].string == "stopped")
        #expect(answer["attemptedSteps"] == .number(2) && answer["verifiedSteps"] == .number(1))
        #expect(answer["message"].string?.contains("unknown") == true, "The current batch explains the uncertain result: \(answer)")

        let recorded = try #require(try await batches(session).first)
        guard case .batch(let stopped, let attempted, let verified)? = recorded.batch.progress.result else {
            Issue.record("the batch's result is not a batch summary: \(String(describing: recorded.batch.progress.result))"); return
        }
        #expect(stopped && attempted == 2 && verified == 1)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .skipped, .skipped, .skipped, .skipped])
        if case .outcome(let kind, _)? = recorded.steps[1].progress.result { #expect(kind == .actedUnverified) }
        else { Issue.record("the uncertain step's outcome is not recorded") }
        try await nothingUnfinished(session)
    }

    @Test("a caller reads the state after an unreadable after scene and resumes: each key once and final display 42")
    func resumptionAfterUnreadableSceneUsesTheObservedState() async throws {
        let session = try CalculatorSession()
        session.outcomes[2] = .actedUnverified
        session.unreadableAfterAt = 2
        let tools = try await tools(session)
        _ = try await tools.call("batch", batch(["1", "2", "+", "3", "0", "="], in: session))

        let observed = try await tools.call("observe", .object(["full"   : .bool(true)])).payload
        #expect(observed["scene"].string?.contains("12 @") == true,
                "the fresh observation shows what the uncertain key did")
        let answer = try await tools.call("batch", batch(["+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+", "3", "0", "="], "each key once")
        #expect(session.display == "42")
        #expect(answer["status"].string == "completed" && answer["verifiedSteps"] == .number(4))
        let recorded = try await batches(session)
        #expect(recorded.count == 2)
        #expect(recorded.last?.steps.map(\.progress.status) == [.completed, .completed, .completed, .completed])
        try await nothingUnfinished(session)
    }

    @Test("an unknown effect with the next target visible continues without replay, keeping its uncertainty")
    func visibleNextTargetAllowsUnknownEffectToContinue() async throws {
        let session = try CalculatorSession()
        session.outcomes[2] = .actedUnverified
        let tools = try await tools(session)
        let answer = try await tools.call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload
        #expect(session.inputs == ["1", "2", "+", "3", "0", "="] && session.display == "42")
        #expect(answer["status"].string == "completed" && answer["attemptedSteps"] == .number(6)
                && answer["verifiedSteps"] == .number(5))
        #expect(tools.openTask != nil, "Step completion does not end or declare success for the task")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.steps.count == 6 && recorded.steps.allSatisfy { $0.progress.status == .completed })
        guard case .batch(let stopped, let attempted, let verified)? = recorded.batch.progress.result else {
            Issue.record("No durable batch summary"); return
        }
        #expect(!stopped && attempted == 6 && verified == 5)
        let unknown = recorded.steps[1]
        guard case .outcome(let kind, _)? = unknown.progress.result else {
            Issue.record("No durable outcome for the unknown effect"); return
        }
        #expect(kind == .actedUnverified)
        let memory = MemoryService.shared(for: session.directory)
        let effect = try await memory.perform { try await $0.facts.effect(of: unknown.event.eventID) }
        let checks = try await memory.perform { try await $0.facts.verifications(of: unknown.event.eventID) }
        #expect(effect?.performed == .uncertain)
        #expect(checks.count == 1 && checks.first?.check.verdict == .unknown
                && checks.first?.check.limits.contains(.deliveryUncertain) == true)
        try await nothingUnfinished(session)
    }

    @Test("a key the tools cannot find or may not press stops the batch with nothing invented after it", arguments: [
        ActOutcomeKind.honestMiss, .refused, .ambiguous,
    ])
    func wrongStateStopsTheBatch(_ kind: ActOutcomeKind) async throws {
        let session = try CalculatorSession()
        session.outcomes[3] = kind
        let answer = try await (try await tools(session)).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+"])
        #expect(answer["status"].string == "stopped" && answer["verifiedSteps"] == .number(2))

        let recorded = try #require(try await batches(session).first)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .completed, .skipped, .skipped, .skipped])
        if case .outcome(let actual, _)? = recorded.steps[2].progress.result { #expect(actual == kind) }
        else { Issue.record("The exact refused/missing/ambiguous outcome must remain in the trace") }
        try await nothingUnfinished(session)
    }

    @Test("a step that fails mid-batch: the keys before it keep their effect, nothing after it is sent, nothing is replayed")
    func failedStepStopsTheBatch() async throws {
        let session = try CalculatorSession()
        session.failsAt = 3
        let answer = try await (try await tools(session)).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.inputs == ["1", "2", "+"] && session.display == "12", "the effects before the failure stay, and are not undone")
        #expect(answer["status"].string == "stopped" && answer["verifiedSteps"] == .number(2))
        #expect(answer["message"].string?.contains("error") == true, "\(answer)")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .failed, .skipped, .skipped, .skipped])
        try await nothingUnfinished(session)
    }

    @Test("a batch cancelled between two keys: the call ends with the cancellation, nothing after it is sent, and the keys it never sent are recorded as never run")
    func cancelledBatchRecordsTheRestAsNeverRun() async throws {
        let session = try CalculatorSession()
        session.cancelsAt = 3
        let tools = try await tools(session), request = batch(["1", "2", "+", "3", "0", "="], in: session)
        // The call runs in a task of its own, the one the session cancels, as a client's cancellation would.
        let call = Task { try await tools.call("batch", request) }
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(session.inputs == ["1", "2", "+"], "no key after the cancellation")
        let recorded = try #require(try await batches(session).first)
        // G76 D1: a cancellation is recorded as cancelled, no longer as failed with its error (R21, R23).
        #expect(recorded.batch.progress.status == .cancelled)
        #expect(recorded.steps.map(\.progress.status) == [.completed, .completed, .completed, .skipped, .skipped, .skipped])
        try await nothingUnfinished(session)
    }

    @Test("cancellation thrown after a key's side effect keeps the child cancelled and its delivery uncertain", arguments: [1, 2])
    func cancellationThrownDuringDeliveryKeepsItsSideEffectAndUncertainty(_ position: Int) async throws {
        let session = try CalculatorSession()
        let tools = try await tools(session)
        let stoppedTask = try #require(tools.openTask?.taskID)
        session.cancelsAndThrowsAt = position
        let keys = ["1", "2", "+", "3", "0", "="]
        let expectedInputs = Array(keys.prefix(position))
        let expectedDisplay = expectedInputs.joined()
        let request = batch(keys, in: session)
        let call = Task { try await tools.call("batch", request) }
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(session.inputs == expectedInputs && session.display == expectedDisplay, "The side effects remain, without replay")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.batch.progress.status == .cancelled)
        try #require(recorded.steps.count == keys.count)
        let expectedStatuses: [AgentCallStatus] = keys.indices.map { index in
            index < position - 1 ? .completed : index == position - 1 ? .cancelled : .skipped
        }
        #expect(recorded.steps.map(\.progress.status) == expectedStatuses)
        let child = recorded.steps[position - 1]
        let memory = MemoryService.shared(for: session.directory)
        let effect = try await memory.perform { try await $0.facts.effect(of: child.event.eventID) }
        let checks = try await memory.perform { try await $0.facts.verifications(of: child.event.eventID) }
        if position == 2 {
            let first = recorded.steps[0]
            let firstChecks = try await memory.perform { try await $0.facts.verifications(of: first.event.eventID) }
            #expect(firstChecks.count == 1 && firstChecks.first?.check.verdict == .passed,
                    "The earlier confirmed gesture makes a stale false uncertainty observable")
        }
        #expect(effect?.performed == .uncertain)
        #expect(checks.count == 1 && checks.first?.check.verdict == .unknown
                && checks.first?.check.limits.contains(.deliveryUncertain) == true
                && checks.first?.check.limits.contains(.noAfterScene) == true)
        try await nothingUnfinished(session)
        tools.markTaskInterrupted()
        try await tools.finishInterruptedTask()
        #expect(tools.openTask == nil)
        session.cancelsAndThrowsAt = nil
        let next = try await tools.call("plan", .object(["request": .string("Continue from the calculator state after Stop"),
            "rows": .array([.object(["title": .string("Read the display before deciding the next key")])])])).payload
        #expect(next["status"].string == "planned")
        #expect(next["continues"]["task"].string == stoppedTask)
        #expect(next["continues"]["uncertain_gesture"] == .bool(true),
                "The resumed worker must see the uncertain delivery, not a stale or unknown gesture: \(next)")
        #expect(tools.openTask?.taskID != stoppedTask && session.inputs == expectedInputs && session.display == expectedDisplay)
    }

    @Test("cancellation during the entry observation skips every key and cancels the parent call")
    func cancellationBeforeTheFirstKeyKeepsAllChildrenSkipped() async throws {
        let session = try CalculatorSession()
        let tools = try await tools(session)
        session.cancelsOnObserve = true
        let request = batch(["1", "2", "+", "3", "0", "="], in: session)
        let call = Task { try await tools.call("batch", request) }
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(session.inputs.isEmpty && session.display == "0")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.batch.progress.status == .cancelled)
        #expect(recorded.steps.count == 6 && recorded.steps.allSatisfy { $0.progress.status == .skipped })
        try await nothingUnfinished(session)
    }

    @Test("cancellation during text classification sends no text and cancels the started child")
    func cancellationBetweenClassificationAndDeliverySendsNothing() async throws {
        let session = try CalculatorSession()
        let tools = try await tools(session)
        // The first classification admits privacy fields; the second runs after the child starts.
        session.cancelsAtClassification = 2
        let request: JSONValue = .object(["steps": .array([
            .object(["operation": .string("type_text"), "step": .string("r1"),
                     "target": .string("Expression"), "text": .string("123")]),
            .object(["operation": .string("act"), "step": .string("r1"), "target": .string("1")])
        ])])
        let call = Task { try await tools.call("batch", request) }
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(session.classificationReads == 2)
        #expect(session.textDispatches == 0 && session.inputs.isEmpty && session.display == "0")
        let recorded = try #require(try await batches(session).first)
        #expect(recorded.batch.progress.status == .cancelled)
        #expect(recorded.steps.map(\.progress.status) == [.cancelled, .skipped])
        let child = try #require(recorded.steps.first)
        let effect = try await MemoryService.shared(for: session.directory).perform {
            try await $0.facts.effect(of: child.event.eventID)
        }
        #expect(effect?.performed == OperationCheck.Performed.none, "The archive records that cancellation preceded delivery")
        try await nothingUnfinished(session)
    }

    @Test("every key verified but the result is 41: the batch says its steps completed and shows 41; nothing claims the task succeeded")
    func completedBatchIsNotATaskSuccess() async throws {
        let session = try CalculatorSession()
        session.wrongResult = "41"
        let answer = try await (try await tools(session)).call("batch", batch(["1", "2", "+", "3", "0", "="], in: session)).payload

        #expect(session.display == "41")
        #expect(answer["status"].string == "completed" && answer["verifiedSteps"] == .number(6))
        let last = String(decoding: try JSONEncoder().encode(answer["observation"]), as: UTF8.self)
        #expect(last.contains("41 @"), "the last step's observation carries the display the caller must judge: \(last)")
        #expect(Set(answer.object.map { Array($0.keys) } ?? []) == ["status", "message", "attemptedSteps", "verifiedSteps", "requested", "observation"],
                "a batch reports its steps, not a task's outcome")
        let recorded = try #require(try await batches(session).first)
        guard case .batch(let stopped, let attempted, let verified)? = recorded.batch.progress.result else {
            Issue.record("no batch summary"); return
        }
        #expect(!stopped && attempted == 6 && verified == 6)
        try await nothingUnfinished(session)
    }
}

/// CalculatorSession is a session over a simulated calculator: every key `act` names changes the display
/// as the real one would, and the outcome each key answers is scripted by its position, so an uncertain
/// verdict can follow a key that really took effect. It records every key sent.
@MainActor
final class CalculatorSession: AutomationSessionOperating {

    let directory: URL
    var id: UUID? = UUID()

    /// What the key at each position (from 1) answers; any other answers found_acted.
    var outcomes: [Int: ActOutcomeKind] = [:]
    /// The key at this position throws instead of acting.
    var failsAt: Int?
    /// The key at this position cancels the task that runs the call, after its effect.
    var cancelsAt: Int?
    /// Applies the side effect, cancels the caller and throws before returning a read-back.
    var cancelsAndThrowsAt: Int?
    /// Cancels the caller while the entry scene is being acquired, before any key can run.
    var cancelsOnObserve = false
    var cancelsAtClassification: Int?
    private(set) var classificationReads = 0
    private(set) var textDispatches = 0
    /// What `=` shows instead of the sum.
    var wrongResult: String?
    /// The gesture can take effect while its returned scene cannot be read.
    var unreadableAfterAt: Int?

    private(set) var inputs: [String] = []
    private(set) var display = "0"
    private var left: Int?
    private var entry = ""

    init() throws {
        directory = try W.directory()
    }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { "com.apple.calculator" }

    func open(application: String, window: String?) async throws -> SceneSnapshot { scene() }
    func observe() async throws -> SceneSnapshot {
        if cancelsOnObserve {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return scene()
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let position = inputs.count + 1
        if failsAt == position {
            inputs.append(target)
            throw AutomationFailure("The calculator's window went away.")
        }
        inputs.append(target)
        press(target)
        if cancelsAndThrowsAt == position {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        if cancelsAt == position { withUnsafeCurrentTask { $0?.cancel() } }
        let kind = outcomes[position] ?? .foundActed
        let check: OperationCheck
        switch kind {
        case .foundActed:
            // The deterministic session's read-back oracle; the tests independently verify the key stream and sum.
            check = OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .passed,
                expected: display, observed: display, performed: .requested)
        case .actedUnverified:
            check = OperationCheck(condition: .valueReadBack, method: .controlValue, verdict: .unknown,
                limits: unreadableAfterAt == position ? [.deliveryUncertain, .noAfterScene] : [.deliveryUncertain],
                performed: .uncertain)
        default: check = .unchecked(performed: .none)
        }
        return ActOutcome(kind, "clicked '\(target)'", scene: unreadableAfterAt == position ? nil : scene(), check: check)
    }

    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("not here") }
    func classify(_ input: InputRequest.Input, section: String?) async -> TextTargetClass {
        classificationReads += 1
        if classificationReads == cancelsAtClassification { withUnsafeCurrentTask { $0?.cancel() } }
        return AttestedFields.classify(input)
    }
    func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        try await deliver(input, section: section)
    }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        textDispatches += 1
        throw AutomationFailure("not here")
    }
    func close() async { id = nil }

    private func press(_ key: String) {
        switch key {
        case "+":
            left  = Int(display)
            entry = ""
        case "=":
            let sum = (left ?? 0) + (Int(entry) ?? 0)
            display = wrongResult ?? String(sum)
            entry   = ""
        default:
            entry   = entry == "0" ? key : entry + key
            display = entry
        }
    }

    private func scene() -> SceneSnapshot {
        let keys = ["1", "2", "3", "0", "+", "="].enumerated().map { index, key in
            SceneElement(id: "control|\(key)", kind: .control, label: key,
                         bounds: NormalizedRect(x: 0.1 + 0.12 * Double(index), y: 0.6, width: 0.1, height: 0.1),
                         role: "AXButton", labelOrigin: .title)
        }
        let shown = SceneElement(id: "text|display", kind: .text, label: display,
                                 bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.15), role: "AXStaticText")
        return SceneSnapshot(bundleID: "com.apple.calculator", appName: "Calculator", windowTitle: "Calculator",
                             viewportPixelSize: ViewportPixelSize(width: 460, height: 816), elements: [shown] + keys + (cancelsAtClassification == nil ? [] : [
                                SceneElement(id: "field|expression", kind: .control, label: "Expression",
                                    bounds: NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.1), role: "AXTextField")
                             ]))
    }
}

extension JSONValue {

    /// Reads structured results before decoding a historical JSON content item.
    var payload: JSONValue {
        if self["structuredContent"] != .null { return self["structuredContent"] }
        guard let text = self["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return self }
        return value
    }
}
