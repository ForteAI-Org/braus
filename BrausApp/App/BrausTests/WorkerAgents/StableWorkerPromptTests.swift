import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Braus

@MainActor
@Suite("Stable worker instructions")
struct StableWorkerPromptTests {
    @Test(arguments: [ChatProvider.claude, .codex])
    func unchangedRoleAndOptionsKeepInstructionsAcrossTurns(_ provider: ChatProvider) {
        let selection = ModelSelection(
            provider: provider == .claude ? .claudeCode : .codex, model: "", effort: .high
        )
        func turn(session: String?, prompt: String, connection: String) -> ProviderTurn {
            WorkerAgentHost.turn(
                prompt: prompt, provider: provider, selection: selection, sessionID: session, role: "Edit documents.",
                bridgeExecutable: URL(filePath: "/fake/bridge"), connectionFile: URL(filePath: connection),
                workingDirectory: URL(filePath: "/tmp"), inheritedEnvironment: [:]
            )
        }
        let first = turn(session: nil, prompt: "First request", connection: "/tmp/connection-one.json")
        let second = turn(session: "s1", prompt: "Second request", connection: "/tmp/connection-two.json")
        #expect(Array(first.instructions.utf8) == Array(second.instructions.utf8))
        #expect(first.instructions.contains("Edit documents."))
    }
}
