import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Testing

@MainActor
struct ObservePreDispatchTests {
    @Test func missingSessionNeverReadsAndReportsKnownPreDispatchFailure() async throws {
        let session = ToolResultSession()
        session.id = nil
        let tools = AutomationTools(session: session)
        do {
            _ = try await tools.call("observe", .object([:]))
            Issue.record("Expected a missing-session refusal")
        } catch let failure as AutomationFailure {
            #expect(failure.cause == "no_session" && failure.isBeforeDispatch)
        }
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("observe"), "arguments": .object([:])])])
        let result = try #require(await router.handle(request))["result"]
        #expect(result["isError"].bool == true)
        let text = try #require(result["content"].array?.first?["text"].string)
        let failure = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(failure["dispatch"].string == "not_dispatched")
        #expect(!text.contains("Effects may be partial"))
        #expect(session.calls.isEmpty && session.id == nil)
    }

    @Test func openedSessionFailureKeepsUnknownDispatchGuidance() async throws {
        let session = ToolResultSession()
        session.observationFailure = AutomationFailure("Synthetic read failed after dispatch")
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("observe"), "arguments": .object([:])])])
        let result = try #require(await router.handle(request))["result"]
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(result["isError"].bool == true && text.contains("Effects may be partial"))
        #expect(session.calls == ["observe"])
    }
}
