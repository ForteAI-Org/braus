import AutomationMCP
import ChatCore
import CLIProviders
import Foundation
import Testing
@testable import Turn

@MainActor
@Suite("TurnTests byte replay")
struct TurnReplayTests {
    @Test func originalProviderArgumentsAndInputRemainByteIdentical() throws {
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let host = TestTurnHost()
        let runner = TurnRunner(
            tools: AutomationTools(session: TurnTestSession()),
            configuration: .init(workingDirectory: URL(filePath: "/fake/work"),
                                 bridgeExecutable: URL(filePath: "/fake/bridge"), allowsSuspension: true),
            host: host
        )
        for provider in [ChatProvider.claude, .codex] {
            for index in 0..<3 {
                let role: String? = index == 0 ? nil : "Edit documents."
                var prompt = "Braus seat: no session is open.\n\nHello"
                if index == 1 {
                    prompt = TurnInstructions.changedNotice(TurnInstructions.compose(role: role)) + prompt
                }
                if index == 2 {
                    prompt = "Braus seat: no session is open.\n\n"
                        + TurnInstructions.humanInterventionInstructions + "\n\nHello"
                }
                let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: provider,
                    executable: URL(filePath: "/fake/provider"), model: nil, effort: "medium",
                    environment: [:], allowsWebSearch: false), sessionID: index == 0 ? nil : "s1", role: role)
                let turn = runner.providerTurn(request, prompt: prompt, session: request.sessionID,
                                               connection: URL(filePath: "/fake/connection.json"))
                let invocation = try ProviderInvocation(turn)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let actual = try encoder.encode(["arguments": invocation.arguments,
                                                "standardInput": [invocation.standardInput]])
                let expected = try Data(contentsOf: fixtures.appending(path:
                    "replay-\(provider.rawValue)-\(index + 1).json"))
                #expect(actual == expected)
            }
        }
    }
}
