@testable import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import ModelTransports
import PerceptionCore
import Testing
@testable import Turn

@MainActor
@Suite("TaskState dispatcher")
struct TaskStateDispatcherTests {
    @Test func sinkAppliedBeforeCallReturns() async throws {
        let session = TaskStateSession()
        let tools = AutomationTools(session: session, capabilities: [])
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        let arguments: JSONValue = .object(["target": .string("Submit"), "verb": .string("click")])
        _ = try await tools.call("act", arguments)
        #expect(inputs.count == 1)
        #expect(inputs.first?.origin == .dispatcher)
        #expect(inputs.first?.sequence == 1)
        #expect(inputs.first?.key == "c1.finished")
        #expect(inputs.first?.fact == .callFinished(tool: "act", subject: "Submit", outcome: session.done.outcome))
        do {
            _ = try await tools.call("act", .object(["verb": .string("click")]))
            Issue.record("Expected refusal")
        } catch {
            #expect(inputs.count == 2)
            #expect(inputs.last?.sequence == 2)
            if case .callFailed(tool: "act", reason: _) = inputs.last?.fact {} else {
                Issue.record("Missing typed failure")
            }
        }
        session.done = ActOutcome(.refused, "private read value", cause: "disabled")
        _ = try await tools.call("act", arguments)
        #expect(inputs.last?.fact == .callFailed(tool: "act", reason: "disabled"))
        #expect(!String(describing: inputs).contains("private read value"))
    }

