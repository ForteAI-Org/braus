import Foundation
import LocalMCP
import Testing

@MainActor
@Suite("Stable server bytes across turns")
struct StableServerFacingBytesTests {
    @Test(arguments: ["initialize", "tools/list"])
    func pauseAndResumeKeepEveryByte(_ method: String) async throws {
        let router = MCPRouter(
            tools: [CanonicalJSONTests.value(rotation: 7)], instructions: "Fixed instructions."
        ) { _, _ in .null }
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method)
        ])
        let before = try #require(await router.handle(request))
        router.pause()
        await router.drain()
        router.resume()
        let after = try #require(await router.handle(request))
        let encoder = JSONValue.canonicalEncoder()
        #expect(try encoder.encode(before) == encoder.encode(after))
        if method == "initialize" {
            #expect(before["result"]["instructions"].string == "Fixed instructions.")
        }
    }
}
