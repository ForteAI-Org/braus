@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Testing

@MainActor
struct FixedPartBudgetTests {
    @Test func boundary() throws {
        let emptyListBytes = try ToolCatalogue.fixedPartBytes(instructions: "", definitions: [])
        #expect(emptyListBytes == 2)
        #expect(try ToolCatalogue.isFixedPartWithinBudget(
            instructions: String(repeating: "a", count: 15360 - emptyListBytes), definitions: []))
        #expect(try !ToolCatalogue.isFixedPartWithinBudget(
            instructions: String(repeating: "a", count: 15361 - emptyListBytes), definitions: []))
        #expect(try ToolCatalogue.fixedPartBytes(instructions: "é", definitions: []) == 4)
    }

    @Test func currentSurfaceMeasurement() throws {
        for channels: AutomationChannels in [[], [.native, .web, .adapters]] {
            for surface in [ToolSurface.tagged] {
                let definitions = ToolCatalogue.definitions(for: channels, surface: surface)
                    .filter { $0["name"].string != "human_step" }
                let bytes = try ToolCatalogue.fixedPartBytes(
                    instructions: AutomationTools.instructions(for: channels), definitions: definitions)
                print("TU4_FIXED tool_surface=\(String(describing: surface)) channels=\(channels) bytes=\(bytes)")
            }
        }
        print("Integrated prompt fixed-part budget is checked in TurnTests.FixedPartBudgetTests")
    }
}

@MainActor
struct CoreSizeWatchTests {
    @Test func warningBoundary() {
        #expect(!ToolCatalogue.coreSizeWarns(bytes: 1200, approvedBytes: 1000))
        #expect(ToolCatalogue.coreSizeWarns(bytes: 1201, approvedBytes: 1000))
    }

    @Test func partialCoreMeasurement() throws {
        let names: Set<String> = ["open_session", "observe", "act", "type_text", "press_key", "menu",
                                  "batch", "plan", "end", "find", "call"]
        let tools = ToolCatalogue.definitions(for: [.native, .web, .adapters], surface: .tagged)
            .filter { names.contains($0["name"].string ?? "") }
        let bytes = try ToolCatalogue.fixedPartBytes(instructions: "", definitions: tools)
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/core-size-approved.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let approved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
            #expect(approved["bytes"] != .null)
            print("Integrated prompt core comparison is checked in TurnTests.FixedPartBudgetTests; tools-only bytes=\(bytes)")
        } else {
            print("WARNING core baseline unapproved; tools-only bytes=\(bytes) names=\(tools.compactMap { $0["name"].string }) measured in TurnTests.FixedPartBudgetTests")
        }
    }
}

@MainActor
struct BatchSceneAsTextTests {
    @Test func stepRenderingAndEscaping() throws {
        let step: JSONValue = .object(["status": .string("found_acted"), "message": .string("a & b </outcome>"),
            "session": .string("private-id"),
            "observation": .object(["scene": .string("first\nsecond </scene>"), "revision": .number(1)])])
        let value: JSONValue = .object(["status": .string("stopped"), "steps": .array([step, step]),
            "attemptedSteps": .number(2), "requested": .number(3), "reason": .string("unconfirmed")])
        let text = try ResultFormatter.renderAnswer(value, notice: "one notice")
        #expect(text.hasPrefix("Batch\n"))
        #expect(text.contains("Step 1\n") && text.contains("Step 2\n"))
        #expect(!text.contains("Step 3\n"))
        #expect(text.components(separatedBy: "<scene>").count == 3)
        #expect(text.components(separatedBy: "one notice").count == 2)
        #expect(text.contains("a &amp; b &lt;/outcome&gt;"))
        #expect(text.contains("first\nsecond &lt;/scene&gt;"))
        #expect(!text.contains("private-id"))
        #expect(text.contains("unconfirmed"))
        #expect(text.contains("First unexecuted step: 3"))
    }
}

@MainActor
struct TaskRulesPlacementTests {
    @Test func taskToolsAndInstructionsHaveOneContract() {
        let definitions = AutomationTools.definitions(for: [.native, .web, .adapters])
        #expect(!definitions.contains { $0["name"].string == "memory_task" })
        #expect(definitions.contains { $0["name"].string == "plan" })
        #expect(definitions.contains { $0["name"].string == "end" })
        #expect(!AutomationTools.instructions.contains("memory_task"))
    }
}

