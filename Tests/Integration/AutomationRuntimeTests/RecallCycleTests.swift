//
//  RecallCycleTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
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

/// RecallCycleTests prove the D3 cycle through the product's own entry, with the chosen configuration, over the
/// session double that replaces only the operating system and the applications: the quality corpus learned through
/// the tools (D2's producers, qualification and archive), the archive closed and opened again, a new request with
/// other values whose `memory_task begin` searches the index and selects the export tract of the learned photo
/// export without the search and the rotation already done, the operations carried out through the tools, and the
/// calls linked to the delivered steps. Nothing is inserted by hand. With `BRAUS_RECALL_MODELS` the hybrid channel runs
/// on the real local model too; without it that case is skipped, saying so. These are integration proofs, not a live
/// run. The first learned procedure is recalled on an archive of one procedure (review F01): the review's request with the
/// product's configuration, the original wording and paraphrases with the semantic model, the original wording found
/// absent by the provisional lexical configuration (a limit); and a part's lexical score is shown independent of the
/// rest of the archive under the uniform and the version weightings, dependent under the collection's.
@MainActor
@Suite("The Recall answers a new request with the tract of a learned procedure, through the tools", .serialized, .automaticSelection)
struct RecallCycleTests {

    typealias P = ProcedureLearningTests

