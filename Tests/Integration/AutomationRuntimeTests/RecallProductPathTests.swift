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
@testable import SQLiteMemory
import Testing

/// RecallProductPathTests prove, through `memory_task` and SQLite with no flag and no control, what the product's one path
/// of the Recall (the agent's choice) answers in every state an agent meets: an archive with nothing learned, an index not
/// built, unreadable, behind the catalogue or without its semantic model; a proposal never chosen, a plan refused, a
/// proposal's id given as a query's; a task ended without its interpretation; knowledge learned by the app and reused by an
/// MCP client and the other way round, each with its own task and values; an archive closed and opened again. In each the
/// agent gets an answer it can act on, never a hidden selection and never an absence it cannot tell from a fault. The plans
/// are written by the test: they prove the contract, not what an agent chooses. These are integration proofs, not a live run.
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
        let begun = try await P.task(tools, C.proposeRequest.replacingOccurrences(of: #""recall_mode":"propose","#, with: ""))
        #expect(begun["status"].string == "begun" && begun["recall"] == .null, "\(begun)")
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
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        #expect(ended["status"].string == "ended" && ended["candidate"]["id"].string != nil, "\(ended)")
        #expect(try Self.count("memory_recall_proposals", session) == 1 && Self.count("memory_recall_queries", session) == 0)
        await L.close(session)
    }

    @Test("an index learned but irrelevant to the request: no source, the guidance says nothing fits; the search is no failure")
    func nothingFits() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let begun = try await P.task(P.tools(session, stream: "unrelated"),
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
        let begun = try await P.task(tools, C.proposeRequest)
        let proposal = begun["recall_proposal"]
        #expect(begun["status"].string == "begun", "the task is begun all the same")
        #expect(proposal["search"]["status"].string == "failed" && proposal["index"]["status"].string == "failed", "\(proposal)")
        #expect(proposal["search"]["note"].string?.contains("disk I/O error") == true)
        #expect(proposal["guidance"].string == RecallProposalDelivery.unsearchedGuidance)
        let id = try #require(proposal["proposal"].string)
        let refused = try await tools.call("memory_task", P.json(C.choose(id, [("s1", 1, 1)])))
        #expect(refused["isError"] == .bool(true) && "\(refused.payload)".contains("search could not answer"), "\(refused.payload)")
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
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        _ = try await P.task(tools, P.photoInterpretation(candidate))
        let second = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        let behind = try await P.task(P.tools(session, stream: "asker-1"), C.proposeRequest)["recall_proposal"]
        #expect(behind["search"]["status"].string == "limited" && (RecallCycleTests.int(behind["index"]["pendingWork"]) ?? 0) > 0, "\(behind)")
        #expect(behind["search"]["note"].string?.contains("not in the index yet") == true, "\(behind["search"])")
        #expect(Self.source(behind, first) != nil && Self.source(behind, second) == nil, "the index answers with what it holds")
        await service.holdWork(false)
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        let caught = try await P.task(P.tools(session, stream: "asker-2"), C.proposeRequest)["recall_proposal"]
        #expect(caught["search"]["status"].string == "completed" && Self.source(caught, second) != nil, "\(caught)")
        await L.close(session)
    }

    @Test("a hybrid search without its model's files: the lexical index answers, the proposal says the semantic channel is unavailable and why")
    func semanticUnavailable() async throws {
        let session = P.photoSession(try W.directory())
        var configuration = L.configuration(.hybrid)
        configuration.model = .graniteEmbedding107MMultilingual
        configuration.modelsDirectory = session.directory.appendingPathComponent("NoModels", isDirectory: true)
        let (_, routeID) = try await L.learnPhoto(session, configuration: configuration)
        let proposal = try await P.task(P.tools(session, stream: "asker"), C.proposeRequest)["recall_proposal"]
        #expect(proposal["search"]["channel"].string == "lexical" && proposal["search"]["status"].string == "limited", "\(proposal["search"])")
        #expect(proposal["search"]["note"].string?.contains("the semantic index is unavailable") == true)
        #expect(proposal["index"]["note"].string?.hasPrefix("semantic model:") == true, "\(proposal["index"])")
        #expect(Self.source(proposal, routeID) != nil, "the lexical channel still offers what it finds")
        await L.close(session)
    }

    // MARK: The agent's part of the exchange

    @Test("a proposal never chosen: the task goes on and ends; a use naming the proposal is refused with what to name instead, recording nothing")
    func choiceMissingAndProposalAsQuery() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await L.learnPhoto(session)
        let tools = P.tools(session, stream: "skipper")
        let proposal = try await P.task(tools, C.proposeRequest)["recall_proposal"]
        let id = try #require(proposal["proposal"].string)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(session.id!.uuidString)","target":"Rotate Right"}"#)
        let refused = try await tools.call("memory_task", P.json(#"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(id)","need":1,"outcome":"followed"}]}
            """#))
        #expect(refused["isError"] == .bool(true) && "\(refused.payload)".contains("is a proposal, not a query"), "\(refused.payload)")
        #expect("\(refused.payload)".contains("Nothing was recorded"))
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        #expect(ended["status"].string == "ended", "the task ends without the use")
        #expect(try Self.count("memory_recall_choices", session) == 0 && Self.count("memory_recall_queries", session) == 0)
        #expect(try Self.count("memory_recall_proposals", session) == 1, "the proposal is kept as proposed, never chosen")
        await L.close(session)
    }

    @Test("a task ended without its interpretation keeps its facts and candidate, learns no procedure, and later proposals offer nothing of it")
    func interpretationOmitted() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        #expect(ended["status"].string == "ended" && ended["candidate"]["id"].string != nil && ended["candidate_error"] == .null, "\(ended)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        #expect(try Self.count("memory_agent_actions", session) > 0, "the trace is kept")
        #expect(try Self.count("memory_procedure_candidates", session) == 1)
        #expect(try Self.count("memory_procedure_versions", session) == 0, "no interpretation, no procedure")
        let proposal = try await P.task(P.tools(session, stream: "asker"), C.proposeRequest)["recall_proposal"]
        #expect(proposal["sources"].array?.isEmpty == true && proposal["guidance"].string == RecallProposalDelivery.nothingGuidance,
                "\(proposal)")
        await L.close(session)
    }

    // MARK: A measure's control

    @Test("a measure's control turns the Recall off in its process: nothing fits, the record names the ablation, the task is learned as usual")
    func measureControl() async throws {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        try await MeasureAblation.$testing.withValue(.recall) {
            let tools = P.tools(session, stream: "control")
            let proposal = try await P.task(tools, C.proposeRequest)["recall_proposal"]
            #expect(proposal["sources"].array?.isEmpty == true && proposal["guidance"].string == RecallProposalDelivery.nothingGuidance,
                    "\(proposal)")
            #expect(proposal["search"]["note"].string == MeasureAblation.recallNote && proposal["index"]["status"].string == "off",
                    "the index is said off, never empty: the archive learned the version")
            #expect(try P.rows("SELECT search_note FROM memory_recall_proposals WHERE source_stream_id = 'control'", in: session)
                    == [MeasureAblation.recallNote], "the record says the search was turned off, never that nothing was learned")
            let ended = try await P.task(tools, #"{"operation":"end","outcome":"abandoned"}"#)
            #expect(ended["status"].string == "ended")
        }
        // Without the ablation the same archive offers the version again.
        let again = try await P.task(P.tools(session, stream: "after-control"), C.proposeRequest)["recall_proposal"]
        #expect(Self.source(again, routeID) != nil)
        #expect(MeasureAblation.parse("recall, brain") == [.recall, .brain] && MeasureAblation.parse("other").isEmpty)
        await L.close(session)
    }

    @Test("a measure's ablation of the Brain shows each scene as perceived while the Brain still learns from it")
    func brainAblation() async throws {
        let memory = try W.service()
        let window = W.window([W.format, W.save])
        let recorder = W.recorder(memory)
        let shown = await MeasureAblation.$testing.withValue(.brain) { await recorder.observe(window) }
        #expect(shown == window.scene, "no enrichment under the ablation")
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try await memory.brain(of: W.bundle)?.objects.isEmpty == false, "the Brain learned all the same")
        await memory.close()
    }

    @Test("memory_task status says the archive this process records into and the Recall configuration it runs, for a run's preflight")
    func statusIdentity() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        var configuration = L.configuration(.hybrid)
        configuration.model = .graniteEmbedding107MMultilingual
        configuration.modelsDirectory = session.directory.appendingPathComponent("Models", isDirectory: true)
        RecallService.install(RecallService(memory: memory, configuration: configuration))
        let status = try await P.task(P.tools(session), #"{"operation":"status"}"#)
        #expect(status["archive"].string == memory.url.path, "\(status)")
        let recall = status["recall"]
        #expect(recall["channel"].string == "hybrid" && recall["owns_index"].bool == true && recall["format"].string == "recall-document-1")
        #expect(recall["model"].string == "ibm-granite/granite-embedding-107m-multilingual@d6cffd338414d6a1c1f5decfad5fec62eebc90d5", "\(recall)")
        #expect(recall["models_folder"].string == configuration.modelsDirectory?.path && recall["model_state"].string == "not loaded yet")
        // A measure's control is named by the process it runs in, and only then.
        #expect(status["measure_ablation"] == .null, "\(status)")
        let controlled = try await MeasureAblation.$testing.withValue([.recall, .brain]) {
            try await P.task(P.tools(session), #"{"operation":"status"}"#)
        }
        #expect(controlled["measure_ablation"].array?.compactMap(\.string) == ["recall", "brain"], "\(controlled)")
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
        let begun = try await S.task(client, C.proposeRequest)
        let proposal = begun["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await S.task(client, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        let tract = try #require(chosen["recall"]["needs"].array?.first?["tracts"].array?.first, "\(chosen)")
        let name = (tract["parameters"].array ?? []).first { $0["name"].string == "output_name" }
        #expect(name?["value"].string == "foto_mail", "the client's own value, never the worker's foto_web: \(tract)")
        let query = try #require(chosen["recall"]["query"].string)
        try await S.export(client, session: session)
        let ended = try await S.task(client, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        #expect(ended["recall_use"].array?.first?["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7], "\(ended)")
        #expect(try S.rows("SELECT source || ':' || source_stream_id FROM memory_recall_queries", worker) == ["mcp:mcp-client"])
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
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
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
        let ended = try await S.task(client, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await S.task(client, P.photoInterpretation(candidate))
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        let routeID = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        let worker = P.photoSession(directory)
        let tools = P.tools(worker, stream: "worker-1")
        let proposal = try await P.task(tools, C.proposeRequest)["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await P.task(tools, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        #expect(chosen["status"].string == "chosen", "\(chosen)")
        #expect(try S.rows("SELECT source || ':' || source_stream_id FROM memory_procedure_interpretations", worker) == ["mcp:mcp-client"])
        #expect(try S.rows("SELECT source || ':' || source_stream_id FROM memory_recall_queries", worker) == ["app:worker-1"])
        #expect(try S.rows("SELECT DISTINCT source || ':' || source_stream_id FROM memory_recall_proposals", worker) == ["app:worker-1"])
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
        let proposal = try await P.task(tools, C.proposeRequest)["recall_proposal"]
        let key = try #require(Self.source(proposal, routeID), "\(proposal)")
        let chosen = try await P.task(tools, C.choose(try #require(proposal["proposal"].string), [(key, 4, 7)]))
        let tract = try #require(chosen["recall"]["needs"].array?.first?["tracts"].array?.first, "\(chosen)")
        #expect(tract["version"].string == routeID)
        #expect((tract["parameters"].array ?? []).contains { $0["name"].string == "output_format" && $0["value"].string == "PNG" }, "\(tract)")
        await L.close(session)
    }
}
