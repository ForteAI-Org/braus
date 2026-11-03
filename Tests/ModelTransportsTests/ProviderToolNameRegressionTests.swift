import Foundation
import Testing
@testable import ModelTransports

@Suite("Provider tool names preserve capability identity")
struct ProviderToolNameRegressionTests {
    private let schema = Data(#"{"type":"object","properties":{}}"#.utf8)

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Read a value.", parameters: schema)
    }

    private func body(_ provider: ModelProvider, names: [String], messages: [TurnMessage] = []) throws
        -> [String: Any] {
        let tools = names.map(tool)
        switch provider {
        case .anthropic:
            return try AnthropicClient(model: "synthetic", effort: .medium, apiKey: "")
                .requestBody(messages: messages, tools: tools)
        case .gemini:
            return try GeminiClient(model: "synthetic", effort: .medium, apiKey: "")
                .requestBody(messages: messages, tools: tools)
        case .ollama:
            return try OllamaClient(model: "synthetic", effort: .medium, settings: ProviderSettings())
                .requestBody(messages: messages, tools: tools, stream: true, show: [:])
        default:
            throw ProviderError.badResponse("unsupported test provider")
        }
    }

    private func declaredNames(_ provider: ModelProvider, in body: [String: Any]) throws -> [String] {
        let tools = try #require(body["tools"] as? [[String: Any]])
        switch provider {
        case .anthropic: return tools.compactMap { $0["name"] as? String }
        case .gemini:
            return try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
                .compactMap { $0["name"] as? String }
        case .ollama:
            return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        default: return []
        }
    }

    @Test(arguments: [ModelProvider.anthropic, .gemini, .ollama])
    func declarationsAreValidStableAndDistinct(provider: ModelProvider) throws {
        let names = ["demo.read", "demo_read", "demo-read", "act", "other.read",
                     "demo.leggi_è", String(repeating: "a", count: 65)]
        let original = try body(provider, names: names)
        let aliases = try declaredNames(provider, in: original)
        #expect(aliases.count == names.count)
        #expect(Set(aliases).count == names.count)
        for alias in aliases {
            #expect(alias.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        }
        #expect(Array(aliases[1...3]) == Array(names[1...3]))
        #expect(aliases.first != names.first)
        #expect(try declaredNames(provider, in: body(provider, names: names.reversed())) == aliases.reversed())
        #expect(try declaredNames(provider, in: body(provider, names: [names[0]])) == [aliases[0]])
    }

    @Test(arguments: [ModelProvider.anthropic, .gemini, .ollama])
    func historyUsesTheSameAliasWithoutChangingInternalCalls(provider: ModelProvider) throws {
        let call = ToolCall(id: "call_1", name: "demo.read", arguments: Data("{}".utf8))
        let messages = [TurnMessage(role: .assistant, text: "", toolCalls: [call]),
                        TurnMessage(result: "{}", of: call, isError: false)]
        let request = try body(provider, names: [call.name], messages: messages)
        let alias = try #require(declaredNames(provider, in: request).first)
        #expect(alias != call.name)
        switch provider {
        case .anthropic:
            let turns = try #require(request["messages"] as? [[String: Any]])
            let blocks = try #require(turns.first?["content"] as? [[String: Any]])
            #expect(blocks.first?["name"] as? String == alias)
        case .gemini:
            let turns = try #require(request["contents"] as? [[String: Any]])
            let calls = try #require(turns[0]["parts"] as? [[String: Any]])
            let results = try #require(turns[1]["parts"] as? [[String: Any]])
            #expect((calls.first?["functionCall"] as? [String: Any])?["name"] as? String == alias)
            #expect((results.first?["functionResponse"] as? [String: Any])?["name"] as? String == alias)
        case .ollama:
            let turns = try #require(request["messages"] as? [[String: Any]])
            let calls = try #require(turns[0]["tool_calls"] as? [[String: Any]])
            #expect((calls.first?["function"] as? [String: Any])?["name"] as? String == alias)
            #expect(turns[1]["tool_name"] as? String == alias)
        default: break
        }
        #expect(messages[0].toolCalls == [call])
        #expect(messages[1].call == call)
        let noLongerServed = try body(provider, names: ["act"], messages: messages)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: noLongerServed), as: UTF8.self)
        #expect(!encoded.contains("demo.read"))
        #expect(encoded.contains(alias))
    }
}