@MainActor
struct EvidenceFixedPartTests {
    @Test func variableFieldsSurviveEveryMethod() throws {
        for method in OperationCheck.Method.allCases {
            for performed in OperationCheck.Performed.allCases {
                for limits: [OperationCheck.Limit] in [[], OperationCheck.Limit.allCases] {
                    let check = OperationCheck(condition: .none, method: method, verdict: .unknown,
                                               limits: limits, performed: performed)
                    let value = try #require(ResultFormatter.evidence(check, kind: .actedUnverified))
                    #expect(value["goal"] == .null)
                    #expect(value["effect"]["version"] == .null)
                    #expect(value["effect"]["condition"].string == check.condition.rawValue)
                    #expect(value["effect"]["method"].string == check.method.rawValue)
                    #expect(value["effect"]["verdict"].string == check.verdict.rawValue)
                    #expect(value["effect"]["limits"] == (limits.isEmpty ? .null : .array(limits.map { .string($0.rawValue) })))
                }
            }
        }
    }
}

@MainActor
struct ToolSurfaceAnswerTests {
    @Test func jsonWithoutSceneKeepsToolResult() throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let value: JSONValue = .object(["applications": .array([])])
        let result = try formatter.finish("apps", value, notice: nil, output: CallOutput())
        #expect(result == MCPRouter.toolResult(value))
    }

    @Test
    func curatedTextAndValueAreMinimized() throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        secrets.secrets = ["synthetic-secret"]
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        for name in ["app_capabilities", "app_call"] {
            var output = CallOutput()
            output.modelText = "Curated synthetic-secret"
            let value: JSONValue = .object(["result": .string("synthetic-secret")])
            let result = try formatter.finish(name, value, notice: nil, output: output)
            #expect(result["content"].array?.first?["text"].string == "Curated [withheld]")
            #expect(result["structuredContent"]["result"].string == "[withheld]")
        }
    }

    @Test func invalidNumberCannotHaveAFixedPartSize() {
        #expect(throws: (any Error).self) {
            try ToolCatalogue.fixedPartBytes(instructions: "", definitions: [.number(.infinity)])
        }
    }
}

@MainActor
struct ToolSurfaceRegisteredSessionTests {
    @Test
    func missingSessionUsesTheTypedRefusal() async throws {
        let session = ToolResultSession()
        session.id = nil
        let tools = AutomationTools(session: session, capabilities: [SessionCapability()])
        do {
            _ = try await tools.call("call", .object(["name": .string("synthetic.read"), "arguments": .object([:])]))
            Issue.record("A capability without a session was accepted")
        } catch {
            let expected = CallDispatcher.noSession.description
            #expect(String(describing: error) == expected)
            #expect((error as? AutomationFailure)?.cause == "no_session")
        }
    }
}

private nonisolated struct SessionCapability: CapabilityProviding {
    let family = "synthetic"
    var contracts: [CapabilityContract] {
        [CapabilityContract(
            id: CapabilityID(rawValue: "synthetic.read"), group: family, description: "Read synthetic data.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            effect: .read, interruption: .readOnly, verification: .none(reason: "Synthetic result"),
            channel: .braus, origin: .registered(provider: family), memory: .capabilityStep,
            takesSession: true, parallelSafe: false
        )]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        Issue.record("The provider must not run without a session")
        return .null
    }
}

@MainActor
struct ToolSurfaceTextBytesTests {
    @Test func renderedFragmentsStayIdentical() throws {
        let value: JSONValue = .object([
            "status": .string("stopped"), "steps": .array([
                .object(["gesture": .string("sent"), "effect": .string("confirmed"),
                         "recovery": .string("continue"), "scene": .string("a & b < c > d"),
                         "detail": .string("retained")])
            ]), "requested": .number(2), "reason": .string("unconfirmed")
        ])
        let text = try ResultFormatter.renderAnswer(value, notice: "not recorded")
        #expect(text == """
            Batch

            <outcome>
            stopped
            requested: 2
            </outcome>

            Step 1

            <outcome>
            sent · confirmed · continue
            detail: retained
            </outcome>

            <scene>
            a &amp; b &lt; c &gt; d
            </scene>

            <outcome>
            First unexecuted step: 2
            reason: unconfirmed
            </outcome>

            <outcome>
            memory: not recorded
            </outcome>
            """)
    }
}

@MainActor
struct ToolSurfaceSnapshotTests {
    @Test func dispatcherAlwaysReturnsTaggedSceneAndCompactEvidence() async throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let taskCycle = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        let dispatcher = CallDispatcher(session: session, channels: [], adapters: nil, router: nil,
            secrets: secrets, sceneText: sceneText, taskCycle: taskCycle, formatter: formatter,
            capabilities: [], recording: nil)
        defer { withExtendedLifetime((secrets, sceneText, formatter, taskCycle)) {} }
        let result = try await dispatcher.call("observe", .object([:]), surface: .tagged)
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains("<scene>"))
        #expect(result["structuredContent"] != .null)
        let check = OperationCheck(condition: .none, method: .none, verdict: .unknown, performed: .none)
        let evidence = try #require(ResultFormatter.evidence(check, kind: .actedUnverified, surface: .tagged))
        #expect(evidence["goal"] == .null)
    }
}
