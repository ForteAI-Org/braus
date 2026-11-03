import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import Switches
import Testing
@testable import Turn

@MainActor
struct TurnRunnerToolLoadingTests {
    @Test func runnerPassesTheSwitchToChild() async throws {
        let root = try testTurnRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let script = root.appending(path: "provider.sh")
        let output = root.appending(path: "arguments.txt")
        try Data(#"""
        #!/bin/sh
        /bin/cat >/dev/null
        /usr/bin/python3 -c 'import json,os,sys; json.dump(sys.argv[1:],open(os.environ["PROVIDER_ARGUMENTS_FILE"],"w"))' "$@"
        /usr/bin/printf '%s\n' '{"type":"result","is_error":false,"result":"ok"}'
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_loading": "harnessSearch"])) {
            let runner = TurnRunner(tools: AutomationTools(session: TurnTestSession()),
                configuration: .init(workingDirectory: root, bridgeExecutable: URL(filePath: "/fake/bridge"),
                    allowsSuspension: true), host: TestTurnHost())
            let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: .claude,
                executable: script, model: nil, effort: nil,
                environment: ["PROVIDER_ARGUMENTS_FILE": output.path], allowsWebSearch: false))
            let turn = runner.providerTurn(request, prompt: "Hello", session: nil,
                connection: root.appending(path: "connection.json"))
            try await CLIProvider().run(turn, executable: script) { _ in }
            let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
            let expected = try ProviderInvocation(turn).arguments
            #expect(arguments == expected)
        }
    }

    @Test func runnerPassesTheSwitch() throws {
        for arm in ["upfront", "harnessSearch"] {
            try SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_loading": arm])) {
                let runner = TurnRunner(tools: AutomationTools(session: TurnTestSession()),
                    configuration: .init(workingDirectory: URL(filePath: "/fake/work"),
                        bridgeExecutable: URL(filePath: "/fake/bridge"), allowsSuspension: true), host: TestTurnHost())
                let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: .claude,
                    executable: URL(filePath: "/fake/provider"), model: nil, effort: nil,
                    environment: [:], allowsWebSearch: false))
                let turn = runner.providerTurn(request, prompt: "Hello", session: nil,
                    connection: URL(filePath: "/fake/connection"))
                #expect(turn.toolLoading.rawValue == arm)
                let args = try ProviderInvocation(turn).arguments
                #expect(args[try #require(args.firstIndex(of: "--tools")) + 1]
                    == (arm == "upfront" ? "" : "ToolSearch"))
            }
        }
    }
}

extension TurnRunnerToolLoadingTests {
    @Test func runnerUsesProfileLoadingOverride() throws {
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["tool_loading": "upfront"])) {
            let profile = SessionProfile(attendance: .none, level: .act, memory: .off,
                catalogue: .open, takeover: false,
                options: .init(switches: ["tool_loading": "harnessSearch"]), name: "test")
            let runner = TurnRunner(tools: AutomationTools(session: TurnTestSession(), profile: profile),
                configuration: .init(workingDirectory: URL(filePath: "/fake/work"),
                    bridgeExecutable: URL(filePath: "/fake/bridge"), allowsSuspension: true), host: TestTurnHost())
            let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: .claude,
                executable: URL(filePath: "/fake/provider"), model: nil, effort: nil,
                environment: [:], allowsWebSearch: false))
            #expect(runner.providerTurn(request, prompt: "Hello", session: nil,
                connection: URL(filePath: "/fake/connection")).toolLoading == .harnessSearch)
        }
    }
}
