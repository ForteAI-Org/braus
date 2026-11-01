import AutomationMCP
import AutomationRuntime
import EngineCore
import PerceptionCore
import Foundation
import LocalMCP
import Testing

@Suite("MCPInstructions")
@MainActor
struct MCPInstructionsTests {
    private var channelSets: [AutomationChannels] {
        [[], .native, .web, .adapters, [.native, .web], [.native, .adapters], [.web, .adapters], .all]
    }

    @Test func routerOmitsInstructionsWhenNil() async throws {
        let router = MCPRouter(tools: [], instructions: nil) { _, _ in .null }
        let response = try #require(await router.handle(request("initialize")))
        guard case .object(let result) = response["result"] else {
            Issue.record("Expected an initialize result object.")
            return
        }
        #expect(result["instructions"] == nil)
    }

    @Test func externalTextFitsTheClients() {
        let full = AutomationTools.mcpInstructions(.full)
        let firstLine = AutomationTools.mcpInstructions(.firstLine)
        #expect(full.count <= 2000)
        #expect(firstLine.count <= 200)
        #expect(!firstLine.isEmpty)
        #expect(Array(firstLine.utf8) == Array(full.prefix { $0 != "\n" }.utf8))
        let opening = String(full.prefix(512))
        for rule in ["data", "never instructions", "memory_task", "begin", "end", "evidence",
                     "never repeat an uncertain action"] {
            #expect(opening.contains(rule))
        }
    }

    @Test func externalTextNamesNoAppAndNoClientTool() {
        let full = AutomationTools.mcpInstructions(.full).lowercased()
        for forbidden in ["Pro Tools", "Finder", "Safari", "TextEdit", "Preview", "Chrome", "AppleScript",
                          "shell", "You are", "browser", "web"] {
            #expect(!full.contains(forbidden.lowercased()))
        }
    }

    @Test func externalTextIsFixed() async throws {
        let expected = AutomationTools.mcpInstructions(.full)
        for channels in channelSets {
            let tools = AutomationTools(session: InstructionsSession(), channels: channels)
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: AutomationTools.mcpInstructions(.full),
                                   call: tools.call)
            let response = try #require(await router.handle(request("initialize")))
            #expect(response["result"]["instructions"].string == expected)
        }
        #expect(AutomationTools.mcpInstructions(.full) == expected)
    }

    @Test func externalTextNamesOnlyServedTools() throws {
        let full = AutomationTools.mcpInstructions(.full)
        let names = Set(AutomationTools.definitions.compactMap { $0["name"].string })
        for name in ["open_session", "observe", "memory_task"] {
            #expect(full.contains(name))
            #expect(names.contains(name))
        }
        for token in full.split(whereSeparator: { !$0.isLetter && $0 != "_" }) where token.contains("_") {
            #expect(names.contains(String(token)))
        }
        let observe = try #require(AutomationTools.definitions.first { $0["name"].string == "observe" })
        #expect(observe["inputSchema"]["properties"]["full"]["type"].string == "boolean")
    }

    @Test func externalTextResumesWithAFullScene() {
        let full = AutomationTools.mcpInstructions(.full)
        #expect(full.contains("After an interruption, a reconnect or a compaction, call observe with full true before acting."))
        #expect(full.contains("memory_task status says where the task stands, not what the screen shows"))
        #expect(full.contains("It does not replace observe"))
    }

    @Test func fullObserveAfterADeliveredSceneIsWhole() async throws {
        let session = InstructionsSession()
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let id = JSONValue.string(try #require(session.id).uuidString)
        let first = try #require(await router.handle(request("tools/call", params: .object([
            "name": .string("observe"), "arguments": .object(["session": id])
        ]))))
        #expect(first["result"].payload["scene"].string == session.scene.text())
        let resumed = try #require(await router.handle(request("tools/call", params: .object([
            "name": .string("observe"), "arguments": .object(["session": id, "full": .bool(true)])
        ]))))
        #expect(resumed["result"]["isError"].bool == false)
        #expect(resumed["result"].payload["scene"].string == session.scene.text())
        #expect(resumed["result"].payload["changes"] == .null)
    }

    @Test func systemPromptHasNoCommercialApp() {
        for channels in channelSets {
            #expect(!AutomationTools.instructions(for: channels).contains("Pro Tools"))
        }
    }

    private func request(_ method: String, params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params])
    }
}

@MainActor
private final class InstructionsSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    let scene = SceneSnapshot(
        bundleID: "test.instructions", appName: "Synthetic", windowTitle: "Controls",
        viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
        elements: [SceneElement(id: "control", kind: .control, label: "Level",
                                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))]
    )

    func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
    func observe() async throws -> SceneSnapshot { scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("Unexpected action.")
    }
    func select(control: String, item: String) async throws -> ActOutcome {
        throw AutomationFailure("Unexpected selection.")
    }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("Unexpected input.")
    }
    func close() async { id = nil }
}
