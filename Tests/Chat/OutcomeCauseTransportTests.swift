import AutomationMCP
import EngineCore
import Foundation
import LocalMCP
import Switches
import Testing

@MainActor
struct OutcomeCauseTransportTests {
    @Test func producerCauseReachesCatalogue() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            session.actionResult = ActOutcome(.refused, "Producer prose.", notSent: .targetUnreachable,
                                              cause: "remote_content_refused.opens_list#42")
            let result = try await AutomationTools(session: session).call("act", .object([
                "session": .string(try #require(session.id).uuidString), "target": .string("Control")
            ]))
            let text = try #require(result["content"].array?.first?["text"].string)
            #expect(text.contains("The control opens a list of choices."))
            #expect(!text.contains("Producer prose."))
            #expect(!text.contains("42"))
        }
    }
}
