import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct ResultFormatterOutcomeTests {
    @Test func environmentSelectsOutcomeFormat() async throws {
        let arm = SwitchBoard.fromEnvironment(ProcessInfo.processInfo.environment)
            .arm("outcome", default: ResultFormatter.OutcomeArm.v1)
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let value = await formatter.outcome(ActOutcome(.foundActed, "Original bytes."))
        let result = try formatter.finish("act", value, notice: nil, output: CallOutput())
        let text = try #require(result["content"].array?.first?["text"].string)
        if arm == .v2 {
            #expect(text.hasPrefix("sent · confirmed · continue\n"))
        } else {
            let object = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            #expect(object["status"].string == "found_acted")
            #expect(object["message"].string == "Original bytes.")
        }
    }

    @Test(arguments: ["v1", "v2", "invalid-status-test"])
    func taskStatusReportsSwitches(_ arm: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "switch-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: directory)
        do {
            try await SwitchBoard.$testing.withValue(SwitchBoard.fromEnvironment(["BRAUS_SWITCHES": "outcome=\(arm)"])) {
                let session = ToolResultSession()
                session.memoryDirectory = directory
                let tools = AutomationTools(session: session)
                let result = try await tools.call("memory_task", .object(["operation": .string("status")]))
                let text = try #require(result["content"].array?.first?["text"].string)
                let object = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                #expect(object["switches"]["outcome"].string == arm)
                if arm == "invalid-status-test" {
                    #expect(object["switches_invalid"]["outcome"].string == arm)
                } else {
                    #expect(object["switches_invalid"].object != nil)
                }
            }
        } catch {
            Issue.record(error)
        }
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }

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
    @Test func notSentFailuresKeepMinimizedDetailsAndCauses() {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        for cause in ["no_session", "memory_unconfirmed", "uncertainty_refusal", "historical_value_refusal"] {
            let result = formatter.thrown(AutomationFailure("fake-private-value", cause: cause), tool: "act",
                                          mayHaveActed: false, minimized: "Specific refusal: [withheld].")
            let text = result["content"].array?.first?["text"].string ?? ""
            #expect(text.hasPrefix("not_sent · not_applicable · do_not_repeat"))
            #expect(text.contains("Specific refusal: [withheld]."))
            #expect(!text.contains("fake-private-value"))
            #expect(text.contains(OutcomeText.message(OutcomeKey(
                outcome: Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat),
                verb: "act", cause: cause), label: nil)))
        }
    }

    @Test func batchStartRefusalIsNotSent() throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        try SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let result = try formatter.finish("batch", .object(["steps": .array([.object([
                "status": .string("error"), "message": .string("fake failure"),
                "_failure_cause": .string("memory_unconfirmed")
            ])])]), notice: nil, output: CallOutput())
            let text = result["content"].array?.first?["text"].string ?? ""
            #expect(text.contains("not_sent · not_applicable · do_not_repeat"))
            #expect(text.contains("Memory did not confirm"))
            #expect(!text.contains("_failure_cause"))
        }
    }

    @Test func substitutedNoopExplainsTheUnmadeClick() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let sceneText = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
            defer { withExtendedLifetime((secrets, sceneText)) {} }
            let refusal = ResultFormatter.RefusalContext(sessionID: try #require(session.id), windowNumber: 1,
                tool: "act", arguments: .object(["target": .string("Control")]))
            for _ in 0..<2 {
                let value = await formatter.outcome(ActOutcome(.actedNoop, "Historical text", noop: .substituted),
                                                    refusal: refusal)
                let result = try formatter.finish("act", value, notice: nil, output: CallOutput())
                let text = result["content"].array?.first?["text"].string ?? ""
                #expect(text.hasPrefix("not_sent · not_applicable · retry"))
                #expect(text.contains("A menu was open and was closed instead; the click was not made."))
            }
        }
    }

}
