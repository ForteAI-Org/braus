import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Testing
@testable import AutomationMCP

@MainActor
struct ResultFormatterOutcomeTests {
    @Test func uncertainProducerDiagnosisIsCompleteLocallyAndAbsentFromBothModelChannels() async throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        secrets.secrets = ["synthetic-private"]
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        var records: [String] = []
        formatter.record = { records.append($0) }
        let detail = String(repeating: "detail-", count: 20) + "synthetic-private"
        let value = await formatter.outcome(ActOutcome(.actedUnverified,
            "Read the attached state; " + OutcomeText.deliveryFailure + detail,
            check: .init(condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                limits: [.deliveryUncertain], performed: .uncertain)))
        let result = try formatter.finish("act", value, notice: nil, output: CallOutput())
        let text = try #require(result["content"].array?.first?["text"].string)
        let structured = String(decoding: try JSONEncoder().encode(result["structuredContent"]), as: UTF8.self)
        #expect(!text.contains("detail-") && !structured.contains("detail-"))
        #expect(!text.contains("synthetic-private") && !structured.contains("synthetic-private"))
        #expect(records.joined().contains(String(repeating: "detail-", count: 20)))
        #expect(!records.joined().contains("synthetic-private"))
    }

    @Test func ordinaryOutcomeFormat() async throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let value = await formatter.outcome(ActOutcome(.foundActed, "Original bytes.", check:
            OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                verdict: .passed, performed: .requested)))
        let result = try formatter.finish("act", value, notice: nil, output: CallOutput())
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(value["gesture"].string == "sent")
        #expect(value["effect"].string == "confirmed")
        #expect(value["recovery"].string == "continue")
        #expect(text.contains("sent · confirmed · continue\n"))
    }

    @Test func hostIdentityReportsTheDeliveredContractWithoutARolloutMap() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "runtime-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: directory)
        do {
            let session = ToolResultSession()
            session.memoryDirectory = directory
            let tools = AutomationTools(session: session)
            let object = try await tools.runtimeIdentity()
            #expect(object["runtime"]["contract"].string == "braus-t2-single-path")
            #expect(object["runtime"]["features"].array?.contains(.string("compact_outcome")) == true)
            #expect(object["runtime"]["served_tools"].array?.compactMap(\.string)
                == tools.toolDefinitions.compactMap { $0["name"].string })
            #expect(object["switches"] == .null && object["configuration"] == .null)
            #expect(!tools.toolDefinitions.contains { $0["name"].string == "memory_task" })
        } catch { Issue.record(error) }
        await memory.close()
        MemoryService.forget(directory)
        try FileManager.default.removeItem(at: directory)
    }

    @Test func typedResponseAndTranscript() async throws {
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
        #expect(text.contains("not_sent · not_applicable · change_target(unreachable)\n"))
        #expect(text.contains("The control opens a list of choices."))
        #expect(!text.contains("Private producer details"))
        #expect(result["structuredContent"]["gesture"].string == "not_sent")
        #expect(!String(describing: result["structuredContent"]).contains("Private producer details"))
        #expect(!text.contains("status") && !text.contains("evidence"))
        let record = try #require(records.first)
        #expect(record.contains("\"gesture\":\"not_sent\""))
        #expect(record.contains("\"effect\":\"not_applicable\""))
        #expect(record.contains("\"recovery\":\"change_target(unreachable)\""))
        #expect(record.contains("Private producer details."))
        #expect(!record.contains("_outcome_message"))
    }

    @Test func ordinaryOutcomeKeepsTypedFieldsAndItsInternalDiagnostic() async throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let result = await formatter.outcome(ActOutcome(.foundActed, "Original bytes.", check:
            OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                verdict: .passed, performed: .requested)))
        #expect(result["status"] == .null && result["evidence"] == .null)
        #expect(result["message"].string == "Original bytes.")
        #expect(result["gesture"].string == "sent")
        #expect(result["effect"].string == "confirmed")
        #expect(result["recovery"].string == "continue")
        #expect(result["_outcome_message"].string?.isEmpty == false)
    }

    @Test func listingKeepsItsItemsAsObservation() async throws {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let value = await formatter.outcome(ActOutcome(.actedNoop, "Menu holds: First, Second.", noop: .listing))
        let result = try formatter.finish("menu", value, notice: nil, output: CallOutput())
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(text.contains("not_sent · not_applicable · continue\n"))
        #expect(text.contains("First, Second"))
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
            #expect(text.contains(acted ? "uncertain · unknown(not_readable) · do_not_repeat" : "not_sent · not_applicable · do_not_repeat"))
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
            #expect(text.contains("not_sent · not_applicable · do_not_repeat"))
            #expect(text.contains("Specific refusal: [withheld]."))
            #expect(!text.contains("fake-private-value"))
            #expect(text.contains(OutcomeText.message(OutcomeKey(
                outcome: Outcome(gesture: .notSent, effect: .notApplicable, recovery: .doNotRepeat),
                verb: "act", cause: cause), label: nil)))
        }
    }

    @Test func batchStartRefusalIsNotSent() {
        let session = ToolResultSession()
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        defer { withExtendedLifetime((secrets, sceneText)) {} }
        let result = formatter.thrown(AutomationFailure("fake failure", cause: "memory_unconfirmed"),
            tool: "batch", mayHaveActed: false)
        let text = result["content"].array?.first?["text"].string ?? ""
        #expect(result["isError"].bool == true)
        #expect(text.contains("not_sent · not_applicable · do_not_repeat"))
        #expect(text.contains("Memory did not confirm"))
        #expect(!text.contains("fake failure"))
    }

    @Test func substitutedNoopExplainsTheUnmadeClick() async throws {
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
            #expect(text.contains("not_sent · not_applicable · retry"))
            #expect(text.contains("A menu was open and was closed instead; the click was not made."))
        }
    }

}
