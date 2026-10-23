import Foundation
import ChatCore
import Testing
@testable import braus

@Suite("Chat command parsing")
struct ChatOptionsTests {
    @Test
    func promptAndResumeAreKeptLiteral() throws {
        let options = try ChatOptions(arguments: [
            "click \"New Path...\"; $(not a shell)", "--provider", "gpt",
            "--model", "chosen-model", "--resume", "last", "--once"
        ])
        #expect(options.provider?.rawValue == "codex")
        #expect(options.model == "chosen-model")
        #expect(options.resume == "last")
        #expect(options.prompt == "click \"New Path...\"; $(not a shell)")
        #expect(options.once)
    }

    @Test(arguments: [
        ["--provider", "unknown"], ["--model"], ["--once"], ["two", "words"],
        ["--provider", "claude", "--provider", "codex"], ["--unknown"],
        ["--list", "do something"], ["--list", "--resume", "last"],
        ["--script", "tasks.txt"], ["--script", "tasks.txt", "--provider", "claude", "a prompt"],
        ["--script", "tasks.txt", "--provider", "claude", "--once"], ["--script", "tasks.txt", "--provider", "codex", "--resume", "last"],
        ["--continue", "--provider", "claude"], ["--evidence", "out", "--provider", "claude"], ["--script"], ["--preflight"],
    ])
    func invalidArgumentsCannotLaunchAProvider(_ args: [String]) {
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: args) }
    }

    @Test
    func effortIsALevelOrTheProviderDefault() throws {
        #expect(try ChatOptions(arguments: ["--provider", "claude", "--effort", "high", "hi"]).effort == "high")
        #expect(try ChatOptions(arguments: ["--provider", "claude", "--effort", "default", "hi"]).effort == nil)
        #expect(try ChatOptions(arguments: ["--provider", "claude", "hi"]).effort == nil)
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: ["--provider", "claude", "--effort", "extreme", "hi"]) }
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: ["--provider", "claude", "--effort"]) }
    }

    @Test
    func aScriptRunsWithItsProviderEvidenceAndPreflight() throws {
        let options = try ChatOptions(arguments: [
            "--script", "~/tasks.txt", "--provider", "claude", "--model", "haiku", "--evidence", "/tmp/run", "--preflight", "expected.json",
            "--continue", "--knowledge", "/tmp/k",
        ])
        #expect(options.script == "~/tasks.txt" && options.evidence == "/tmp/run" && options.preflight == "expected.json")
        #expect(options.continueOnError && options.provider == .claude && options.model == "haiku" && options.knowledgeDirectory == "/tmp/k")
        #expect(!options.once && options.prompt == nil)
        let preflightOnly = try ChatOptions(arguments: ["--provider", "codex", "--preflight", "expected.json", "--once", "do it"])
        #expect(preflightOnly.preflight == "expected.json" && preflightOnly.once && preflightOnly.prompt == "do it")
    }

    @Test
    func delimiterAllowsPromptThatLooksLikeAnOption() throws {
        let options = try ChatOptions(arguments: ["--provider", "claude", "--", "--remember this"])
        #expect(options.prompt == "--remember this")
    }
}
