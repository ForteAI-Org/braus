import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import ModelTransports
import PerceptionCore
import Switches
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
        let arguments: JSONValue = .object(["session": .string(session.id!.uuidString),
                                            "target": .string("Submit"), "verb": .string("click")])
        _ = try await tools.call("act", arguments)
        #expect(inputs.count == 1)
        #expect(inputs.first?.origin == .dispatcher)
        #expect(inputs.first?.sequence == 1)
        #expect(inputs.first?.key == "c1.finished")
        #expect(inputs.first?.fact == .callFinished(tool: "act", subject: "Submit", outcome: session.done.outcome))
        do {
            _ = try await tools.call("unknown", .object([:]))
            Issue.record("Expected refusal")
        } catch {
            #expect(inputs.count == 2)
            #expect(inputs.last?.sequence == 2)
            if case .callFailed(tool: "unknown", reason: _) = inputs.last?.fact {} else {
                Issue.record("Missing typed failure")
            }
        }
        session.done = ActOutcome(.refused, "private read value", cause: "disabled")
        _ = try await tools.call("act", arguments)
        #expect(inputs.last?.fact == .callFailed(tool: "act", reason: "disabled"))
        #expect(!String(describing: inputs).contains("private read value"))
    }

    @Test func deliveredGuideSectionsAreTyped() async throws {
        let capability = try guideCapability()
        let tools = AutomationTools(session: TaskStateSession(), capabilities: [GuideProvider(guide: capability)])
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        let arguments: JSONValue = .object(["app": .string("test.state"), "sections": .array([.string("Submit")])])
        let observed = try await tools.call("help.read", arguments)
        let sections = inputs.compactMap { input -> String? in
            if case .loaded(.guide(id: _, section: let section)) = input.fact { return section }
            return nil
        }
        #expect(sections == ["head", "Submit"])
        #expect(inputs.allSatisfy { $0.sequence == 1 })
        #expect(Set(inputs.map(\.key)).count == inputs.count)
        let state = TaskStateFixtures.state(inputs)
        #expect(state.sections[.loaded]?.lines.count == 2)
        tools.observeTaskState(nil)
        #expect(try await tools.call("help.read", arguments) == observed)
    }

    @Test func unobservedNestedCallsDoNotEnterTheParentState() async throws {
        let nested = AutomationTools(session: TaskStateSession(), capabilities: [])
        let tools = AutomationTools(session: TaskStateSession(),
            capabilities: [GuideProvider(guide: try guideCapability(), nestedTools: nested)])
        var inputs: [TaskStateInput] = []
        tools.observeTaskState { inputs.append($0) }
        _ = try await tools.call("help.read", .object([:]))
        #expect(inputs.map(\.fact) == [.callFinished(tool: "help.read", subject: nil, outcome: nil)])
    }

    private func guideCapability() throws -> GuideCapability {
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
        let guides = AppGuides(guides: [guide], search: GuideSearch(guides: [guide]), arm: .requested,
            estimateTokens: AutomationRuntime.TokenEstimate.tokens(in:), similarity: { _, _ in 0 })
        return GuideCapability(guides: guides,
            resolve: { _ in OpenedApp(bundleID: "test.state", version: nil, locale: "en") }, todo: { [] })
    }

    @Test func stateFromTheRealDispatcher() async throws {
        var messages: [[TurnMessage]]?
        for arm in ["on", "off"] {
            try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["task_state": arm])) {
                let session = TaskStateSession()
                let tools = AutomationTools(session: session, capabilities: [GuideProvider(guide: try guideCapability())])
                let host = TestTurnHost()
                let runner = TurnRunner(tools: tools, configuration: .init(
                    workingDirectory: URL(filePath: "/fake/task-state"), bridgeExecutable: URL(filePath: "/bin/cat"),
                    allowsSuspension: true, closesSessionOnEnd: false), host: host)
                let arguments = "{\"session\":\"\(session.id!.uuidString)\",\"target\":\"Submit\",\"verb\":\"click\"}"
                let transport = TurnTestTransport([
                    [.toolCall(.init(id: "one", name: "act", arguments: Data(arguments.utf8)))],
                    [.toolCall(.init(id: "two", name: "act", arguments: Data(arguments.replacingOccurrences(
                        of: "Submit", with: "Disabled").utf8)))],
                    [.toolCall(.init(id: "three", name: "help.read", arguments: Data(
                        "{\"app\":\"test.state\",\"sections\":[\"Submit\"]}".utf8)))],
                    [.delta("ok")]
                ])
                _ = try await runner.run(.init(prompt: "Submit", route: .modelLoop(transport: transport,
                    contextWindow: nil))) { _ in }
                if arm == "on" {
                    #expect(runner.currentTaskState?.sections[.facts]?.provenance == [1])
                    #expect(runner.currentTaskState?.sections[.failedAttempts]?.provenance == [2])
                    #expect(runner.currentTaskState?.sections[.loaded]?.lines.count == 2)
                    #expect(runner.currentTaskState?.rendered().contains("private read value") == false)
                    let text = try #require(runner.currentTaskState?.rendered())
                    print("TaskState dispatched: \(text.utf8.count) bytes, \(AutomationRuntime.TokenEstimate.tokens(in: text)) tokens")
                } else { #expect(runner.currentTaskState == nil) }
                if let messages { #expect(transport.messages == messages) } else { messages = transport.messages }
                try await runner.close()
            }
        }
    }

    @MainActor
    private final class TaskStateSession: AutomationSessionOperating {
        let id: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
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

    private nonisolated struct GuideProvider: CapabilityProviding {
        let family = "help"
        let guide: GuideCapability
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
                let sessionID = try await MainActor.run { try #require(nestedTools.session.id) }
                return try await nestedTools.call("act", .object([
                    "session": .string(sessionID.uuidString),
                    "target": .string("Submit"), "verb": .string("click")]))
            }
            return try await guide.call(.init(rawValue: "read_guide"), arguments: arguments, context: context)
        }
    }
}
