import Foundation
import Testing
@testable import ModelTransports

@Suite struct AnthropicParityTests {
    private let client = AnthropicClient(model: "claude-opus-5", effort: .high, apiKey: "fake-key")
    private func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    @Test func stablePrefixAndMovingHistoryBreakpoint() throws {
        let tool = ToolDefinition(name: "read", description: "Read.", parameters: Data("{}".utf8))
        let messages = [TurnMessage(role: .system, text: "Instructions."), TurnMessage(role: .user, text: "Hello.")]
        let first = try client.requestBody(messages: messages, tools: [tool])
        let second = try client.requestBody(messages: messages + [TurnMessage(role: .assistant, text: "Done.")], tools: [tool])
        #expect(first["cache_control"] == nil)
        #expect(try bytes(first["tools"] as Any) == bytes(second["tools"] as Any))
        #expect(try bytes(first["system"] as Any) == bytes(second["system"] as Any))
        let system = try #require(first["system"] as? [[String: Any]])
        #expect(system.last?["cache_control"] != nil)
        let a = try #require(first["messages"] as? [[String: Any]])
        let b = try #require(second["messages"] as? [[String: Any]])
        var old = try #require(a[0]["content"] as? [[String: Any]])
        #expect(old[0].removeValue(forKey: "cache_control") != nil)
        #expect(try bytes(old) == bytes(b[0]["content"] as Any))
        #expect((b.last?["content"] as? [[String: Any]])?.last?["cache_control"] != nil)
    }

    @Test func countsReachModelUsage() throws {
        var progress = TurnProgress()
        _ = try AnthropicClient.decode(Data(#"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":50},"reasoning_tokens":30}}}"#.utf8), progress: &progress)
        let usage = progress.usage(wallClock: .zero)
        #expect(usage.cacheWriteHourTokens == 50)
        #expect(usage.reasoningTokens == 30)
        #expect(TurnProgress().usage(wallClock: .zero).cacheWriteHourTokens == nil)
        #expect(TurnProgress().usage(wallClock: .zero).reasoningTokens == nil)
    }

    @Test(arguments: [true, false])
    func capabilityAliasesPreserveTheCachePrefix(hasSystem: Bool) throws {
        let tool = ToolDefinition(name: "demo.read", description: "Read.", parameters: Data("{}".utf8))
        let call = ToolCall(id: "one", name: tool.name, arguments: Data("{}".utf8))
        let messages = (hasSystem ? [TurnMessage(role: .system, text: "Instructions.")] : []) + [
            TurnMessage(role: .user, text: "Hello."),
            TurnMessage(role: .assistant, text: "", toolCalls: [call]),
            TurnMessage(result: "Done.", of: call, isError: false),
        ]
        let first = try client.requestBody(messages: messages, tools: [tool])
        let second = try client.requestBody(
            messages: messages + [TurnMessage(role: .user, text: "Continue.")], tools: [tool])
        let definitions = try #require(first["tools"] as? [[String: Any]])
        #expect(definitions[0]["name"] as? String == ToolNameAliases.wireName(tool.name))
        #expect(try bytes(definitions) == bytes(second["tools"] as Any))
        #expect(first["cache_control"] == nil)
        if hasSystem {
            #expect(try bytes(first["system"] as Any) == bytes(second["system"] as Any))
            #expect(definitions[0]["cache_control"] == nil)
        } else {
            #expect(definitions[0]["cache_control"] != nil)
        }
        let old = try #require(first["messages"] as? [[String: Any]])
        let new = try #require(second["messages"] as? [[String: Any]])
        let calls = try #require(old[1]["content"] as? [[String: Any]])
        #expect(calls[0]["name"] as? String == ToolNameAliases.wireName(tool.name))
        for index in old.indices {
            var blocks = try #require(old[index]["content"] as? [[String: Any]])
            for block in blocks.indices { blocks[block].removeValue(forKey: "cache_control") }
            #expect(try bytes(blocks) == bytes(new[index]["content"] as Any))
        }
        #expect((old.last?["content"] as? [[String: Any]])?.last?["cache_control"] != nil)
        #expect((new.last?["content"] as? [[String: Any]])?.last?["cache_control"] != nil)
        #expect(messages[messages.count - 2].toolCalls == [call])
    }

    @Test func olderSettingsKeepTheDefaultHost() throws {
        let encoded = try JSONEncoder().encode(ProviderSettings())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "anthropicHost")
        let old = try JSONDecoder().decode(ProviderSettings.self, from: bytes(object))
        #expect(old == ProviderSettings())
    }

    @Test func theToolPrefixIsMarkedWhenThereIsNoSystem() throws {
        let tool = ToolDefinition(name: "read", description: "Read.", parameters: Data("{}".utf8))
        let body = try client.requestBody(messages: [TurnMessage(role: .user, text: "Hello")], tools: [tool, tool])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["cache_control"] == nil)
        #expect(tools[1]["cache_control"] != nil)
        #expect(body["system"] == nil)
    }

    @Test func redirectsCannotForwardCredentialsToAnotherDestination() throws {
        let url = try #require(URL(string: "https://example.invalid"))
        let task = URLSession.shared.dataTask(with: url)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        AnthropicClient.DestinationPolicy().urlSession(URLSession.shared, task: task,
            willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { request in
            #expect(request == nil)
        }
    }

    @Test func hostsAreRestrictedBeforeSending() throws {
        #expect(try client.endpointURL().absoluteString == "https://api.anthropic.com/v1/messages")
        for host in ["http://localhost:8123", "http://127.0.0.1:8123", "http://[::1]:8123"] {
            let local = AnthropicClient(model: "test", effort: .low, apiKey: "fake", host: host)
            #expect(try local.endpointURL().path == "/v1/messages")
        }
        for host in ["https://example.com", "https://api.anthropic.com.evil.test", "http://localhost.evil.test",
                     "http://user:password@localhost", "http://localhost?redirect=elsewhere"] {
            let remote = AnthropicClient(model: "test", effort: .low, apiKey: "fake", host: host)
            #expect(throws: (any Error).self) { try remote.endpointURL() }
        }
    }
}
