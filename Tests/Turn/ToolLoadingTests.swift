import LocalMCP
import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import Testing
@testable import Turn

@MainActor
struct TurnRunnerToolLoadingTests {
    @Test func runnerPassesTheCanonicalInvocationToChild() async throws {
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

    @Test func runnerRetainsTheSameCoreForBothProviderChildren() throws {
        let tools = AutomationTools(session: TurnTestSession())
        let names = tools.toolDefinitions.compactMap { $0["name"].string }
        #expect(names.count == 11 && Array(names.suffix(2)) == ["find", "call"])
        for provider: ChatProvider in [.claude, .codex] {
            let runner = TurnRunner(tools: tools,
                configuration: .init(workingDirectory: URL(filePath: "/fake/work"),
                    bridgeExecutable: URL(filePath: "/fake/bridge"), allowsSuspension: true), host: TestTurnHost())
            let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: provider,
                executable: URL(filePath: "/fake/provider"), model: nil, effort: nil,
                environment: [:], allowsWebSearch: false))
            let turn = runner.providerTurn(request, prompt: "Hello", session: nil,
                connection: URL(filePath: "/fake/connection"))
            let args = try ProviderInvocation(turn).arguments
            #expect(!args.contains { $0.contains("ToolSearch") || $0.contains("alwaysLoad") })
            #expect(tools.toolDefinitions.compactMap { $0["name"].string } == names)
        }
    }

}


extension TurnRunnerToolLoadingTests {
    @Test func observeProfileKeepsReadingAndDiscoveryOnly() throws {
        let profile = SessionProfile(attendance: .none, level: .observe, memory: .off,
            catalogue: .open, takeover: false, options: .init(), name: "test")
        let tools = AutomationTools(session: TurnTestSession(), profile: profile)
        #expect(tools.toolList.level == .observe)
        #expect(!tools.toolDefinitions.contains { $0["name"].string == "act" })
        #expect(tools.toolDefinitions.compactMap { $0["name"].string } == ["open_session", "observe", "find", "call"])
        #expect(tools.configurationEvidence["tool_loading"].string == "upfront")
    }
}
