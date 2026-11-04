//
//  RecallProductPathTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalEmbedding
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallProductPathTests retain Recall service fault, persistence, privacy and attribution scenarios.
/// Current plan/action/end entries are distinct from explicit typed proposal/choice/report fixtures.
/// A historical service delivery is never claimed to be the current model's plan response.
@MainActor
@Suite("The Recall's one product path, the agent's choice, through the tool in every state", .serialized)
struct RecallProductPathTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests
    typealias S = RecallSharingTests
    typealias C = RecallChoiceToolTests

    static func count(_ table: String, _ session: LearningSession) throws -> Int {
        Int(try P.rows("SELECT count(*) FROM \(table)", in: session).first ?? "0") ?? 0
    }

    /// The proposal's version of `routeID` and its name in the proposal, when it is offered.
    static func source(_ proposal: JSONValue, _ routeID: String) -> String? {
        proposal["sources"].array?.first { $0["version"].string == routeID }?["source"].string
    }

    // MARK: Nothing to choose from

    @Test("an archive with nothing learned: the proposal offers no source, says so and asks for no choice; the task goes on")
    func nothingLearned() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        let begun = try await HistoricalRecallFixture.beginPlannedProposal(tools, C.proposeRequest.replacingOccurrences(of: #""recall_mode":"propose","#, with: ""))
        #expect(begun["status"].string == "proposed" && begun["recall"] == .null, "\(begun)")
        let proposal = begun["recall_proposal"]
        #expect(proposal["sources"].array?.isEmpty == true, "\(proposal)")
        // Nothing was ever learned: the catalogue proves it whatever the index is doing, and the search is no failure.
        #expect(proposal["guidance"].string == RecallProposalDelivery.nothingGuidance, "\(proposal)")
        // Either the catalogue answered before any index existed, or the worker had already made an empty one.
        let index = proposal["index"]["status"].string, note = proposal["search"]["note"].string
        #expect(proposal["search"]["status"].string == "completed", "\(proposal)")
        #expect((index == "empty" && note == "nothing has been learned on this Mac yet") || (index == "ready" && note == nil), "\(proposal)")
        // Nothing to choose: the agent acts with the tools, and the task ends as usual.
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        let ended = try await P.task(tools, #"{"outcome":"completed"}"#)
        #expect(ended["status"].string == "ended" && ended["candidate"] == .null, "\(ended)")
        #expect(try Self.count("memory_recall_proposals", session) == 2 && Self.count("memory_recall_queries", session) == 0)
        await L.close(session)
    }

    @Test("an index learned but irrelevant to the request: no source, the guidance says nothing fits; the search is no failure")
    func nothingFits() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let begun = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "unrelated"),
                                     #"{"operation":"begin","goal":"Ascolta il podcast zzqxv sul giradischi"}"#)
        let proposal = begun["recall_proposal"]
        #expect(proposal["search"]["status"].string == "completed" && proposal["index"]["status"].string == "ready", "\(proposal)")
        #expect(proposal["sources"].array?.isEmpty == true && proposal["guidance"].string == RecallProposalDelivery.nothingGuidance,
                "\(proposal)")
        await L.close(session)
    }

    @Test("an index that cannot be read: the proposal says failed, no proof of absence; a choice from it is refused and records nothing")
    func unreadableIndex() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        await RecallService.shared(for: memory).setIndexFault(RecallCorpus.Failure("disk I/O error"))
        let tools = P.tools(session, stream: "worker-2")
        let begun = try await HistoricalRecallFixture.beginProposal(tools, C.proposeRequest)
        let proposal = begun["recall_proposal"]
        #expect(begun["status"].string == "begun", "the task is begun all the same")
        #expect(proposal["search"]["status"].string == "failed" && proposal["index"]["status"].string == "failed", "\(proposal)")
        #expect(proposal["search"]["note"].string?.contains("disk I/O error") == true)
        #expect(proposal["guidance"].string == RecallProposalDelivery.unsearchedGuidance)
        let id = try #require(proposal["proposal"].string)
        let refused = try await HistoricalRecallFixture.choose(tools, C.choose(id, [("s1", 1, 1)]))
        #expect(refused["status"].string == "error" && "\(refused)".contains("search could not answer"), "\(refused)")
        #expect(try Self.count("memory_recall_queries", session) == 0)
        await L.close(session)
    }

    @Test("an index behind the catalogue says so and still answers; once the work is done the new version is offered")
    func indexBehind() async throws {
        let session = P.photoSession(try W.directory())
        let (_, first) = try await L.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService.shared(for: memory)
        await service.holdWork(true)
        // A second photo export learned while the worker is held: its index work stays pending.
        let tools = P.tools(session, stream: "learner-2")
        _ = try await P.task(tools, #"""
            {"request":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"outcome":"completed"}"#)
        let candidate = try await P.candidateIDFixture(tools, session)
        _ = try await P.interpretFixture(tools, session, P.photoInterpretation(candidate))
        let second = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        let behind = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "asker-1"), C.proposeRequest)["recall_proposal"]
        #expect(behind["search"]["status"].string == "limited" && (RecallCycleTests.int(behind["index"]["pendingWork"]) ?? 0) > 0, "\(behind)")
        #expect(behind["search"]["note"].string?.contains("not in the index yet") == true, "\(behind["search"])")
        // The second export repeats the first one's method, so its version replaced the first in the catalogue
        // (`ProcedureMethod`): the index, behind, offers neither the replaced version nor the one it has not indexed yet.
        #expect(Self.source(behind, first) == nil && Self.source(behind, second) == nil, "the index answers with what it holds")
        await service.holdWork(false)
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        let caught = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "asker-2"), C.proposeRequest)["recall_proposal"]
        #expect(caught["search"]["status"].string == "completed" && Self.source(caught, second) != nil, "\(caught)")
        await L.close(session)
    }

    @Test("a version learned by the process before, its index work still pending at its exit, is offered by the next process's first search at once")
    func learnedJustBefore() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        await RecallService.shared(for: memory).holdWork(true)
        // The process that learns the second export ends before its worker enters it: the work stays pending in the archive.
        let tools = P.tools(session, stream: "learner-2")
        _ = try await P.task(tools, #"""
            {"request":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"outcome":"completed"}"#)
        let candidate = try await P.candidateIDFixture(tools, session)
        _ = try await P.interpretFixture(tools, session, P.photoInterpretation(candidate))
        let second = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        await L.close(session)
        // The next process: a Recall that never ran, and a search that does not wait for it first.
        let reopened = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: reopened, configuration: L.configuration()))
        let proposal = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "asker-next"), C.proposeRequest)["recall_proposal"]
        #expect(proposal["search"]["status"].string == "completed", "\(proposal["search"])")
        #expect(Self.source(proposal, second) != nil, "the version learned just before is offered: \(proposal)")
        await L.close(session)
    }

    @Test("a hybrid search without its model's files: the lexical index answers, the proposal says the semantic channel is unavailable and why")
    func semanticUnavailable() async throws {
        let session = P.photoSession(try W.directory())
        var configuration = L.configuration(.hybrid)
        configuration.model = .graniteEmbedding107MMultilingual
        configuration.modelsDirectory = session.directory.appendingPathComponent("NoModels", isDirectory: true)
        let memory = MemoryService.shared(for: session.directory)
        let missingModel = EmbeddingService { _ in throw EmbeddingService.Unavailable.notInstalled }
        let service = RecallService(memory: memory, configuration: configuration, embeddingService: missingModel)
        let (_, routeID) = try await L.learnPhoto(session, configuration: configuration, service: service)
        let proposal = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "asker"), C.proposeRequest)["recall_proposal"]
        #expect(proposal["search"]["channel"].string == "lexical" && proposal["search"]["status"].string == "limited", "\(proposal["search"])")
        #expect(proposal["search"]["note"].string?.contains("the semantic index is unavailable") == true)
        #expect(proposal["index"]["note"].string?.hasPrefix("semantic model:") == true, "\(proposal["index"])")
        #expect(Self.source(proposal, routeID) != nil, "the lexical channel still offers what it finds")
        await L.close(session)
    }

    // MARK: The agent's part of the exchange

    @Test("a proposal never chosen: the task goes on and ends; a use naming the proposal is answered with what to name instead, recording no use")
    func choiceMissingAndProposalAsQuery() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let tools = P.tools(session, stream: "skipper")
        let proposal = try await HistoricalRecallFixture.beginPlannedProposal(tools, C.proposeRequest)["recall_proposal"]
        let id = try #require(proposal["proposal"].string)
        let choiceRows = "SELECT query_id || ':' || proposal_id FROM memory_recall_choices ORDER BY query_id"
        let queryRows = "SELECT query_id || ':' || delivery FROM memory_recall_queries ORDER BY query_id"
        let choicesBefore = try P.rows(choiceRows, in: session)
        let queriesBefore = try P.rows(queryRows, in: session)
        #expect(try P.rows("SELECT count(*) FROM memory_recall_choices WHERE proposal_id = '\(id)'", in: session) == ["0"],
                "The explicit service proposal has never been chosen")
        let current = try #require(tools.openTask?.taskID)
        #expect(choicesBefore.isEmpty, "Neither offering a plan part nor proposing a service choice selects a tract: \(choicesBefore)")
        let planProposalTasks = try P.rows("SELECT t.task_uuid FROM memory_recall_proposals p JOIN memory_tasks t ON t.task_id = p.task_id WHERE p.proposal_id != '\(id)' ORDER BY p.proposal_id", in: session)
        #expect(planProposalTasks == [current], "The other proposal belongs to the real plan: \(planProposalTasks), expected \(current)")
        let storedOffer = try P.rows("SELECT CAST(p.proposal_id AS TEXT) || ':' || t.task_uuid FROM memory_recall_proposals p JOIN memory_tasks t ON t.task_id = p.task_id WHERE p.proposal_id = '\(id)'", in: session)
        #expect(storedOffer == [id + ":" + current], "The returned numeric identity names this task's stored proposal: \(storedOffer)")
        // The typed propose service passes no calibration. insertProposal creates a matching search query
        // only for nonempty calibration; the current plan's calibrated offers are a separate contract.
        let explicitReceipt = try P.rows("SELECT query_id FROM memory_recall_queries WHERE query_id = '\(id)'", in: session)
        #expect(explicitReceipt.isEmpty, "This unchosen typed proposal has no query receipt: \(explicitReceipt)")
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(session.id!.uuidString)","target":"Rotate Right"}"#)
        // The use is answered as not recorded; the end itself is recorded (review U2: refused, it left the task open).
        let ended = try await HistoricalRecallFixture.end(tools, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(id)","need":1,"outcome":"followed"}]}
            """#)
        #expect(ended["status"].string == "ended", "the task ends without the use: \(ended)")
        let problem = ended["use_not_recorded"].array?.first?.string ?? ""
        #expect(problem.contains("proposal") && problem.contains("not recorded"), "\(ended)")
        #expect(try P.rows(choiceRows, in: session) == choicesBefore)
        #expect(try P.rows(queryRows, in: session) == queriesBefore,
                "An invalid use creates no query, choice or delivery receipt")
        #expect(try P.rows("SELECT count(*) FROM memory_recall_choices WHERE proposal_id = '\(id)'", in: session) == ["0"])
        #expect(try Self.count("memory_recall_proposals", session) == 2, "the proposal is kept as proposed, never chosen")
        await L.close(session)
    }

    @Test("a task ended without its interpretation keeps its facts and candidate, learns no procedure, and later proposals offer nothing of it")
    func interpretationOmitted() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"request":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"outcome":"completed"}"#)
        #expect(ended["status"].string == "ended" && ended["candidate"] == .null && ended["candidate_error"] == .null, "\(ended)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        #expect(try Self.count("memory_agent_actions", session) > 0, "the trace is kept")
        #expect(try await P.candidateFixture(tools, session)["id"].string != nil)
        #expect(try Self.count("memory_procedure_candidates", session) == 1)
        #expect(try Self.count("memory_procedure_versions", session) == 0, "no interpretation, no procedure")
        let proposal = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "asker"), C.proposeRequest)["recall_proposal"]
        #expect(proposal["sources"].array?.isEmpty == true && proposal["guidance"].string == RecallProposalDelivery.nothingGuidance,
                "\(proposal)")
        await L.close(session)
    }

    // MARK: Session permissions

    @Test("learn skips Recall without changing the shared index")
    func memoryLearnRecallsNothingAndLearns() async throws {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        let tools = AutomationTools(session: session, profile: SessionProfile.cli.replacing(memory: .learn))
        tools.producer = CallProducer(source: .cli, streamID: "juniper")
        let response = try await HistoricalRecallFixture.beginProposal(tools, C.proposeRequest)
        let proposal = response["recall_proposal"]
        #expect(proposal["sources"].array?.isEmpty == true)
        #expect(response["memory_read_reason"].string == RecallService.MemoryReadReason.profileDoesNotReadMemory.rawValue)
        #expect(proposal["search"]["note"] == .null, "The raw service does not invent a model-facing explanation")
        #expect(proposal["index"]["status"].string == "off")
        #expect(proposal["search"]["partsConsidered"] == .number(0))
        _ = try await HistoricalRecallFixture.end(tools, #"{"operation":"end","outcome":"abandoned"}"#)
        let again = try await HistoricalRecallFixture.beginProposal(P.tools(session, stream: "juniper-read"), C.proposeRequest)["recall_proposal"]
        #expect(Self.source(again, routeID) != nil)
        await L.close(session)
    }

    @Test("off shows the perceived scene and records facts without Brain learning")
    func memoryOff() async throws {
        let memory = try W.service()
        let window = W.window([W.format, W.save])
        let shown = await MemoryAccess.$current.withValue(SessionProfile.cli.replacing(memory: .off).memoryAccess) {
            await W.recorder(memory).observe(window)
        }
        #expect(shown == window.scene)
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try await memory.brain(of: W.bundle)?.objects.isEmpty != false)
        await memory.close()
    }

    @Test("read-only memory keeps the historical projection frozen")
    func readOnlyMemoryKeepsProjectionFrozen() async throws {
        let memory = try W.service()
        let window = W.window([W.format, W.save])
        let shown = await MemoryAccess.$current.withValue(SessionProfile.cli.replacing(memory: .read).memoryAccess) {
            await W.recorder(memory).observe(window)
        }
        #expect(shown.knowledge?.status == .unrecognized)
        var live = shown
        live.knowledge = nil
        #expect(live == window.scene, "A read-only enrichment can annotate status while preserving every live scene field")
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try await memory.brain(of: W.bundle)?.objects.isEmpty == true)
        await memory.close()
    }

    @Test("runtime identity says the archive this process records into and the Recall configuration it runs, for a run's preflight")
    func statusIdentity() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        var configuration = L.configuration(.hybrid)
        configuration.model = .graniteEmbedding107MMultilingual
        configuration.modelsDirectory = session.directory.appendingPathComponent("Models", isDirectory: true)
        RecallService.install(RecallService(memory: memory, configuration: configuration))
        let status = try await AutomationTools(session: session, profile: .app).runtimeIdentity()
        #expect(status["archive"].string == memory.url.path, "\(status)")
        let recall = status["recall"]
        #expect(recall["channel"].string == "hybrid" && recall["owns_index"].bool == true && recall["format"].string == "recall-document-1")
        #expect(recall["model"].string == "ibm-granite/granite-embedding-107m-multilingual@d6cffd338414d6a1c1f5decfad5fec62eebc90d5", "\(recall)")
        #expect(recall["models_folder"].string == configuration.modelsDirectory?.path && recall["model_state"].string == "not loaded yet")
        #expect(status["profile"]["readsMemory"].bool == true)
        let controlled = try await AutomationTools(session: session,
            profile: SessionProfile.cli.replacing(memory: .off)).runtimeIdentity()
        #expect(controlled["profile"]["readsMemory"].bool == false)
        #expect(controlled["profile"]["learnsMemory"].bool == false)
        await L.close(session)
    }

    // MARK: Producers

    @Test("learned by an app worker, chosen and carried out by an MCP client with its own task and values: its query, links and use; the version untouched")
    func appToClient() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        let (_, routeID) = try await L.learnPhoto(worker)
        let session = P.photoSession(directory)
        let client = try await S.client(session)
        let begun = try await S.beginProposalFixture(client, C.proposeRequest)
        let proposal = begun["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await HistoricalRecallFixture.choose(client.tools, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        let tract = try #require(chosen["recall"]["needs"].array?.first?["tracts"].array?.first, "\(chosen)")
        let name = (tract["parameters"].array ?? []).first { $0["name"].string == "output_name" }
        #expect(name?["value"].string == "foto_mail", "the client's own value, never the worker's foto_web: \(tract)")
        let query = try #require(chosen["recall"]["query"].string)
        try await S.export(client, session: session)
        let ended = try await S.endFixture(client, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        #expect(ended["recall_use"].array?.first?["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7], "\(ended)")
        #expect(try S.rows("SELECT source || ':' || source_stream_id FROM memory_recall_queries WHERE query_id = '\(query)'", worker) == ["mcp:mcp-client"])
        #expect(try S.rows("SELECT DISTINCT source || ':' || source_stream_id FROM memory_procedure_interpretations", worker) == ["app:worker-1"])
        #expect(try S.rows("SELECT count(*) FROM memory_recall_choice_links", worker) == ["4"])
        await L.close(worker)
    }

    @Test("learned by an MCP client, chosen by an app worker with its own task: the client's version, the worker's query and values")
    func clientToApp() async throws {
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let session = P.photoSession(directory)
        let client = try await S.client(session)
        _ = try await S.task(client, #"""
            {"request":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        let id = session.id!.uuidString
        _ = try await S.call(client, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await S.call(client, "type_text", #"{"session":"\#(id)","target":"Search","text":"foto_demo"}"#)
        _ = try await S.call(client, "act", #"{"session":"\#(id)","target":"foto_demo.png"}"#)
        _ = try await S.call(client, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await S.call(client, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        try await S.export(client, session: session, name: "foto_web.jpg", format: "JPEG")
        _ = try await S.call(client, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await S.call(client, "act", #"{"session":"\#(id)","target":"Show Preview","verb":"set_toggle","value":"on"}"#)
        let ended = try await S.task(client, #"{"outcome":"completed"}"#)
        let candidate = try await P.candidateIDFixture(client.tools, session)
        let interpreted = try await P.interpretFixture(client.tools, session, P.photoInterpretation(candidate))
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        let routeID = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        let worker = P.photoSession(directory)
        let tools = P.tools(worker, stream: "worker-1")
        let proposal = try await HistoricalRecallFixture.beginProposal(tools, C.proposeRequest)["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await HistoricalRecallFixture.choose(tools, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        #expect(chosen["status"].string == "chosen", "\(chosen)")
        #expect(try S.rows("SELECT source || ':' || source_stream_id FROM memory_procedure_interpretations", worker) == ["mcp:mcp-client"])
        #expect(try S.rows("SELECT DISTINCT source || ':' || source_stream_id FROM memory_recall_queries WHERE delivery != 'proposed'", worker) == ["app:worker-1"])
        #expect(try S.rows("SELECT DISTINCT source || ':' || source_stream_id FROM memory_recall_proposals ORDER BY source", worker) == ["app:worker-1", "mcp:mcp-client"])
        await L.close(worker)
    }

    @Test("closed and opened again: the same version is proposed, chosen and delivered with the new task's values")
    func reopened() async throws {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        await L.close(session)
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        await RecallService.shared(for: memory).schedule()
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        let tools = P.tools(session, stream: "after-reopen")
        let proposal = try await HistoricalRecallFixture.beginProposal(tools, C.proposeRequest)["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await HistoricalRecallFixture.choose(tools, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        let tract = try #require(chosen["recall"]["needs"].array?.first?["tracts"].array?.first, "\(chosen)")
        #expect(tract["version"].string == routeID)
        #expect((tract["parameters"].array ?? []).contains { $0["name"].string == "output_format" && $0["value"].string == "PNG" }, "\(tract)")
        await L.close(session)
    }
}
