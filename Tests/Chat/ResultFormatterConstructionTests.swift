import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing
import Switches
@testable import AutomationMCP

@Suite
@MainActor
struct ResultFormatterConstructionTests {
    @Test
    func handwrittenOutcome() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v1"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(
                session: session,
                secrets: secrets,
                sceneText: sceneText
            )
            // The formatter borrows these owners, so the example keeps them alive through the call.
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            let outcome = ActOutcome(.foundActed, "handwritten result", scene: nil)
            let actual = await formatter.outcome(outcome)
            let expected = JSONValue.object([
                "status": .string("found_acted"),
                "message": .string("handwritten result"),
                "session": .string(try #require(session.id).uuidString),
                "evidence": .object([
                    "command": .string("uncertain"),
                    "effect": .object([
                        "condition": .string("none"), "method": .string("none"),
                        "version": .string("engine-oracle-1"), "verdict": .string("unknown"),
                        "limits": .array([])
                    ]),
                    "goal": .string("not judged by a call: the task's result check says it")
                ])
            ])
            #expect(actual == expected)
        }
    }
}
