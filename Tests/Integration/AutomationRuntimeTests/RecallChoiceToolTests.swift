//
//  RecallChoiceToolTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// RecallChoiceToolTests prove the Recall by the agent's choice, the product's one path, through `memory_task` and SQLite, on
/// the photo export learned through the tools: offered with no flag, the automatic selector only under its control; a
/// proposal recorded and never delivered as a plan; a valid plan admitted,
/// recorded with its query and delivered tract by tract; a plan given again answered unchanged and another refused; a
/// refusal that records nothing; a proposal stale after a revision, unknown after a resumption, refused for a part retired or
/// a version superseded since; and the calls that follow linked to the tract they carried out, each once, the version's
/// confirmed reuses counting only a tract wholly carried out; and a producer and its consumer chosen as two tracts of one
/// version, recorded and delivered with the producer named in the earlier tract. The plans are written by the test: they
/// prove the contract, not what an agent chooses.
@MainActor
@Suite("The agent's choice through the tool", .serialized)
struct RecallChoiceToolTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    static let proposeRequest = #"""
        {"operation":"begin","goal":"Export the photo already rotated in Preview as foto_mail.png in PNG","recall_mode":"propose",
         "remaining":"Export the photo already rotated in Preview as foto_mail.png in PNG",
         "inputs":[{"name":"output_name","value":"foto_mail","role":"name of the exported file without extension"},
                   {"name":"output_extension","value":"png","role":"extension of the exported file"},
                   {"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"}]}
        """#

    static func choose(_ proposal: String, _ tracts: [(String, Int, Int)], covered: String = "all") -> String {
        let list = tracts.map { #"{"source":"\#($0.0)","from":\#($0.1),"to":\#($0.2)}"# }.joined(separator: ",")
        return #"{"operation":"choose","proposal":"\#(proposal)","plan":[{"need":1,"tracts":[\#(list)],"covered":"\#(covered)"}]}"#
    }

    /// The photo export learned, and a tool of another stream that proposed for the export task:
    /// the session, the tool, the proposal's id, the version's id and its name in the proposal.
    static func proposed() async throws -> (LearningSession, AutomationTools, String, String, String) {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        let tools = P.tools(session, stream: "chooser")
        let begun = try await P.task(tools, proposeRequest)
        let proposal = begun["recall_proposal"]
        let id = try #require(proposal["proposal"].string, "\(begun)")
        let key = try #require(proposal["sources"].array?.first { $0["version"].string == routeID }?["source"].string, "\(proposal)")
        return (session, tools, id, routeID, key)
    }

    static var definition: JSONValue { AutomationTools.definitions.first { $0["name"].string == "memory_task" } ?? .null }

    static func count(_ table: String, _ session: LearningSession, _ condition: String = "1") throws -> Int {
        Int(try P.rows("SELECT count(*) FROM \(table) WHERE \(condition)", in: session).first ?? "0") ?? 0
    }

    @Test("the agent's choice is the product's one path: described and accepted with no flag, begin answers a proposal, only the selector's control answers a selection")
    func theOnePath() async throws {
        let properties = Self.definition["inputSchema"]["properties"]
        #expect("\(properties["operation"])".contains("choose") && properties["proposal"] != .null && properties["plan"] != .null)
        #expect(properties["recall_mode"] == .null, "no mode is offered: there is one search")
        let instructions = AutomationTools.instructions
        #expect(instructions.contains("recall_proposal") && instructions.contains("memory_task choose"))
        #expect(!instructions.contains("recall_mode") && !instructions.contains("Experiment"))
        #expect(instructions.contains("When the\n    proposal lists no source") || instructions.contains("proposal lists no source"))
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await L.learnPhoto(session)
        let plain = Self.proposeRequest.replacingOccurrences(of: #""recall_mode":"propose","#, with: "")
        let begun = try await P.task(P.tools(session, stream: "plain"), plain)
        #expect(begun["recall"] == .null && begun["recall_proposal"]["sources"].array?.contains { $0["version"].string == routeID } == true,
                "\(begun)")
        let compatible = try await P.task(P.tools(session, stream: "compatible"), Self.proposeRequest)
        #expect(compatible["recall_proposal"]["proposal"].string != nil, "recall_mode propose is accepted and changes nothing")
        let refused = try await P.tools(session, stream: "other").call("memory_task",
                                                                       P.json(Self.proposeRequest.replacingOccurrences(of: "propose", with: "select")))
        #expect(refused["isError"] == .bool(true) && "\(refused.payload)".contains("recall_mode is propose"), "\(refused.payload)")
        try await RecallSelectionControl.$automatic.withValue(true) {
            let control = try await P.task(P.tools(session, stream: "control"), plain)
            #expect(control["recall"]["query"].string != nil && control["recall_proposal"] == .null, "\(control)")
        }
        await L.close(session)
    }

    @Test("a proposal is recorded and delivers no plan; a valid choice is recorded with its query and delivered; given again, answered unchanged")
    func proposeAndChoose() async throws {
        do {
            let (session, tools, id, routeID, key) = try await Self.proposed()
            let proposals = try Self.count("memory_recall_proposals", session), queries = try Self.count("memory_recall_queries", session)
            #expect(proposals == 1 && queries == 0, "a proposal is not a query")
            let lines = try P.rows("SELECT count(*) FROM memory_recall_proposal_sources WHERE route_id = '\(routeID)'", in: session)
            #expect(lines == ["1"])
            let chosen = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            #expect(chosen["status"].string == "chosen", "\(chosen)")
            let need = try #require(chosen["recall"]["needs"].array?.first)
            #expect(need["coverage"].string == "complete" && need["declared"].string == "all", "\(need)")
            #expect(need["tracts"].array?.first?["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } == [4, 5, 6, 7])
            #expect(try P.rows("SELECT selector_version || ':' || coverage FROM memory_recall_queries", in: session)
                    == ["recall-agent-choice-2:complete"])
            #expect(try P.rows("SELECT declared FROM memory_recall_choice_needs", in: session) == ["all"])
            #expect(try P.rows("SELECT first_position || '-' || last_position FROM memory_recall_selections WHERE role = 'selected'",
                               in: session) == ["3-6"])
            let again = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            #expect(again["status"].string == "already chosen" && again["recall"]["query"] == chosen["recall"]["query"], "\(again)")
            #expect(try Self.count("memory_recall_queries", session) == 1, "a choice given again records nothing new")
            let other = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 5, 7)])))
            #expect(other["isError"] == .bool(true) && "\(other.payload)".contains("proposal_already_chosen"), "\(other.payload)")
            await L.close(session)
        }
    }

    @Test("a refused plan records nothing and runs nothing; every problem is listed")
    func refusalRecordsNothing() async throws {
        do {
            let (session, tools, id, _, key) = try await Self.proposed()
            let calls = try Self.count("memory_agent_actions", session)
            let refused = try await tools.call("memory_task", P.json(Self.choose(id, [("s9", 4, 7), (key, 4, 40)])))
            #expect(refused["isError"] == .bool(true) && "\(refused.payload)".contains("invalid_plan"), "\(refused.payload)")
            let problems = refused.payload["problems"].array ?? []
            #expect(problems.count == 2, "\(refused.payload)")
            let queries = try Self.count("memory_recall_queries", session), choices = try Self.count("memory_recall_choices", session)
            #expect(queries == 0 && choices == 0)
            #expect(try Self.count("memory_agent_actions", session) == calls, "a refusal runs no operation")
            await L.close(session)
        }
    }

    @Test("a proposal is stale after a revision of the task and after a restart and resumption; another task's is unknown")
    func staleAndResumed() async throws {
        do {
            let (session, tools, id, _, key) = try await Self.proposed()
            _ = try await P.task(tools, #"{"operation":"update","goal":"Export the photo already rotated as foto_mail.png in PNG, quickly"}"#)
            let stale = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(stale["isError"] == .bool(true) && "\(stale.payload)".contains("stale_proposal"), "\(stale.payload)")
            // A restart: the producer's open task is gone; it resumes its task in a new attempt.
            let task = try #require(try await P.task(tools, #"{"operation":"status"}"#)["task"].string)
            let restarted = P.tools(session, stream: "chooser")
            #expect(try await P.task(restarted, #"{"operation":"resume","task":"\#(task)"}"#)["status"].string == "resumed")
            let resumed = try await restarted.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(resumed["isError"] == .bool(true) && "\(resumed.payload)".contains("stale_proposal"), "\(resumed.payload)")
            // Another task of the same producer cannot choose from it.
            _ = try await P.task(restarted, #"{"operation":"end","outcome":"abandoned"}"#)
            _ = try await P.task(restarted, #"{"operation":"begin","goal":"Another task","recall":false}"#)
            let other = try await restarted.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(other["isError"] == .bool(true) && "\(other.payload)".contains("unknown_proposal"), "\(other.payload)")
            #expect(try Self.count("memory_recall_queries", session) == 0)
            await L.close(session)
        }
    }

    @Test("a step retired, or the version superseded, between the proposal and the choice refuses the tract")
    func catalogueChangedBetween() async throws {
        do {
            let (session, tools, id, routeID, key) = try await Self.proposed()
            let memory = MemoryService.shared(for: session.directory)
            _ = try await memory.perform { try await $0.procedures.setState(.retired, of: "\(routeID)/step-5", reason: "the pop-up moved",
                                                                            by: "test", at: memory.clock.calendarMS()) }
            let retired = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(retired["isError"] == .bool(true) && "\(retired.payload)".contains("step 6 of \(key) is no longer offered"), "\(retired.payload)")
            await L.close(session)

            let (other, otherTools, otherID, _, otherKey) = try await Self.proposed()
            let candidate = try #require(try P.rows("SELECT candidate_id FROM memory_procedure_versions", in: other).first)
            let worker = P.tools(other, stream: "worker-1")
            let renamed = P.photoInterpretation(candidate).replacingOccurrences(of: "Confirm the export", with: "Save the exported image")
            #expect(try await P.task(worker, renamed)["status"].string == "interpreted")
            let superseded = try await otherTools.call("memory_task", P.json(Self.choose(otherID, [(otherKey, 4, 7)])))
            #expect(superseded["isError"] == .bool(true) && "\(superseded.payload)".contains("superseded"), "\(superseded.payload)")
            await L.close(other)
        }
    }

    @Test("two tracts of one version: the calls are linked to the tract they carried out, each once; a tract wholly carried out is a confirmed reuse, the other not")
    func feedbackPerTract() async throws {
        do {
            let (session, tools, id, routeID, key) = try await Self.proposed()
            let chosen = try await P.task(tools, Self.choose(id, [(key, 1, 2), (key, 4, 7)]))
            let need = try #require(chosen["recall"]["needs"].array?.first, "\(chosen)")
            #expect(need["tracts"].array?.count == 2)
            let query = try #require(chosen["recall"]["query"].string)
            let session_ = session.id!.uuidString
            _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
            _ = try await P.call(tools, "menu", #"{"session":"\#(session_)","path":"File > Export…"}"#)
            _ = try await P.call(tools, "type_text", #"{"session":"\#(session_)","target":"foto_demo.png","text":"foto_mail.png"}"#)
            _ = try await P.call(tools, "select", #"{"session":"\#(session_)","control":"Format","item":"PNG"}"#)
            _ = try await P.call(tools, "press", #"{"session":"\#(session_)","button":"Save"}"#)
            let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"adapted"}]}"#)
            let used = ended["recall_use"].array ?? []
            let second = used.first { RecallCycleTests.int($0["tract"]) == 2 }
            let first = used.first { RecallCycleTests.int($0["tract"]) == 1 }
            #expect(second?["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7], "\(ended)")
            #expect(first?["not_carried_out"].array?.compactMap { RecallCycleTests.int($0) } == [1, 2], "\(ended)")
            #expect(try P.rows("SELECT DISTINCT selection_position FROM memory_recall_choice_links WHERE step_position IS NOT NULL", in: session) == ["1"])
            #expect(try Self.count("memory_recall_links", session, "query_id = '\(query)'") == 0, "a choice's links name their tract")
            #expect(try P.rows("SELECT count(*) FROM memory_recall_choice_links GROUP BY call_event_id HAVING count(*) > 1", in: session).isEmpty)
            let memory = MemoryService.shared(for: session.directory)
            let source = try await memory.perform { try await $0.recall.sources([routeID]) }.first
            #expect(source?.confirmedUses == 1, "the export tract, wholly carried out and verified; not the Finder tract")
            await L.close(session)
        }
    }

    @Test("a producer and its consumer chosen as two tracts of one version, the unrelated download between left out: recorded, and delivered with the producer in the earlier tract")
    func producerInAnEarlierTract() async throws {
        // Found by the measure with a real agent: the agent chose exactly these tracts for a-relay-en, Engine admitted them,
        // and schema 6's check of a requirement's step refused to record the second tract's `input_produced`.
        let corpus = try RecallCorpus.load("recall-corpus-v4").restricted(to: ["report-relay"])
        let query = try #require(corpus.queries(split: "all").first { $0["id"].string == "a-relay-en" })
        let (base, learned) = try await RecallEvaluationTests.learnBase(corpus)
        let configuration = try #require(RecallEvaluationV2Tests.allConfigurations.first { $0.name == "lexical/recall-document-1/uniform" })
        let archive = try await RecallEvaluationTests.archive(from: base, learned: learned, corpus: corpus,
                                                              configuration: configuration.configuration(models: nil))
        let routeID = try #require(archive.learned["report-relay"]?.current)
        let session = LearningSession(directory: archive.directory)
        let tools = P.tools(session, source: .app, stream: "relay-chooser")
        guard case .object(var begin) = RecallCorpus.begin(query) else { Issue.record("no begin"); return }
        begin["recall_mode"] = .string("propose")
        do {
            let proposal = try await tools.call("memory_task", .object(begin)).payload["recall_proposal"]
            let id = try #require(proposal["proposal"].string, "\(proposal)")
            let key = try #require(proposal["sources"].array?.first { $0["version"].string == routeID }?["source"].string, "\(proposal)")
            let result = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 1, 4), (key, 7, 12)])))
            #expect(result["isError"] != .bool(true), "\(result.payload)")
            let need = try #require(result.payload["recall"]["needs"].array?.first, "\(result.payload)")
            let tracts = need["tracts"].array ?? []
            #expect(tracts.count == 2, "\(need)")
            let produced = tracts.last?["conditions"].array?.first { $0["kind"].string == "input_produced" }
            #expect(produced?["detail"].string?.contains("an earlier tract of this plan") == true, "\(tracts.last ?? .null)")
            let rows = try P.rows(
                "SELECT r.selection_position || ':' || r.step_position FROM memory_recall_requirements r "
                    + "JOIN memory_recall_queries q ON q.query_id = r.query_id WHERE q.selector_version = 'recall-agent-choice-2' "
                    + "AND r.kind = 'input_produced'", in: session)
            #expect(rows.count == 1 && rows.first.map { Int($0.split(separator: ":")[1]).map { $0 < 4 } ?? false } == true,
                    "the second tract's input names the producer's step in the first tract: \(rows)")
        }
        await RecallEvaluationTests.close(archive)
    }

    // MARK: Retries and recording faults (review of experiment A: F13, R2)

    /// The facts recorded for the query of a choice, as rows of text: what a retry must leave as they were.
    static func facts(_ session: LearningSession) throws -> [String] {
        try P.rows("SELECT query_id || ':' || task_revision || ':' || coverage FROM memory_recall_queries", in: session)
            + P.rows("SELECT query_id || ':' || position || ':' || route_id || ':' || first_position || '-' || last_position "
                     + "FROM memory_recall_selections ORDER BY query_id, need_position, position", in: session)
            + P.rows("SELECT query_id || ':' || selection_position || ':' || kind || ':' || ifnull(task_value_name, '') "
                     + "FROM memory_recall_requirements ORDER BY query_id, need_position, selection_position, position", in: session)
    }

    @Test("Replaying a chosen plan after task values change refuses it or returns its original receipt")
    func replayCannotRebindAnOldQuery() async throws {
        // The independent review's counterexample (F13), its body and expectations unchanged.
        typealias C = RecallChoiceToolTests
        do {
            let (session, tools, proposal, _, source) = try await C.proposed()
            let arguments = C.choose(proposal, [(source, 4, 7)])
            let first = try await P.task(tools, arguments)
            let firstNeed = try #require(first["recall"]["needs"].array?.first)
            let firstParameters = firstNeed["tracts"].array?.first?["parameters"] ?? .null
            _ = try await P.task(tools, #"{"operation":"update","goal":"Export the already rotated image as a different file","inputs":[{"name":"output_name","value":"changed_name","role":"name of the exported file without extension"},{"name":"output_extension","value":"png","role":"extension of the exported file"},{"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"}]}"#)
            let reply = try await tools.call("memory_task", P.json(arguments))
            if reply["isError"] == .bool(true) {
                #expect("\(reply.payload)".contains("stale_proposal"), "An explicit stale refusal is acceptable: \(reply.payload)")
            } else {
                let again = reply.payload
                let secondParameters = again["recall"]["needs"].array?.first?["tracts"].array?.first?["parameters"] ?? .null
                #expect(again["recall"]["query"] == first["recall"]["query"], "Replay must retain the original query")
                #expect(secondParameters == firstParameters,
                        "The same recorded query must not deliver new bindings. Original: \(firstParameters); replay: \(secondParameters)")
            }
            #expect(try C.count("memory_recall_queries", session) == 1)
            await L.close(session)
        }
    }

    @Test("a retry after a revision of the task is stale and records nothing; the chosen query's facts stay as recorded, also after reopening")
    func retryAfterRevisionIsStale() async throws {
        do {
            let (session, tools, id, _, key) = try await Self.proposed()
            _ = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            let recorded = try Self.facts(session)
            _ = try await P.task(tools, #"{"operation":"update","inputs":[{"name":"output_name","value":"changed_name","role":"name of the exported file without extension"},{"name":"output_extension","value":"png","role":"extension of the exported file"},{"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"}]}"#)
            let retry = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(retry["isError"] == .bool(true) && "\(retry.payload)".contains("stale_proposal"), "\(retry.payload)")
            #expect("\(retry.payload)".contains("revision"), "the refusal says why: \(retry.payload)")
            #expect(try Self.facts(session) == recorded, "nothing new, nothing changed")
            await L.close(session)
            #expect(try Self.facts(session) == recorded, "the same after reopening")
        }
    }

    @Test("a retry in the same revision answers the recorded receipt: the same query, the same bindings, no new fact")
    func retryInTheSameRevisionIsIdempotent() async throws {
        do {
            let (session, tools, id, _, key) = try await Self.proposed()
            let first = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            let recorded = try Self.facts(session)
            let again = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            #expect(again["status"].string == "already chosen", "\(again)")
            #expect(again["recall"]["query"] == first["recall"]["query"])
            #expect(again["recall"]["needs"] == first["recall"]["needs"], "the same tracts, bindings and conditions")
            #expect(try Self.facts(session) == recorded)
            await L.close(session)
        }
    }

    @Test("a retry after a step was retired or the version superseded is refused like a new choice; the recorded query stays")
    func retryAfterCatalogueChange() async throws {
        do {
            let (session, tools, id, routeID, key) = try await Self.proposed()
            _ = try await P.task(tools, Self.choose(id, [(key, 4, 7)]))
            let recorded = try Self.facts(session)
            let memory = MemoryService.shared(for: session.directory)
            _ = try await memory.perform { try await $0.procedures.setState(.retired, of: "\(routeID)/step-5", reason: "the pop-up moved",
                                                                            by: "test", at: memory.clock.calendarMS()) }
            let retry = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            #expect(retry["isError"] == .bool(true) && "\(retry.payload)".contains("no longer offered"), "\(retry.payload)")
            #expect(try Self.facts(session) == recorded)
            await L.close(session)
        }
    }

    @Test("a choice the archive cannot record is an internal error of the choice: nothing delivered or recorded, no app action to repeat, the memory not suspended")
    func choiceNotRecorded() async throws {
        do {
            let (session, tools, id, _, key) = try await Self.proposed()
            // A fault of the record, as the measure met one (R1): a check of the archive refuses the choice's row, so the
            // transaction that records the query and the choice rolls back.
            let raw = try SQLiteConnection(path: session.directory.appendingPathComponent("memory.sqlite").path)
            try raw.execute("CREATE TRIGGER test_record_fault BEFORE INSERT ON memory_recall_choices "
                            + "BEGIN SELECT RAISE(ABORT, 'a check of the test refuses the choice'); END")
            raw.close()
            let memory = MemoryService.shared(for: session.directory)
            let refused = try await tools.call("memory_task", P.json(Self.choose(id, [(key, 4, 7)])))
            let text = "\(refused.payload)"
            #expect(refused["isError"] == .bool(true) && text.contains("choice_not_recorded"), "\(text)")
            #expect(!text.contains("memory_unavailable") && !text.contains("App actions"), "\(text)")
            #expect(refused.payload["recall"] == .null, "nothing delivered")
            #expect(try Self.count("memory_recall_queries", session) == 0)
            #expect(await memory.status().suspended == nil, "a recall record is no essential fact: the memory is not suspended")
            await L.close(session)
        }
    }

    // MARK: Compatibility and ambiguity on the corpus (review of experiment A: R3, R4, R5)

    /// CorpusArchive is a lexical archive of corpus v4 restricted to some knowledge, to propose and choose on through the tool.
    @MainActor
    struct CorpusArchive {
        let archive: RecallEvaluationTests.Archive
        let session: LearningSession

        init(_ knowledge: Set<String>) async throws {
            let corpus = try RecallCorpus.load("recall-corpus-v4").restricted(to: knowledge)
            let (base, learned) = try await RecallEvaluationTests.learnBase(corpus)
            let configuration = try #require(RecallEvaluationV2Tests.allConfigurations.first { $0.name == "lexical/recall-document-1/uniform" })
            archive = try await RecallEvaluationTests.archive(from: base, learned: learned, corpus: corpus,
                                                             configuration: configuration.configuration(models: nil))
            session = LearningSession(directory: archive.directory)
        }

        /// Begins a task for `remaining` (with `inputs`) in a stream of its own and proposes: the tool, the proposal's id and
        /// the proposal's name of each knowledge item it shortlisted.
        func propose(_ remaining: String, inputs: String = "[]", stream: String) async throws -> (AutomationTools, String, [String: String]) {
            let tools = P.tools(session, source: .app, stream: stream)
            let text = remaining.replacingOccurrences(of: "\"", with: "\\\"")
            let begun = try await P.task(tools, #"{"operation":"begin","goal":"\#(text)","remaining":"\#(text)","recall_mode":"propose","inputs":\#(inputs)}"#)
            let proposal = begun["recall_proposal"]
            let id = try #require(proposal["proposal"].string, "\(begun)")
            var keys: [String: String] = [:]
            for source in proposal["sources"].array ?? [] {
                guard let version = source["version"].string, let key = source["source"].string,
                      let known = archive.learned.first(where: { $0.value.revisions.contains(version) })?.key else { continue }
                keys[known] = key
            }
            return (tools, id, keys)
        }

        func close() async { await RecallEvaluationTests.close(archive) }
    }

    static func plan(_ proposal: String, covered: String, tracts: [(String, Int, Int)] = [], alternatives: [(String, Int, Int)] = [],
                     uncovered: String? = nil, settledBy: String? = nil) -> String {
        func list(_ items: [(String, Int, Int)]) -> String {
            items.map { #"{"source":"\#($0.0)","from":\#($0.1),"to":\#($0.2)}"# }.joined(separator: ",")
        }
        var need = #""need":1,"tracts":[\#(list(tracts))],"covered":"\#(covered)""#
        if !alternatives.isEmpty { need += #","alternatives":[\#(list(alternatives))]"# }
        if let uncovered { need += #","uncovered":"\#(uncovered)""# }
        if let settledBy { need += #","settled_by":"\#(settledBy)""# }
        return #"{"operation":"choose","proposal":"\#(proposal)","plan":[{\#(need)}]}"#
    }

    static func choose(_ tools: AutomationTools, _ arguments: String) async throws -> JSONValue {
        try await tools.call("memory_task", P.json(arguments))
    }

    @Test("R3: tracts around a fixed choice the task contradicts are refused with its episode; an independent compatible episode of the same version stays reusable")
    func conflictTakesItsEpisode() async throws {
        let corpus = try await CorpusArchive(["numbers-sort-desc", "numbers-chart-mail", "keynote-slide-message"])
        // The sort fixes the descending order the task contradicts: leaving that step out does not make the sort ascending.
        let (sortTools, sort, sortKeys) = try await corpus.propose(
            "Sort the sales table by Region from A to Z",
            inputs: #"[{"name":"sort_column","value":"Region"},{"name":"sort_order","value":"Ascending","role":"order of the sort"}]"#, stream: "r3-sort")
        let sortKey = try #require(sortKeys["numbers-sort-desc"], "\(sortKeys)")
        let around = try await Self.choose(sortTools, Self.plan(sort, covered: "part", tracts: [(sortKey, 1, 2), (sortKey, 4, 4)],
                                                                uncovered: "the ascending order"))
        #expect(around["isError"] == .bool(true) && "\(around.payload)".contains("belongs to the work of step 3"), "\(around.payload)")
        // The chart's export fixes PNG where the task asks PDF; making the chart is an episode of its own, and is what the task needs.
        let (chartTools, chart, chartKeys) = try await corpus.propose(
            "Make a bar chart of the table and export it as a PDF named vendite_q4",
            inputs: #"[{"name":"chart_name","value":"vendite_q4"},{"name":"image_format","value":"PDF","role":"format of the exported file"}]"#,
            stream: "r3-chart")
        let chartKey = try #require(chartKeys["numbers-chart-mail"], "\(chartKeys)")
        let export = try await Self.choose(chartTools, Self.plan(chart, covered: "part", tracts: [(chartKey, 3, 4)], uncovered: "the PDF export"))
        #expect(export["isError"] == .bool(true) && "\(export.payload)".contains("belongs to the work of step 5"), "\(export.payload)")
        let made = try await Self.choose(chartTools, Self.plan(chart, covered: "part", tracts: [(chartKey, 1, 2)], uncovered: "the PDF export"))
        #expect(made["isError"] != .bool(true), "\(made.payload)")
        #expect(made.payload["recall"]["needs"].array?.first?["coverage"].string == "partial", "\(made.payload)")
        // The slide's export fixes PNG where the task asks JPEG; selecting the slide is a preparation of its own.
        let (slideTools, slide, slideKeys) = try await corpus.propose(
            "Export slide 2 of the presentation as a JPEG image named intro",
            inputs: #"[{"name":"slide_number","value":"2"},{"name":"image_name","value":"intro"},{"name":"image_format","value":"JPEG","role":"format of the image"}]"#,
            stream: "r3-slide")
        let slideKey = try #require(slideKeys["keynote-slide-message"], "\(slideKeys)")
        let split = try await Self.choose(slideTools, Self.plan(slide, covered: "part", tracts: [(slideKey, 1, 2), (slideKey, 4, 5)],
                                                                uncovered: "JPEG"))
        #expect(split["isError"] == .bool(true) && "\(split.payload)".contains("belongs to the work of step 3"), "\(split.payload)")
        let selected = try await Self.choose(slideTools, Self.plan(slide, covered: "part", tracts: [(slideKey, 1, 1)],
                                                                   uncovered: "the JPEG export"))
        #expect(selected.payload["recall"]["needs"].array?.first?["coverage"].string == "partial", "\(selected.payload)")
        // The near positive: the same version's chart, asked alone, is complete.
        let (aloneTools, alone, aloneKeys) = try await corpus.propose("Make a bar chart of the sales table", stream: "r3-alone")
        let aloneKey = try #require(aloneKeys["numbers-chart-mail"], "\(aloneKeys)")
        let whole = try await Self.choose(aloneTools, Self.plan(alone, covered: "all", tracts: [(aloneKey, 1, 2)]))
        #expect(whole.payload["recall"]["needs"].array?.first?["coverage"].string == "complete", "\(whole.payload)")
        await corpus.close()
    }

    @Test("R5: variants with a different fixed choice need it settled (task value, request's words, or a quotation of them); otherwise the need is answered ambiguous, recorded and delivered with no tract to run")
    func variantsNeedTheirChoiceSettled() async throws {
        let corpus = try await CorpusArchive(["print-all-pages", "print-current-page", "pages-export-pdf", "pages-export-word"])
        // "Print the open PDF": which pages is the person's choice.
        let (tools, id, keys) = try await corpus.propose("Print the open PDF", stream: "r5-print")
        let all = try #require(keys["print-all-pages"], "\(keys)"), current = try #require(keys["print-current-page"], "\(keys)")
        let picked = try await Self.choose(tools, Self.plan(id, covered: "all", tracts: [(all, 1, 3)]))
        #expect(picked["isError"] == .bool(true) && "\(picked.payload)".contains("different fixed choice"), "\(picked.payload)")
        let unquoted = try await Self.choose(tools, Self.plan(id, covered: "all", tracts: [(all, 1, 3)], settledBy: "every page please"))
        #expect(unquoted["isError"] == .bool(true) && "\(unquoted.payload)".contains("settled_by is not words of the request"), "\(unquoted.payload)")
        // The measure's smoke met the request quoted whole as if it stated the choice: it states none.
        let whole = try await Self.choose(tools, Self.plan(id, covered: "all", tracts: [(all, 1, 3)], settledBy: "Print the open PDF"))
        #expect(whole["isError"] == .bool(true) && "\(whole.payload)".contains("quotes the whole request"), "\(whole.payload)")
        let asked = try await Self.choose(tools, Self.plan(id, covered: "ambiguous", alternatives: [(all, 1, 3), (current, 1, 3)],
                                                           uncovered: "Print every page or only the current one?"))
        #expect(asked["isError"] != .bool(true), "\(asked.payload)")
        let need = try #require(asked.payload["recall"]["needs"].array?.first, "\(asked.payload)")
        #expect(need["coverage"].string == "ambiguous" && need["reason"].string == "alternatives" && need["declared"].string == "ambiguous")
        #expect(need["tracts"].array?.isEmpty == true && need["alternatives"].array?.count == 2, "\(need)")
        let query = try #require(asked.payload["recall"]["query"].string)
        #expect(try P.rows("SELECT role FROM memory_recall_selections WHERE query_id = '\(query)' ORDER BY position", in: corpus.session)
                == ["alternative", "alternative"])
        #expect(try P.rows("SELECT coverage || ':' || reason FROM memory_recall_needs WHERE query_id = '\(query)'", in: corpus.session)
                == ["ambiguous:alternatives"])
        #expect(try P.rows("SELECT declared FROM memory_recall_choice_needs WHERE query_id = '\(query)'", in: corpus.session) == ["ambiguous"])
        let again = try await Self.choose(tools, Self.plan(id, covered: "ambiguous", alternatives: [(all, 1, 3), (current, 1, 3)],
                                                           uncovered: "Print every page or only the current one?"))
        #expect(again.payload["status"].string == "already chosen" && again.payload["recall"]["query"].string == query, "\(again.payload)")
        // The request's words settle it.
        let (wordsTools, words, wordsKeys) = try await corpus.propose("Print all the pages of the open PDF", stream: "r5-words")
        let named = try await Self.choose(wordsTools, Self.plan(words, covered: "all", tracts: [(try #require(wordsKeys["print-all-pages"]), 1, 3)]))
        #expect(named.payload["recall"]["needs"].array?.first?["coverage"].string == "complete", "\(named.payload)")
        // In another language the agent quotes the person's words; Engine checks they are the request's.
        let (itTools, it, itKeys) = try await corpus.propose("Stampa soltanto la pagina che sto leggendo del PDF aperto", stream: "r5-it")
        let itCurrent = try #require(itKeys["print-current-page"], "\(itKeys)")
        let bare = try await Self.choose(itTools, Self.plan(it, covered: "all", tracts: [(itCurrent, 1, 3)]))
        #expect(bare["isError"] == .bool(true) && "\(bare.payload)".contains("different fixed choice"), "\(bare.payload)")
        let quoted = try await Self.choose(itTools, Self.plan(it, covered: "all", tracts: [(itCurrent, 1, 3)],
                                                              settledBy: "soltanto la pagina che sto leggendo"))
        let quotedNeed = quoted.payload["recall"]["needs"].array?.first
        #expect(quotedNeed?["coverage"].string == "complete" && quotedNeed?["settledBy"].string == "soltanto la pagina che sto leggendo",
                "\(quoted.payload)")
        let settledQuery = try #require(quoted.payload["recall"]["query"].string)
        #expect(try P.rows("SELECT settled_by FROM memory_recall_choice_needs WHERE query_id = '\(settledQuery)'", in: corpus.session)
                == ["soltanto la pagina che sto leggendo"])
        // A task value naming the other variant's choice is a contradiction; naming this one settles it.
        let (valueTools, value, valueKeys) = try await corpus.propose("Print the open PDF", inputs: #"[{"name":"pages","value":"All"}]"#,
                                                                     stream: "r5-value")
        let wrong = try await Self.choose(valueTools, Self.plan(value, covered: "all", tracts: [(try #require(valueKeys["print-current-page"]), 1, 3)]))
        #expect(wrong["isError"] == .bool(true), "\(wrong.payload)")
        #expect("\(wrong.payload)".contains("values name"), "\(wrong.payload)")
        let right = try await Self.choose(valueTools, Self.plan(value, covered: "all", tracts: [(try #require(valueKeys["print-all-pages"]), 1, 3)]))
        #expect(right.payload["recall"]["needs"].array?.first?["coverage"].string == "complete", "\(right.payload)")
        // A format the request leaves open, and one it names.
        let (openTools, open, openKeys) = try await corpus.propose("Export the open Pages document as relazione_x",
                                                                   inputs: #"[{"name":"output_name","value":"relazione_x"}]"#, stream: "r5-open")
        let pdf = try await Self.choose(openTools, Self.plan(open, covered: "all", tracts: [(try #require(openKeys["pages-export-pdf"]), 1, 4)]))
        #expect(pdf["isError"] == .bool(true), "\(openKeys) \(pdf.payload)")
        #expect("\(pdf.payload)".contains("different fixed choice"), "\(pdf.payload)")
        let (formatTools, format, formatKeys) = try await corpus.propose("Esporta il documento di Pages in PDF con nome relazione_finale",
                                                                         inputs: #"[{"name":"output_name","value":"relazione_finale"}]"#, stream: "r5-format")
        let chosenPDF = try await Self.choose(formatTools, Self.plan(format, covered: "all", tracts: [(try #require(formatKeys["pages-export-pdf"]), 1, 4)]))
        #expect(chosenPDF.payload["recall"]["needs"].array?.first?["coverage"].string == "complete", "\(chosenPDF.payload)")
        await corpus.close()
    }

    // MARK: The evidence of a choice and the role of the data (review of the corrections: F14)

    @Test("A filename Word does not establish the export format Word")
    func filenameIsNotFormat() async throws {
        // The review's counterexample (F14), its body and expectations unchanged.
        typealias C = RecallChoiceToolTests
        let corpus = try await C.CorpusArchive(["pages-export-pdf", "pages-export-word"])
        let (tools, proposal, keys) = try await corpus.propose(
            "Export the open Pages document with the filename Word; the output format is still undecided",
            inputs: #"[{"name":"output_name","value":"Word","role":"filename of the exported document, not its format"}]"#,
            stream: "independent-data-role")
        let word = try #require(keys["pages-export-word"])
        let result = try await C.choose(tools, C.plan(proposal, covered: "all", tracts: [(word, 1, 4)]))
        #expect(result["isError"] == .bool(true),
                "A data value naming the file must not settle a functional format choice: \(result.payload)")
        await corpus.close()
    }

    @Test("An unrelated input value Word does not settle a missing export format")
    func unrelatedValueIsNotFormat() async throws {
        // The review's counterexample (F14), its body and expectations unchanged.
        typealias C = RecallChoiceToolTests
        let corpus = try await C.CorpusArchive(["pages-export-pdf", "pages-export-word"])
        let (tools, proposal, keys) = try await corpus.propose(
            "Export the open Pages document with the filename relazione_x; the output format is still undecided",
            inputs: #"[{"name":"output_name","value":"relazione_x"},{"name":"customer_code","value":"Word","role":"customer code, not an export format"}]"#,
            stream: "independent-unrelated-role")
        let word = try #require(keys["pages-export-word"])
        let result = try await C.choose(tools, C.plan(proposal, covered: "all", tracts: [(word, 1, 4)]))
        #expect(result["isError"] == .bool(true),
                "An input of another role must not settle the output format: \(result.payload)")
        await corpus.close()
    }

    @Test("an explicit role paraphrase remains unresolved even with an exact name and never supplies a historical value")
    func roleParaphraseRemainsUnresolved() async throws {
        let corpus = try await CorpusArchive(["pages-export-pdf", "pages-export-word"])
        let (tools, proposal, keys) = try await corpus.propose(
            "Export the open Pages document to PDF with the filename Word",
            inputs: #"[{"name":"output_name","value":"Word","role":"filename of the exported document"}]"#,
            stream: "role-paraphrase")
        let answer = try await Self.choose(tools, Self.plan(
            proposal, covered: "all", tracts: [(try #require(keys["pages-export-pdf"]), 1, 4)]
        ))
        #expect(answer["isError"] != .bool(true), "\(answer.payload)")
        let need = try #require(answer.payload["recall"]["needs"].array?.first)
        #expect(need["coverage"].string == "ambiguous" && need["reason"].string == "unresolved_input", "\(need)")
        let tract = try #require(need["tracts"].array?.first)
        let parameter = try #require(tract["parameters"].array?.first { $0["name"].string == "output_name" })
        #expect(parameter["role"].string == "name of the exported file")
        #expect(parameter["status"].string == "missing" && parameter["value"] == .null, "\(parameter)")
        #expect(parameter["from"] == .null && parameter["producedBy"] == .null, "\(parameter)")
        let nameStep = try #require(tract["steps"].array?.first { RecallCycleTests.int($0["step"]) == 3 })
        let text = try #require(nameStep["arguments"].array?.first { $0["name"].string == "text" })
        #expect(text["kind"].string == "parameter" && text["value"].string == "{output_name}", "\(nameStep)")
        await corpus.close()
    }

    @Test("F14 paired: a choice is settled by the request's words or a value named for it, never by data; a refused plan records and delivers nothing")
    func choiceEvidenceFollowsTheRole() async throws {
        let corpus = try await CorpusArchive(["pages-export-pdf", "pages-export-word", "print-all-pages", "print-current-page"])
        func coverage(_ answer: JSONValue) -> String? { answer.payload["recall"]["needs"].array?.first?["coverage"].string }
        func queries() throws -> Int { Int(try P.rows("SELECT count(*) FROM memory_recall_queries", in: corpus.session).first ?? "0") ?? 0 }
        // The request names Word as the format: settled.
        let (wordTools, wordID, wordKeys) = try await corpus.propose("Export the open Pages document to Word as relazione_v3",
                                                                     inputs: #"[{"name":"output_name","value":"relazione_v3"}]"#, stream: "f14-word")
        let named = try await Self.choose(wordTools, Self.plan(wordID, covered: "all", tracts: [(try #require(wordKeys["pages-export-word"]), 1, 4)]))
        #expect(coverage(named) == "complete", "\(named.payload)")
        // PDF asked, the file named Word: PDF is settled, Word is not.
        let (pdfTools, pdfID, pdfKeys) = try await corpus.propose(
            "Export the open Pages document to PDF with the filename Word",
            inputs: #"[{"name":"output_name","value":"Word","role":"name of the exported file"}]"#, stream: "f14-pdf")
        let before = try queries()
        let wrongWord = try await Self.choose(pdfTools, Self.plan(pdfID, covered: "all", tracts: [(try #require(pdfKeys["pages-export-word"]), 1, 4)]))
        #expect(wrongWord["isError"] == .bool(true) && "\(wrongWord.payload)".contains("different fixed choice"), "\(wrongWord.payload)")
        #expect(try queries() == before, "a refused plan records no query")
        let pdf = try await Self.choose(pdfTools, Self.plan(pdfID, covered: "all", tracts: [(try #require(pdfKeys["pages-export-pdf"]), 1, 4)]))
        #expect(coverage(pdf) == "complete", "\(pdf.payload)")
        let pdfQuery = try #require(pdf.payload["recall"]["query"].string)
        #expect(try P.rows("SELECT coverage FROM memory_recall_queries WHERE query_id = '\(pdfQuery)'", in: corpus.session) == ["complete"])
        // An unrelated value spelling the other variant's word, also in the request, causes no false refusal.
        let (codeTools, codeID, codeKeys) = try await corpus.propose(
            "Export the open Pages document to PDF as relazione_y for the customer Word",
            inputs: #"[{"name":"output_name","value":"relazione_y"},{"name":"customer_code","value":"Word","role":"customer code"}]"#,
            stream: "f14-code")
        let code = try await Self.choose(codeTools, Self.plan(codeID, covered: "all", tracts: [(try #require(codeKeys["pages-export-pdf"]), 1, 4)]))
        #expect(coverage(code) == "complete", "\(code.payload)")
        // A value named for the choice that names the other option still excludes this one.
        let (formatTools, formatID, formatKeys) = try await corpus.propose(
            "Export the open Pages document as relazione_z",
            inputs: #"[{"name":"output_name","value":"relazione_z"},{"name":"export_format","value":"PDF","role":"format of the export"}]"#,
            stream: "f14-format")
        let contrary = try await Self.choose(formatTools, Self.plan(formatID, covered: "all", tracts: [(try #require(formatKeys["pages-export-word"]), 1, 4)]))
        #expect(contrary["isError"] == .bool(true) && "\(contrary.payload)".contains("values name"), "\(contrary.payload)")
        let settled = try await Self.choose(formatTools, Self.plan(formatID, covered: "all", tracts: [(try #require(formatKeys["pages-export-pdf"]), 1, 4)]))
        #expect(coverage(settled) == "complete", "\(settled.payload)")
        // The same rule on another family of choice: which pages to print.
        let (dataTools, dataID, dataKeys) = try await corpus.propose("Print the open PDF for the account All",
                                                                     inputs: #"[{"name":"account","value":"All"}]"#, stream: "f14-print-data")
        let dataPick = try await Self.choose(dataTools, Self.plan(dataID, covered: "all", tracts: [(try #require(dataKeys["print-all-pages"]), 1, 3)]))
        #expect(dataPick["isError"] == .bool(true) && "\(dataPick.payload)".contains("different fixed choice"), "\(dataPick.payload)")
        let (pagesTools, pagesID, pagesKeys) = try await corpus.propose("Print the open PDF", inputs: #"[{"name":"pages","value":"Current"}]"#,
                                                                       stream: "f14-print-pages")
        let pages = try await Self.choose(pagesTools, Self.plan(pagesID, covered: "all", tracts: [(try #require(pagesKeys["print-current-page"]), 1, 3)]))
        #expect(coverage(pages) == "complete", "\(pages.payload)")
        await corpus.close()
    }
}
