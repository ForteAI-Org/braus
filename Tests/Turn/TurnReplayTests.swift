import LocalMCP
import AutomationMCP
import ChatCore
import CLIProviders
import Foundation
import Testing
@testable import Turn

@MainActor
@Suite("TurnTests byte replay")
struct TurnReplayTests {
    @Test func providersReceiveTheCurrentInstructionsAndExplicitPrompt() throws {
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
                var prompt = "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\nHello"
                if index == 1 {
                    prompt = TurnInstructions.changedNotice(testTurnInstructions(role: role)) + prompt
                }
                if index == 2 {
                    prompt = "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\n"
                        + TurnInstructions.humanInterventionInstructions + "\n\nHello"
                }
                let request = TurnRequest(prompt: "Hello", route: .commandLine(provider: provider,
                    executable: URL(filePath: "/fake/provider"), model: nil, effort: "medium",
                    environment: [:], allowsWebSearch: false), sessionID: index == 0 ? nil : "s1", role: role)
                let turn = runner.providerTurn(request, prompt: prompt, session: request.sessionID,
                                               connection: URL(filePath: "/fake/connection.json"))
                let invocation = try ProviderInvocation(turn)
                #expect(invocation.standardInput == prompt)
                #expect(turn.instructions == testTurnInstructions(role: role))
                let flags = provider == .claude ? "--append-system-prompt" : "developer_instructions="
                #expect(invocation.arguments.contains { $0.contains(flags) })
                #expect(turn.sessionID == request.sessionID)

            }
        }
    }
}
