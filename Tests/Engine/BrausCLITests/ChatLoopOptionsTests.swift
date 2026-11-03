import Foundation
import ModelTransports
import Testing
@testable import braus

@Suite struct ChatLoopOptionsTests {
    @Test func loopAndScriptOptions() throws {
        let options = try ChatOptions(arguments: ["--model-provider", "anthropic", "--model", "test-model",
            "--provider-key-service", "test.service", "--script", "requests.txt", "--pause-between-requests",
            "--anthropic-host", "http://127.0.0.1:8123"])
        #expect(options.modelProvider?.rawValue == "anthropic")
        #expect(options.pauseBetweenRequests)
        #expect(options.anthropicHost == "http://127.0.0.1:8123")
        #expect(try ChatOptions(arguments: []).modelProvider == nil)
        #expect(try ChatOptions(arguments: []).pauseBetweenRequests == false)
    }

    @Test(arguments: [[], ["--provider", "claude"], ["--model-provider", "gemini"],
                      ["--model-provider", "ollama"]])
    func anthropicHostRequiresAnthropicProvider(_ arguments: [String]) {
        do {
            _ = try ChatOptions(arguments: arguments + ["--anthropic-host", "https://api.anthropic.com"])
            Issue.record("Expected Anthropic provider validation")
        } catch {
            #expect(error.localizedDescription == "--anthropic-host requires --model-provider anthropic.")
        }
    }

    @Test(arguments: [
        ["--pause-between-requests"], ["--model-provider", "codex"],
        ["--model-provider", "anthropic", "--provider", "claude"],
        ["--model-provider", "anthropic", "--pass-env", "SECRET"]
    ]) func invalidOptions(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try ChatOptions(arguments: arguments) }
    }
}
