@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Testing

@MainActor
struct PreDispatchFailureTests {
    @Test func semanticArgumentFailuresAreAlsoBeforeDispatch() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        for (name, arguments): (String, JSONValue) in [
            ("act", .object(["target": .string("Public"), "verb": .string("set_toggle")])),
            ("call", .object(["name": .string("drag"), "arguments": .object(["from": .string("Public"),
                "to": .string("Other"), "dx": .number(1), "dy": .number(1)])]))
        ] {
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": arguments])])
            let response = try #require(await router.handle(request))["result"]
            let text = try #require(response["content"].array?.first?["text"].string)
            #expect(response["isError"].bool == true)
            #expect(text.contains("not_dispatched"))
            #expect(!text.contains("Effects may be partial"))
        }
        #expect(session.calls.isEmpty)
    }

    @Test func planSessionAndUnknownRowRefusalsNeverDispatch() async throws {
        for cause in ["plan_required", "no_session", "unknown_step"] {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            if cause == "plan_required" {
                _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
                session.calls.removeAll()
            } else if cause == "no_session" { session.id = nil }
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            var args: [String: JSONValue] = ["target": .string("Must not run")]
            if cause == "unknown_step" { args["step"] = .string("r999") }
            do {
                _ = try await tools.call("act", .object(args))
                Issue.record("Expected a preflight refusal")
            } catch let failure as AutomationFailure {
                #expect(failure.cause == cause && failure.isBeforeDispatch)
            }
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string("act"), "arguments": .object(args)])])
            let result = try #require(await router.handle(request))["result"]
            let text = try #require(result["content"].array?.first?["text"].string)
            #expect(result["isError"].bool == true)
            let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            #expect(payload["dispatch"].string == "not_dispatched")
            #expect(!text.contains("Effects may be partial"))
            #expect(session.calls.isEmpty)
        }
    }

    @Test(arguments: [2, 20]) func invalidFindHasNoEffectsWhileUnknownFailuresKeepCaution(_ limit: Int) async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("tools/call"), "params": .object(["name": .string("find"),
                "arguments": .object(["query": .string("Public capability"), "limit": .number(Double(limit))])])])
        let result = try #require(await router.handle(request))["result"]
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(result["isError"].bool == true)
        #expect(text.contains("not_dispatched"))
        #expect(!text.contains("Effects may be partial"))
        #expect(session.calls.isEmpty)
        let unknown = MCPRouter.failureResult(AutomationFailure("Synthetic interrupted operation"))
        #expect(unknown["content"].array?.first?["text"].string?.contains("Effects may be partial") == true)
    }
}
