import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing
@testable import AutomationMCP

@Suite
@MainActor
struct ResultFormatterConstructionTests {
    @Test
    func handwrittenOutcome() async throws {
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
        let outcome = ActOutcome(.foundActed, "handwritten result", check:
            OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                verdict: .passed, performed: .requested))
        let actual = await formatter.outcome(outcome)
        let expected = JSONValue.object([
            "message": .string("handwritten result"),
            "session": .string(try #require(session.id).uuidString),
            "gesture": .string("sent"), "effect": .string("confirmed"), "recovery": .string("continue"),
            "_outcome_message": .string(OutcomeText.message(OutcomeKey(outcome: outcome.outcome, verb: ""), label: nil))
        ])
        #expect(actual == expected)
    }
}
