import EngineCore
import Foundation
import LocalMCP
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct ReplayOutcomeTests {
    @Test(arguments: try ReplayCorpus.load().filter { $0.input != nil })
    func boundedModelAnswer(_ item: ReplayCase) async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let input = try #require(item.input)
            let session = ReplaySession()
            session.id = input.session
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            var answer = JSONValue.null
            for value in input.prefix + [input.outcome] {
                session.observedWindowNumber = value.windowNumber
                answer = await formatter.outcome(try value.converted())
            }
            let result = try formatter.finish(item.tool, answer, notice: nil, output: CallOutput())
            let text = try #require(result["content"].array?.first?["text"].string)
            let lines = text.split(separator: "\n")
            let row = String(try #require(lines.first))
            let outcome = try #require(Outcome.parse(row))
            let message = String(try #require(lines.dropFirst().first))
            #expect(message.count <= 160)
            #expect(!MessageContract.mentionsObserve(message) || outcome.recovery == .observe)
            #expect(outcome.recovery != .observe || input.outcome.scene == nil)
            #expect(result["structuredContent"] == .null)
        }
    }
}
