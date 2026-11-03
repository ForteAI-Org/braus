import Foundation
import ChatCore
import AutomationRuntime
import Testing
import ModelTransports
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

extension ChatOptionsTests {
    @Test func profileIsLoadedBeforeLaunching() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"preset":"cli","name":"Juniper","memory":"learn"}"#.utf8).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record(error) }
        }
        #expect(try ChatOptions(arguments: ["--profile", url.path]).sessionProfile.memory == .learn)
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--profile", url.path, "--profile", url.path]) }
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--profile", url.path + ".missing"]) }
        try Data(#"{"preset":"app"}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--profile", url.path]) }
    }
}

extension ChatOptionsTests {
    @Test func effortIsParsedAndValidated() throws {
        for effort in ReasoningEffort.allCases {
            #expect(try ChatOptions(arguments: ["--effort", effort.rawValue]).effort == effort)
        }
        for args in [["--effort", "huge"], ["--effort", "high", "--effort", "low"]] {
            #expect(throws: (any Error).self) { try ChatOptions(arguments: args) }
        }
    }
}

extension ChatOptionsTests {
    @Test func profileEffortAndIdleDurationAreValidated() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { do { try FileManager.default.removeItem(at: file) } catch { Issue.record(error) } }
        try Data(#"{"preset":"cli","options":{"effort":"ultra","seatWarmSeconds":0}}"#.utf8).write(to: file)
        #expect(try ChatOptions(arguments: ["--profile", file.path]).effort == .ultra)
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--profile", file.path, "--effort", "high"]) }
        for options in [#"{"effort":"huge"}"#, #"{"seatWarmSeconds":-1}"#] {
            try Data("{\"preset\":\"cli\",\"options\":\(options)}".utf8).write(to: file)
            #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--profile", file.path]) }
        }
    }
}
