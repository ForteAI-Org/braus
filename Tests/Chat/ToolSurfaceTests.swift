@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Switches
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

    @Test func legacyMeasurements() throws {
        for channels: AutomationChannels in [[], [.native, .web, .adapters]] {
            for surface in [ToolSurface.v1, .v2] {
                let definitions = ToolCatalogue.definitions(for: channels, surface: surface)
                    .filter { $0["name"].string != "human_step" }
                let bytes = try ToolCatalogue.fixedPartBytes(
                    instructions: AutomationTools.instructions(for: channels), definitions: definitions)
                print("TU4_FIXED prompt=v1 tool_surface=\(surface.rawValue) channels=\(channels) bytes=\(bytes)")
            }
        }
        print("Integrated prompt=v2 fixed-part budget is checked in TurnTests.FixedPartBudgetTests")
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
        let tools = ToolCatalogue.definitions(for: [.native, .web, .adapters], surface: .v2)
            .filter { names.contains($0["name"].string ?? "") }
        let bytes = try ToolCatalogue.fixedPartBytes(instructions: "", definitions: tools)
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/core-size-approved.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let approved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
            #expect(approved["bytes"] != .null)
            print("Integrated prompt=v2 core comparison is checked in TurnTests.FixedPartBudgetTests; tools-only bytes=\(bytes)")
        } else {
            print("WARNING core baseline unapproved; tools-only bytes=\(bytes) names=\(tools.compactMap { $0["name"].string }) prompt=v2 measured in TurnTests.FixedPartBudgetTests tool_surface=v2 outcome=v1")
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
struct MemoryTaskRulesPlacementTests {
    @Test func fourArmsPreserveRulesAndNames() throws {
        let legacy = AutomationTools.definitions(for: [.native, .web, .adapters])
        for prompt in ["v1", "v2"] {
            for surface in ["v1", "v2"] {
                SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": surface, "prompt": prompt])) {
                    let definitions = AutomationTools.definitions(for: [.native, .web, .adapters])
                    #expect(definitions.map { $0["name"] } == legacy.map { $0["name"] })
                    if surface == "v1" { #expect(definitions == legacy) }
                    let description = definitions.first { $0["name"].string == "memory_task" }?["description"].string ?? ""
                    if surface == "v2" {
                        #expect(description.contains("Before acting") == (prompt == "v1"))
                        #expect(description.contains("After checking") == (prompt == "v1"))
                    }
                }
            }
        }
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
                    let legacy = try SwitchBoard.$testing.withValue(SwitchBoard(values: [:])) {
                        try #require(ResultFormatter.evidence(check, kind: .actedUnverified))
                    }
                    try SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": "v2", "outcome": "v1"])) {
                        let value = try #require(ResultFormatter.evidence(check, kind: .actedUnverified))
                        #expect(value["goal"] == .null)
                        #expect(value["effect"]["version"] == .null)
                        for key in ["condition", "method", "verdict"] {
                            #expect(value["effect"][key] == legacy["effect"][key])
                            #expect(value["effect"][key] != .null)
                        }
                        #expect(value["command"] == legacy["command"])
                        #expect(value["effect"]["limits"] == (limits.isEmpty ? .null : legacy["effect"]["limits"]))
                    }
                }
            }
        }
    }
}

@MainActor
struct ToolSurfaceAnswerTests {
    @Test func jsonWithoutSceneKeepsToolResult() throws {
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": "v2"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            let value: JSONValue = .object(["applications": .array([])])
            let result = try formatter.finish("apps", value, notice: nil, output: CallOutput())
            #expect(result == MCPRouter.toolResult(value))
        }
    }

    @Test(arguments: ["v1", "v2"])
    func curatedTextAndValueAreMinimized(_ surface: String) throws {
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": surface])) {
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
    }

    @Test func invalidNumberCannotHaveAFixedPartSize() {
        #expect(throws: (any Error).self) {
            try ToolCatalogue.fixedPartBytes(instructions: "", definitions: [.number(.infinity)])
        }
    }
}

@MainActor
struct ToolSurfaceRegisteredSessionTests {
    @Test(arguments: ["v1", "v2"])
    func missingSessionUsesTheSelectedRefusal(_ surface: String) async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": surface])) {
            let session = ToolResultSession()
            session.id = nil
            let tools = AutomationTools(session: session, capabilities: [SessionCapability()])
            do {
                _ = try await tools.call("synthetic.read", .object([:]))
                Issue.record("A capability without a session was accepted")
            } catch {
                let expected = surface == "v2" ? CallDispatcher.noSession.description : ModelText.text(.init(rawValue: "call_dispatcher.id.v1"))
                #expect(String(describing: error) == expected)
                #expect((error as? AutomationFailure)?.cause == "no_session")
            }
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
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v1"])) {
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
}

@MainActor
struct ToolSurfaceSnapshotTests {
    @Test(arguments: [ToolSurface.v1, .v2])
    func capturedSurfaceSurvivesArmChange(_ initial: ToolSurface) async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": initial.rawValue])) {
            let surface = ToolCatalogue.currentSurface
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            let taskCycle = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
            let dispatcher = CallDispatcher(
                session: session, channels: [], adapters: nil, router: nil,
                secrets: secrets, sceneText: sceneText, taskCycle: taskCycle, formatter: formatter,
                capabilities: [], recording: nil
            )
            defer { withExtendedLifetime((secrets, sceneText, formatter, taskCycle)) {} }
            let arguments: JSONValue = .object(["session": .string(try #require(session.id).uuidString)])
            let changed = initial == .v1 ? "v2" : "v1"
            try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_surface": changed])) {
                let result = try await dispatcher.call("observe", arguments, surface: surface)
                let text = try #require(result["content"].array?.first?["text"].string)
                if initial == .v2 {
                    #expect(text.contains("<scene>"))
                    #expect(result["structuredContent"] != .null)
                } else {
                    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                    #expect(decoded["scene"] != .null)
                    #expect(result["structuredContent"] == .null)
                }
                let check = OperationCheck(condition: .none, method: .none, verdict: .unknown, performed: .none)
                let evidence = try #require(ResultFormatter.evidence(check, kind: .actedUnverified, surface: surface))
                #expect((evidence["goal"] == .null) == (initial == .v2))
            }
        }
    }
}
