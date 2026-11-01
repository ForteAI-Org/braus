import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct ResultFormatterOutcomeTests {
    @Test func typedResponseAndTranscript() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            var records: [String] = []
            formatter.record = { records.append($0) }
            let value = await formatter.outcome(ActOutcome(.refused, "Private producer details.",
                notSent: .targetUnreachable, cause: "remote_content_refused.opens_list"))
            let result = try formatter.finish("act", value, notice: nil, output: CallOutput())
            let text = try #require(result["content"].array?.first?["text"].string)
            #expect(text.hasPrefix("not_sent · not_applicable · change_target(unreachable)\n"))
            #expect(text.contains("The control opens a list of choices."))
            #expect(!text.contains("Private producer details"))
            #expect(result["structuredContent"] == .null)
            #expect(!text.contains("status") && !text.contains("evidence"))
            let record = try #require(records.first)
            #expect(record.contains("\"gesture\":\"not_sent\""))
            #expect(record.contains("\"effect\":\"not_applicable\""))
            #expect(record.contains("\"recovery\":\"change_target(unreachable)\""))
            #expect(record.contains("Private producer details."))
            #expect(!record.contains("_outcome_message"))
        }
    }

    @Test func defaultArmMatchesV1() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard()) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            let result = await formatter.outcome(ActOutcome(.foundActed, "Original bytes."))
            #expect(result["status"].string == "found_acted")
            #expect(result["message"].string == "Original bytes.")
            #expect(result["evidence"] != .null)
            #expect(result["gesture"] == .null)
        }
    }

    @Test func listingKeepsItsItemsAsObservation() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            let value = await formatter.outcome(ActOutcome(.actedNoop, "Menu holds: First, Second.", noop: .listing))
            let result = try formatter.finish("menu", value, notice: nil, output: CallOutput())
            let text = try #require(result["content"].array?.first?["text"].string)
            #expect(text.hasPrefix("not_sent · not_applicable · continue\n"))
            #expect(text.contains("First, Second"))
        }
    }

    @Test func thrownUsesCatalogue() {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        for acted in [false, true] {
            let result = formatter.thrown(AutomationFailure("fake-secret-value"), tool: "act", mayHaveActed: acted)
            let text = result["content"].array?.first?["text"].string ?? ""
            #expect(result["isError"].bool == true)
            #expect(!text.contains("fake-secret-value"))
            #expect(text.hasPrefix(acted ? "uncertain · unknown(not_readable) · observe" : "not_sent · not_applicable · do_not_repeat"))
        }
    }
}
