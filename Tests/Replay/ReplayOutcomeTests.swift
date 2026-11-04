import EngineCore
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

@MainActor
struct ReplayOutcomeTests {
    @Test(arguments: try ReplayCorpus.load().filter { $0.input != nil })
    func boundedModelAnswer(_ item: ReplayCase) async throws {
        do {
            let input = try #require(item.input)
            let result = try await regenerateModelAnswer(input, tool: item.tool)
            let text = try #require(result["content"].array?.first?["text"].string)
            let lines = text.split(separator: "\n")
            let row = String(try #require(lines.first { Outcome.parse(String($0)) != nil }))
            let outcome = try #require(Outcome.parse(row))
            let index = try #require(lines.firstIndex(of: Substring(row)))
            let message = String(try #require(lines.dropFirst(index + 1).first))
            #expect(message.count <= 160)
            #expect(!MessageContract.mentionsObserve(message) || outcome.recovery == .observe)
            #expect(outcome.recovery != .observe || input.outcome.scene == nil)
            #expect(result["structuredContent"]["gesture"].string == outcome.gesture.rawValue)
            #expect(result["structuredContent"]["message"].string == message)
            #expect(result["structuredContent"]["_outcome_message"] == .null)
        }
    }
}