    @Test func deliveredAttachedGuideSectionsAreTyped() async throws {
        let directory = URL.temporaryDirectory.appending(path: "attached-state-" + UUID().uuidString)
        let session = TaskStateSession()
        session.memoryDirectory = directory
        let profile = SessionProfile(attendance: .none, level: .actConnectors, memory: .learn,
            catalogue: .openAndPrivate, takeover: false, options: .init(), name: "attached-state-test")
        let tools = AutomationTools(session: session, profile: profile, guides: try attachedGuides(),
            resolveGuideApp: { _ in OpenedApp(bundleID: "test.state", version: nil, locale: "en") })
        _ = try await tools.call("open_session", .object(["app": .string("test.state")]))
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await tools.call("plan", .object(["request": .string("Submit the document"), "rows": .array([
            .object(["title": .string("Submit"), "app": .string("test.state")])])]))
        let receipts = inputs.compactMap { input -> String? in
            if case .loaded(.guide(id: _, section: let section)) = input.fact { return section }
            return nil
        }
        #expect(receipts.contains("head"))
        #expect(receipts.contains("Submit"))
        #expect(Set(inputs.map(\.sequence)).count == 1)
        #expect(Set(inputs.map(\.key)).count == inputs.count)
        let state = TaskStateFixtures.state(inputs)
        #expect(state.sections[.loaded]?.lines.count == receipts.count)
        inputs.removeAll()
        _ = try await tools.call("plan", .object(["rows": .array([
            .object(["id": .string("r1"), "title": .string("Submit"), "app": .string("test.state")])])]))
        let repeated = inputs.contains { if case .loaded(.guide) = $0.fact { return true }; return false }
        #expect(!repeated)
        _ = try await tools.call("end", .object(["outcome": .string("abandoned")]))
        await MemoryService.shared(for: directory).close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func unobservedNestedCallsDoNotEnterTheParentState() async throws {
        let nested = AutomationTools(session: TaskStateSession(), capabilities: [])
        let tools = AutomationTools(session: TaskStateSession(),
            capabilities: [LoadedGuideProvider(nestedTools: nested)])
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await tools.call("call", .object(["name": .string("help.read"), "arguments": .object([:])]))
        #expect(inputs.map(\.fact) == [.callFinished(tool: "help.read", subject: nil, outcome: nil)])
    }

    private func attachedGuides() throws -> AppGuides {
        let guide = try AppGuide.parse("""
        ---
        {"app":"test.state","locale":"en","revision":1,"name":"Editing","description":"Editing help"}
        ---
        The document holds the content.
        The sidebar holds settings.
        ## Submit
        Use the Submit control.
        ## Export
        Use the export menu.
        """)
        return AppGuides(guides: [guide], search: GuideSearch(guides: [guide]),
            estimateTokens: AutomationRuntime.TokenEstimate.tokens(in:), similarity: { _, _ in 0 })
    }

    @Test func stateFromTheRealDispatcher() async throws {
        let session = TaskStateSession()
        let tools = AutomationTools(session: session, capabilities: [LoadedGuideProvider()])
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(
            workingDirectory: URL(filePath: "/fake/task-state"), bridgeExecutable: URL(filePath: "/bin/cat"),
            allowsSuspension: true, closesSessionOnEnd: false), host: host)
        let arguments = #"{"target":"Submit","verb":"click"}"#
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "act", arguments: Data(arguments.utf8)))],
            [.toolCall(.init(id: "two", name: "act", arguments: Data(arguments.replacingOccurrences(
                of: "Submit", with: "Disabled").utf8)))],
            [.toolCall(.init(id: "three", name: "call", arguments: Data(
                "{\"name\":\"help.read\",\"arguments\":{\"app\":\"test.state\",\"sections\":[\"Submit\"]}}".utf8)))],
            [.delta("ok")]
        ])
        _ = try await runner.run(.init(prompt: "Submit", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        #expect(runner.currentTaskState?.sections[.facts]?.provenance == [1])
        #expect(runner.currentTaskState?.sections[.failedAttempts]?.provenance == [2])
        #expect(runner.currentTaskState?.sections[.loaded]?.lines.count == 2)
        #expect(runner.currentTaskState?.rendered().contains("private read value") == false)
        let text = try #require(runner.currentTaskState?.rendered())
        print("TaskState dispatched: \(text.utf8.count) bytes, \(AutomationRuntime.TokenEstimate.tokens(in: text)) tokens")
        try await runner.close()
    }

    @MainActor
    private final class TaskStateSession: AutomationSessionOperating {
        let id: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        var memoryDirectory: URL?
        var memoryApplication: String? { "test.state" }
        func applications(matching query: String?) async throws -> [ApplicationCandidate] {
            [.init(name: "Example", bundleID: "test.state", version: nil, isRunning: true)]
        }
        var done = ActOutcome(.foundActed, "private read value", check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .passed,
            observed: "private read value", performed: .requested,
            target: .init(elementID: "submit", role: nil, label: "Submit", section: nil)))
        var scene: SceneSnapshot {
            SceneSnapshot(bundleID: "test.state", appName: "Example", windowTitle: "Document",
                viewportPixelSize: .init(width: 800, height: 600), elements: [
                    SceneElement(id: "submit", kind: .control, label: "Submit",
                        bounds: .init(x: 0, y: 0, width: 0.5, height: 0.1))])
        }
        func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
        func observe() async throws -> SceneSnapshot { scene }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            target == "Disabled" ? ActOutcome(.refused, "private read value", cause: "disabled") : done
        }
        func select(control: String, item: String) async throws -> ActOutcome { done }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { done }
        func close() async {}
    }

    /// Supplies synthetic loaded-content receipts to test dispatcher propagation independently of guide retrieval.
    private nonisolated struct LoadedGuideProvider: CapabilityProviding {
        let family = "help"
        var nestedTools: AutomationTools? = nil
        var contracts: [CapabilityContract] {
            [CapabilityContract(id: .init(rawValue: "help.read"), group: family, description: "Read help.",
                inputSchema: .object(["type": .string("object")]), effect: .read, interruption: .readOnly,
                verification: .none(reason: "Read only"), channel: .braus,
                origin: .registered(provider: family), memory: .notRecorded(reason: "Help"),
                takesSession: false, parallelSafe: false)]
        }
        func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
            if let nestedTools {
                return try await nestedTools.call("act", .object([
                    "target": .string("Submit"), "verb": .string("click")]))
            }
            await MainActor.run {
                if let call = CallDispatcher.taskStateCall {
                    call.loaded.append(.guide(id: "synthetic-attached-guide", section: "head"))
                    call.loaded.append(.guide(id: "synthetic-attached-guide", section: "Submit"))
                }
            }
            return .string("Synthetic attached guide receipts")
        }
    }
}