    nonisolated static var models: URL? {
        ProcessInfo.processInfo.environment["BRAUS_RECALL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A JSON number as an integer.
    static func int(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(exactly: number) }
        return nil
    }

    /// The hybrid thresholds the automatic selector was frozen at on the second development split
    /// (`recall-calibration-v2.json`), which these regressions of the selector keep. The product's configuration has used
    /// the agent's choice's own since 2026-10-13 (`RecallConfiguration.chosen`), which shape only a proposal's suggestion.
    static let selectorHybridThresholds = SelectionThresholds(absolute: 0.66, stepMargin: 0.1, partMargin: -0.4, adequacy: 0.05, tie: 0.04)

    static func configuration(_ channel: RecallConfiguration.Channel) -> RecallConfiguration {
        var configuration = RecallConfiguration.chosen
        configuration.channel = channel
        configuration.modelsDirectory = models
        configuration.hybridThresholds = selectorHybridThresholds
        if channel == .lexical { configuration.model = nil }
        return configuration
    }

    /// Learns the photo export of D2's S01 through the tools, ends and interprets it, and waits for the index.
    static func learn(_ session: LearningSession, channel: RecallConfiguration.Channel) async throws -> String {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: configuration(channel)))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await P.task(tools, P.photoInterpretation(candidate))
        #expect(interpreted["parts"].array?.allSatisfy { $0["admitted"].bool == true } == true, "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        return ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
    }

    /// Closes the archive and the Recall, as a quitting process does, and opens them again.
    static func reopen(_ session: LearningSession, channel: RecallConfiguration.Channel) async -> MemoryService {
        let memory = MemoryService.shared(for: session.directory)
        _ = await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60))
        RecallService.forget(memory)
        await memory.close()
        MemoryService.forget(session.directory)
        let reopened = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: reopened, configuration: configuration(channel)))
        return reopened
    }

    /// The request of the corpus's development query photo-1, evaluated with the chosen configuration: a wording
    /// further from the learned labels ("Export the document already open and edited in Preview as a PNG file named
    /// foto_mail") is found absent by the lexical channel, a limit the comparison reports.
    static let exportRequest = #"""
        {"operation":"begin","goal":"Export the photo already rotated in Preview as foto_mail.png in PNG",
         "remaining":"Export the photo already rotated in Preview as foto_mail.png in PNG",
         "inputs":[{"name":"output_name","value":"foto_mail","role":"name of the exported file without extension"},
                   {"name":"output_extension","value":"png","role":"extension of the exported file"},
                   {"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"},
                   {"name":"document","value":"foto_demo.png","kind":"file","source":"previous_output","source_ref":"task-1/exported"}]}
        """#

    /// Learns the quality corpus through the tools with the Recall of `channel`, applies its later changes and waits
    /// for the index; answers the photo export's current version.
    static func learnCorpus(_ session: LearningSession, channel: RecallConfiguration.Channel) async throws -> String {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: configuration(channel)))
        let corpus = try RecallCorpus.load()
        var learned = try await corpus.learn(into: session.directory)
        try await corpus.applyChanges(to: &learned, in: session.directory)
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(120)))
        return try #require(learned["photo-export"]).current
    }

    /// The request as first written for this cycle, worded away from the learned labels.
    static let originalExportRequest = #"""
        {"operation":"begin","goal":"Export the photo already rotated in Preview as foto_mail.png in PNG",
         "remaining":"Export the document already open and edited in Preview as a PNG file named foto_mail",
         "inputs":[{"name":"output_name","value":"foto_mail","role":"name of the exported file without extension"},
                   {"name":"output_extension","value":"png","role":"extension of the exported file"},
                   {"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"},
                   {"name":"document","value":"foto_demo.png","kind":"file","source":"previous_output","source_ref":"task-1/exported"}]}
        """#

    static func exportCycle(channel: RecallConfiguration.Channel) async throws {
        let session = P.photoSession(try W.directory())
        let routeID = try await learnCorpus(session, channel: channel)
        let memory = await reopen(session, channel: channel)

        // A new task: the photo is ready in Preview; only the export remains, with other values.
        let tools = P.tools(session, stream: "worker-2")
        let begun = try await P.task(tools, exportRequest)
        let recall = begun["recall"]
        #expect(recall["search"]["status"].string == "completed", "\(recall)")
        #expect(recall["coverage"].string == "complete", "\(recall)")
        let selection = recall["needs"].array?.first?["selection"] ?? .null
        #expect(selection["version"].string == routeID)
        let steps = selection["steps"].array?.compactMap { Self.int($0["step"]) }
        #expect(steps == [4, 5, 6, 7], "the export tract only: open the dialog, name, format, confirm; got \(recall)")
        #expect(selection["steps"].array?.first?["tool"].string == "menu")
        let parameters = selection["parameters"].array ?? []
        let name = parameters.first { $0["name"].string == "output_name" }
        #expect(name?["value"].string == "foto_mail" && name?["status"].string == "bound", "the new value, never the learned one: \(parameters)")
        #expect(!"\(recall)".contains("foto_web"), "no value of the learned episode is delivered")
        #expect(selection["conditions"].array?.contains { $0["kind"].string == "compatibility_unknown" } == true,
                "PNG was never chosen in the source: its compatibility is to check")

        // The agent carries out the tract with the task's values, then reports and ends.
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"foto_mail.png"}"#)
        _ = try await P.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"PNG"}"#)
        _ = try await P.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let query = try #require(recall["query"].string)
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","outputs":[{"name":"exported","value":"foto_mail.png","kind":"file"}],
             "use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first)
        #expect(used["steps_carried_out"].array?.compactMap { Self.int($0) } == [4, 5, 6, 7], "\(ended)")
        #expect(used["verified"].array?.count == 4)
        #expect(Self.int(used["own_operations"]) == 0)

        // Independent check of the rows: the query, its selection, the links to the new calls, the declared use.
        let file = session.directory.appendingPathComponent("memory.sqlite")
        #expect(try rawRows("SELECT reason || ':' || coverage || ':' || delivery FROM memory_recall_queries", at: file)
                == ["initial:complete:delivered"])
        #expect(try rawRows("SELECT first_position || '-' || last_position FROM memory_recall_selections WHERE role = 'selected'", at: file)
                == ["3-6"])
        #expect(try rawRows("SELECT count(*) FROM memory_recall_links WHERE confirmed = 1", at: file) == ["4"])
        #expect(try rawRows("SELECT declared FROM memory_recall_reports", at: file) == ["followed"])
        #expect(try rawRows("SELECT count(*) FROM memory_recall_requirements WHERE kind = 'parameter_bound'", at: file) == ["3"])
        let source = try await memory.perform { try await $0.procedures.version(routeID) }
        #expect(source?.qualifications.values.allSatisfy { $0.verdict == .admitted } == true, "the source's qualification is untouched")
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("the chosen lexical channel: after reopening, a new export request gets the export tract with new values and its use is linked")
    func lexicalExportCycle() async throws {
        try await Self.exportCycle(channel: .lexical)
    }

    @Test("the hybrid channel on the real local model, tied with the chosen one: the same cycle",
          .enabled(if: models != nil, "BRAUS_RECALL_MODELS names no folder of the pinned models"))
    func hybridExportCycle() async throws {
        try await Self.exportCycle(channel: .hybrid)
    }

    /// The export request with another wording, the photo export's inputs unchanged.
    static func exportRequest(_ remaining: String) -> String {
        originalExportRequest.replacingOccurrences(of: "Export the document already open and edited in Preview as a PNG file named foto_mail",
                                                   with: remaining)
    }

    /// Learns the photo export alone, reopens the archive and begins a new export task with `request` under `channel`.
    static func firstLearned(_ request: String, channel: RecallConfiguration.Channel) async throws -> JSONValue {
        let session = P.photoSession(try W.directory())
        _ = try await Self.learn(session, channel: channel)
        let memory = await Self.reopen(session, channel: channel)
        let begun = try await P.task(P.tools(session, stream: "worker-2"), request)
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(session.directory)
        return begun
    }

    static func steps(_ begun: JSONValue) -> [Int] {
        (begun["recall"]["needs"].array?.first?["selection"]["steps"].array ?? []).compactMap { Self.int($0["step"]) }
    }

    @Test("the first learned procedure already helps: after reopening an archive of one procedure, the review's request gets the export tract with new values, with the product's configuration")
    func firstLearnedProcedureIsRecalled() async throws {
        let begun = try await Self.firstLearned(Self.exportRequest, channel: RecallConfiguration.chosen.channel)
        // The product's channel is hybrid: without the model's files the lexical index answers, and the search says so.
        let search = begun["recall"]["search"]
        if Self.models == nil {
            #expect(search["status"].string == "limited" && search["channel"].string == "lexical", "\(search)")
            #expect(search["note"].string?.contains("the semantic index is unavailable") == true, "\(search)")
        } else {
            #expect(search["status"].string == "completed" && search["channel"].string == "hybrid", "\(search)")
        }
        #expect(begun["recall"]["coverage"].string == "complete", "the first learned procedure should already help: \(begun)")
        #expect(Self.steps(begun) == [4, 5, 6, 7], "the export, neither the search nor the rotation done before")
    }

    @Test("the original wording and paraphrases of the first learned case, on the semantic model (Granite, hybrid at its frozen thresholds)",
          .enabled(if: models != nil, "BRAUS_RECALL_MODELS names no folder of the pinned models"),
          arguments: ["Export the document already open and edited in Preview as a PNG file named foto_mail",
                      "Save the picture I just edited in Preview as a PNG called foto_mail",
                      "esporta l'immagine edited in PNG, name foto_mail"])
    func firstLearnedWordingsOnTheModel(_ remaining: String) async throws {
        let begun = try await Self.firstLearned(Self.exportRequest(remaining), channel: .hybrid)
        #expect(begun["recall"]["search"]["channel"].string == "hybrid", "\(begun["recall"]["search"])")
        let expected = Self.unaccountedVerbs[remaining] ?? []
        #expect(begun["recall"]["coverage"].string == (expected.isEmpty ? "complete" : "partial"), "\(begun)")
        #expect(begun["recall"]["needs"].array?.first?["unaccounted"].array?.compactMap(\.string) ?? [] == expected, "\(begun)")
        #expect(Self.steps(begun) == [4, 5, 6, 7])
    }

    /// The wordings whose clause leads with a verb the version knows nowhere (selector 4, review F11): the need is partial
    /// and names the verb, with the same tract. "edited as …" is such a clause, and so is the Italian "esporta"; the other
    /// wording's verbs are all the version's. Until selector 3 these were complete.
    static let unaccountedVerbs: [String: [String]] = [
        "Export the document already open and edited in Preview as a PNG file named foto_mail": ["edited"],
        "esporta l'immagine edited in PNG, name foto_mail": ["esporta"],
    ]

    @Test("a known limit of the provisional lexical configuration: the original wording of the first learned case is found absent, never wrongly answered")
    func firstLearnedOriginalWordingLexically() async throws {
        let begun = try await Self.firstLearned(Self.originalExportRequest, channel: .lexical)
        #expect(begun["recall"]["search"]["status"].string == "completed")
        #expect(begun["recall"]["coverage"].string == "absent", "\(begun)")
    }

    /// The lexical scores of every part of the photo export for `texts`, by the part's document, in an archive holding
    /// only that procedure or the whole corpus, under `weighting`.
    static func photoScores(corpus: Bool, weighting: LexicalIndex.Weighting, texts: [String]) async throws -> [String: [Double]] {
        let session = P.photoSession(try W.directory())
        var configuration = Self.configuration(.lexical)
        configuration.lexicalWeighting = weighting
        if corpus {
            let memory = MemoryService.shared(for: session.directory)
            RecallService.install(RecallService(memory: memory, configuration: configuration))
            var learned = try await RecallCorpus.load().learn(into: session.directory)
            try await RecallCorpus.load().applyChanges(to: &learned, in: session.directory)
            _ = await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(120))
        }
        let route = try await Self.learn(session, channel: .lexical)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        var scores: [String: [Double]] = [:]
        for text in texts {
            let (_, parts) = try await service.explain(text, limit: 1_000_000)
            for part in parts where part.partID.hasPrefix(route) { scores[part.text, default: []].append(part.lexical) }
        }
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(session.directory)
        return scores
    }

    @Test("a part's lexical score does not depend on the rest of the archive under the uniform and the version weightings; it does under the collection's")
    func scoresIndependentOfTheArchive() async throws {
        // A positive (the export) and a close negative (a rename of a file in Finder), searched as the service masks them.
        let texts = ["Export the photo already rotated in Preview as <output_name>.<output_extension> in <output_extension>",
                     "Rename the file <file_name> to <new_name> in Finder"]
        for weighting in [LexicalIndex.Weighting.uniform, .version] {
            let alone = try await Self.photoScores(corpus: false, weighting: weighting, texts: texts)
            let among = try await Self.photoScores(corpus: true, weighting: weighting, texts: texts)
            let differing = "\(alone.filter { among[$0.key] != $0.value }) against \(among.filter { alone[$0.key] != $0.value })"
            #expect(!alone.isEmpty && alone == among, "\(weighting): the same part scores the same among nineteen other procedures: \(differing)")
        }
        let alone = try await Self.photoScores(corpus: false, weighting: .collection, texts: texts)
        let among = try await Self.photoScores(corpus: true, weighting: .collection, texts: texts)
        #expect(alone != among, "the collection's weighting moves with the archive: the cause of review F01")
    }
}

/// RecallScoresProbe prints the scores of the learned photo export's parts for a few texts. A diagnostic of the
/// channels' scales, run with `BRAUS_RECALL_PROBE=1`; it asserts nothing about relevance.
@MainActor
@Suite("Recall scores of a learned procedure, printed for diagnosis", .serialized)
struct RecallScoresProbe {

    @Test("scores per channel", .enabled(if: ProcessInfo.processInfo.environment["BRAUS_RECALL_PROBE"] == "1", "BRAUS_RECALL_PROBE=1 asks for it"))
    func scores() async throws {
        for channel in [RecallConfiguration.Channel.lexical, .semantic, .hybrid] where channel == .lexical || RecallCycleTests.models != nil {
            let session = ProcedureLearningTests.photoSession(try W.directory())
            _ = try await RecallCycleTests.learn(session, channel: channel)
            let memory = MemoryService.shared(for: session.directory)
            let status = try await RecallService.shared(for: memory).status()
            print("PROBE status \(channel) worker=\(status.workerFailure ?? "-") model=\(status.modelFailure ?? "-") index=\(status.index)")
            for text in ["Export the photo already rotated in Preview as <output_name>.<output_extension> in <output_extension>",
                         "Export the document already open and edited in Preview as a PNG file named foto_mail",
                         "Esporta la foto già ruotata in PNG", "Find a file in Finder and rotate it", "Send an email with the report"] {
                let (used, parts) = try await RecallService.shared(for: memory).explain(text, limit: 14)
                print("PROBE \(channel) used=\(used) text=\(text)")
                for part in parts {
                    print(String(format: "PROBE   %.3f sem=%@ lex=%.3f %@ %@", part.combined, part.semantic.map { String(format: "%.3f", $0) } ?? "-",
                                 part.lexical, part.kind.rawValue, part.text))
                }
            }
            await memory.close()
            MemoryService.forget(session.directory)
        }
    }
}
