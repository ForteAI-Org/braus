import AutomationMCP
import LocalMCP
import Testing

@Suite
@MainActor
struct FindThroughDispatcherTests {
    @Test func facadeExposesFindAfterCatalogueComposition() async throws {
        do {
            let tools = AutomationTools(session: DemoSession())
            let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
            let arguments: JSONValue = .object(["query": .string("scroll down the list")])
            let direct = try await tools.call("find", arguments)
            let bridged = try #require(await router.handle(.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string("find"), "arguments": arguments])
            ])))
            #expect(bridged["result"] == direct)
            let found = try decodedCapabilityResult(direct)["capabilities"].array ?? []
            #expect(found.prefix(3).contains { $0["name"].string == "scroll" })
            #expect(found.allSatisfy { $0["inputSchema"]["additionalProperties"] == .bool(false) })
        }
    }
}
