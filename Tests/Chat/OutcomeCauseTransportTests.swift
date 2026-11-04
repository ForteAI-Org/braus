import AutomationMCP
import EngineCore
import Foundation
import LocalMCP
import Testing

@MainActor
struct OutcomeCauseTransportTests {
    @Test func producerCauseReachesCatalogue() async throws {
        let session = ToolResultSession()
        session.actionResult = ActOutcome(.refused, "Producer prose.", notSent: .targetUnreachable,
                                          cause: "remote_content_refused.opens_list#42")
        try await session.withPlannedTools { tools in
            let result = try await tools.call("act", .object([
                "step": .string("r1"), "target": .string("Control")
            ]))
            let text = try #require(result["content"].array?.first?["text"].string)
            #expect(text.contains("The control opens a list of choices."))
            #expect(!text.contains("Producer prose."))
            #expect(!text.contains("42"))
        }
    }
}
