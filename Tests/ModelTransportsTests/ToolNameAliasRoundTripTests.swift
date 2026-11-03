import Foundation
import Testing
@testable import ModelTransports

@Suite("Tool aliases round trip at the provider boundary")
struct ToolNameAliasRoundTripTests {
    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Read a value.", parameters: Data("{}".utf8))
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }

    @Test func collisionsRefuseDefinitionsAndHistoryBeforeSending() throws {
        let name = "demo.read"
        let alias = ToolNameAliases.wireName(name)
        #expect(throws: ProviderError.self) {
            try ToolNameAliases(tools: [tool(name), tool(alias)], messages: [])
        }
        let oldCall = ToolCall(id: "old", name: alias, arguments: Data("{}".utf8))
        #expect(throws: ProviderError.self) {
            try ToolNameAliases(tools: [tool(name)], messages: [
                TurnMessage(role: .assistant, text: "", toolCalls: [oldCall]),
            ])
        }
        #expect(throws: ProviderError.self) {
            try AnthropicClient(model: "synthetic", effort: .medium, apiKey: "")
                .requestBody(messages: [], tools: [tool(name), tool(alias)])
        }
    }

    @Test func boundaryNamesAndUnknownCallsKeepTheirIdentity() throws {
        let valid = ["a", "A_0-z", String(repeating: "a", count: 64)]
        for name in valid { #expect(ToolNameAliases.wireName(name) == name) }
        for name in ["", "demo.read", "è", String(repeating: "a", count: 65)] {
            let alias = ToolNameAliases.wireName(name)
            #expect(alias.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
            #expect(alias != name)
        }
        #expect(ToolNameAliases.wireName("demo.é") == ToolNameAliases.wireName("demo.e\u{301}"))
        let names = try ToolNameAliases(tools: [tool("demo.read"), tool("demo_read")], messages: [])
        for name in ["unknown", "tool_unrecognized", "demo_read"] {
            let call = ToolCall(id: "1", name: name, arguments: Data("{}".utf8))
            #expect(names.restoring(call) == call)
        }
    }

    @Test(arguments: [true, false])
    func oldGeminiRecordsKeepTheirResponseNameAndSignature(hasID: Bool) throws {
        var function: [String: Any] = ["name": "demo.read", "args": [:]]
        if hasID { function["id"] = "1" }
        let block = try json(["functionCall": function, "thoughtSignature": "signed"])
        let call = ToolCall(id: hasID ? "1" : "call_0", name: "demo.read", arguments: Data("{}".utf8))
        let record = TurnRecord(provider: .gemini, blocks: [block])
        let messages = [TurnMessage(role: .assistant, text: "", toolCalls: [call], record: record),
                        TurnMessage(result: "{}", of: call, isError: false)]
        let body = try GeminiClient(model: "synthetic", effort: .medium, apiKey: "")
            .requestBody(messages: messages, tools: [tool(call.name)])
        let turns = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(turns[0]["parts"] as? [[String: Any]])
        #expect(try parts.map(json) == [block])
        let results = try #require(turns[1]["parts"] as? [[String: Any]])
        let response = try #require(results.first?["functionResponse"] as? [String: Any])
        #expect(response["name"] as? String == call.name)
        #expect(response["id"] as? String == (hasID ? call.id : nil))
    }

    @Test(arguments: [ModelProvider.anthropic, .gemini, .ollama])
    func streamedCallsRestoreCanonicalIDsAndReplayNativeRecords(provider: ModelProvider) throws {
        let name = "demo.read"
        let alias = ToolNameAliases.wireName(name)
        let names = try ToolNameAliases(tools: [tool(name)], messages: [])
        let input = ["capability": "other.read"]
        let payloads: [[String: Any]]
        let format: EventStreamReader.Format
        let decode: TurnAssembler.PayloadDecoding
        let recording: ModelProvider?
        switch provider {
        case .anthropic:
            payloads = [
                ["type": "content_block_start", "index": 0,
                 "content_block": ["type": "thinking", "thinking": "", "signature": "signed"]],
                ["type": "content_block_start", "index": 1,
                 "content_block": ["type": "tool_use", "id": "1", "name": alias, "input": input]],
                ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
                ["type": "message_stop"],
            ]
            format = .serverSentEvents
            decode = AnthropicClient.decode
            recording = .anthropic
        case .gemini:
            payloads = [["candidates": [["content": ["parts": [
                ["functionCall": ["id": "1", "name": alias, "args": input], "thoughtSignature": "signed"],
            ]], "finishReason": "STOP"]]]]
            format = .serverSentEvents
            decode = GeminiClient.decode
            recording = .gemini
        case .ollama:
            payloads = [["message": ["tool_calls": [["id": "1", "function": ["name": alias, "arguments": input]]]],
                         "done": true, "done_reason": "stop"]]
            format = .newlineDelimitedJSON
            decode = OllamaClient.decode
            recording = nil
        default:
            throw ProviderError.badResponse("unsupported test provider")
        }
        var assembler = TurnAssembler(format: format, decode: decode, recording: recording, toolNames: names)
        for payload in payloads {
            let prefix = provider == .ollama ? "" : "data: "
            let line = prefix + String(decoding: try json(payload), as: UTF8.self) + "\n\n"
            for byte in line.utf8 { _ = try assembler.accept(byte) }
        }
        let call = ToolCall(id: "1", name: name, arguments: try json(input))
        #expect(assembler.takeToolCalls() == [call])
        #expect(assembler.takeToolCalls().isEmpty)
        _ = try assembler.completion(wallClock: .seconds(1))
        guard let record = assembler.record else {
            #expect(provider == .ollama)
            return
        }
        let messages = [TurnMessage(role: .assistant, text: "", toolCalls: [call], record: record),
                        TurnMessage(result: "{}", of: call, isError: false)]
        let blocks: [[String: Any]]
        switch provider {
        case .anthropic:
            let body = try AnthropicClient(model: "synthetic", effort: .medium, apiKey: "")
                .requestBody(messages: messages, tools: [tool(name)])
            let turns = try #require(body["messages"] as? [[String: Any]])
            blocks = try #require(turns.first?["content"] as? [[String: Any]])
            #expect(blocks.first?["signature"] as? String == "signed")
            #expect(blocks.last?["name"] as? String == alias)
        case .gemini:
            let body = try GeminiClient(model: "synthetic", effort: .medium, apiKey: "")
                .requestBody(messages: messages, tools: [tool(name)])
            let turns = try #require(body["contents"] as? [[String: Any]])
            blocks = try #require(turns.first?["parts"] as? [[String: Any]])
            #expect(blocks.first?["thoughtSignature"] as? String == "signed")
            let results = try #require(turns[1]["parts"] as? [[String: Any]])
            #expect((results.first?["functionResponse"] as? [String: Any])?["name"] as? String == alias)
        default:
            throw ProviderError.badResponse("unexpected recorded provider")
        }
        #expect(try blocks.map(json) == record.blocks)
        #expect(messages[0].toolCalls == [call])
        #expect(messages[1].call == call)
    }
}
