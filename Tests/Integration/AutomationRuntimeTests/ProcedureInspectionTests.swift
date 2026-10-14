//
//  ProcedureInspectionTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// ProcedureInspectionTests prove the diagnosis by id a developer reads with `braus memory --task`:
/// read only, from an archive the producers wrote through the tools, it describes the same objects as
/// the rows. The graph's containment, order and relation edges are the parts, the consecutive steps and
/// the relations the task's calls proved, counted by SQL; a batch and a skipped step are no step; a
/// state may lead to itself and no part contains itself; no value of a parameter is printed.
@MainActor
@Suite("A task read by its id: the graph and the rows describe the same objects", .serialized)
struct ProcedureInspectionTests {

    typealias Learning = ProcedureLearningTests

    static func archive(_ session: LearningSession) -> URL { session.directory.appendingPathComponent("memory.sqlite") }

    static func inspection(_ taskID: String, _ session: LearningSession) throws -> ProcedureInspection {
        guard case .found(let inspection) = SQLiteMemoryInspection.task(taskID, in: archive(session)) else {
            Issue.record("the task was not read")
            throw AutomationFailure("not read")
        }
        return inspection
    }

    static func count(_ sql: String, _ session: LearningSession) throws -> Int {
        Int(try Learning.rows(sql, in: session).first ?? "") ?? -1
    }

    /// The edges of a Mermaid graph by kind: containment `a --> b`, order `a -.-> b`, relation `a -- "…" --> b`.
    static func edges(_ graph: String) -> (containment: Int, order: Int, relations: [(String, String)]) {
        var containment = 0, order = 0
        var relations: [(String, String)] = []
        for line in graph.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let words = line.split(separator: " ")
            if line.contains(" -- \"") {
                relations.append((String(words.first ?? ""), String(words.last ?? "")))
            } else if words.count == 3, words[1] == "-->" {
                containment += 1
            } else if words.count == 3, words[1] == "-.->" {
                order += 1
            }
        }
        return (containment, order, relations)
    }

    @Test("the photo export read by its id: parts, steps and relations of the graph are the rows; the Finder state leads to itself; no part contains itself")
    func graphIsTheRows() async throws {
        let session = Learning.photoSession(try W.directory())
        session.script["act|Show Preview"] = LearningSession.Outcome(
            kind: .actedNoop,
            check: LearningSession.check(.requestedStateAlreadyPresent, method: .controlState, expected: "on", observed: "on",
                                         performed: .none, target: LearningSession.checkbox("Show Preview", state: .on))
        )
        let tools = Learning.tools(session)
        let begun = try await Learning.task(tools, #"""
            {"operation":"begin","goal":"Export the photo",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        let taskID = try #require(begun["task"].string)
        try await Learning.runPhotoExport(tools, session)
        let checkpoint = try await Learning.task(tools, #"{"operation":"checkpoint"}"#)
        let candidateID = try #require(checkpoint["candidate"]["id"].string)
        _ = try await Learning.task(tools, Learning.photoInterpretation(candidateID))
        _ = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(session.directory)

        let inspection = try Self.inspection(taskID, session)
        let attempt = try #require(Learning.rows("SELECT task_occurrence_id FROM memory_task_attempts WHERE task_id = '\(taskID)'",
                                                 in: session).first)
        let versions = "SELECT route_id FROM memory_procedure_versions WHERE task_occurrence_id = '\(attempt)'"
        let calls = "SELECT event_id FROM memory_task_events WHERE task_occurrence_id = '\(attempt)' AND role IN ('action', 'context')"
        // Counts: steps are the occurrences of the attempt; the other calls are context; no legacy Route.
        #expect(inspection.counts.operationalSteps
                == (try Self.count("SELECT count(*) FROM memory_step_occurrences WHERE task_occurrence_id = '\(attempt)'", session)))
        #expect(inspection.counts.operationalSteps == 8 && inspection.counts.containers == 0 && inspection.counts.skipped == 0)
        #expect(inspection.counts.contextCalls == (try Self.count("SELECT count(*) FROM (\(calls))", session)) - 8)
        #expect(inspection.counts.candidates == 1 && inspection.counts.versions == 1 && inspection.counts.legacyRoutes == 0)
        #expect(inspection.counts.admittedParts == 12 && inspection.counts.refusedParts == 0)
        // Edges: the model's, the graph's and the rows' agree.
        let containment = try Self.count("SELECT count(*) FROM memory_procedure_parts WHERE parent_part_id IS NOT NULL AND route_id IN (\(versions))", session)
        let order = try Self.count("""
            SELECT ifnull(sum(n - 1), 0) FROM (SELECT count(*) AS n FROM memory_procedure_parts
            WHERE part_kind = 'step' AND route_id IN (\(versions)) GROUP BY route_id)
            """, session)
        let relations = try Self.count("""
            SELECT count(DISTINCT relation_id) FROM brain_relation_evidence e WHERE call_event_id IN (\(calls))
              AND sequence = (SELECT max(v.sequence) FROM brain_relation_evaluations v WHERE v.call_event_id = e.call_event_id)
            """, session)
        #expect(containment == 11 && order == 7 && relations == 8, "the menu command and the dialog's button teach relations too")
        let model = inspection.edgeCounts
        #expect(model.containment == containment && model.order == order && model.relations == relations)
        let drawn = Self.edges(inspection.graph)
        #expect(drawn.containment == containment && drawn.order == order && drawn.relations.count == relations, "\(inspection.graph)")
        #expect(drawn.relations.contains { $0.0 == $0.1 }, "a no-op in Finder is a lawful self-loop of its state")
        // Containment has no cycle: every part reaches the procedure within its depth.
        #expect(try Self.count("""
            WITH RECURSIVE up(part_id, ancestor, depth) AS (
                SELECT part_id, parent_part_id, 1 FROM memory_procedure_parts WHERE route_id IN (\(versions))
                UNION ALL SELECT up.part_id, p.parent_part_id, depth + 1 FROM up JOIN memory_procedure_parts p ON p.part_id = up.ancestor
                WHERE depth < 10)
            SELECT count(*) FROM up WHERE ancestor = part_id OR depth > 3
            """, session) == 0)
        // The text names the same objects by id, and none of the bound values.
        let text = inspection.text.joined(separator: "\n")
        for id in try Learning.rows("SELECT part_id FROM memory_procedure_parts WHERE route_id IN (\(versions))", in: session) {
            #expect(text.contains("[\(id)]"), "part \(id) missing from the text")
        }
        #expect(!text.contains("foto_web") && !text.contains("JPEG\""), "the values stay in the bindings: \(text)")
        #expect(text.contains("parameter output_name input text required, role name of the exported file without extension"), "\(text)")
        #expect(text.contains("bound from request: held"))
        #expect(inspection.counts.offeredParts == 12)

        // Disabled without deleting: a step to evaluate again leaves the catalogue, a quarantined policy
        // takes everything it admitted out of it; every part, evaluation and version stays.
        let reopened = MemoryService.shared(for: session.directory)
        let step = try #require(inspection.attempts.first?.versions.first?.version.parts.first { $0.kind == .step }?.partID)
        _ = try await reopened.perform { try await $0.procedures.setState(.toReevaluate, of: step, reason: "review", by: "test", at: 1) }
        #expect(try await reopened.perform { try await $0.procedures.catalogue(limit: 100) }.count == 9,
                "the step, its block and the procedure that contain it leave the catalogue")
        _ = try await reopened.perform { try await $0.procedures.quarantine(policy: QualificationPolicy.version, reason: "review", at: 2) }
        #expect(try await reopened.perform { try await $0.procedures.catalogue(limit: 100) }.isEmpty)
        await reopened.close()
        MemoryService.forget(session.directory)
        let disabled = try Self.inspection(taskID, session)
        #expect(disabled.counts.offeredParts == 0 && disabled.counts.admittedParts == 12)
        #expect(disabled.text.contains { $0.contains("[\(step)]") && $0.contains("to_reevaluate, not offered") })
        #expect(try Self.count("SELECT count(*) FROM memory_procedure_parts WHERE route_id IN (\(versions))", session) == 12)
    }

    @Test("a batch stopped at its second step: the batch is a container, the skipped step is listed and is no step, the counts are the occurrences")
    func containerAndSkipped() async throws {
        let session = Learning.photoSession(try W.directory())
        session.windows[Learning.preview] = Learning.Preview.export
        session.script["select|Format"] = LearningSession.Outcome(
            kind: .honestMiss,
            check: LearningSession.check(.valueReadBack, .failed, method: .controlValue, expected: "JPEG", observed: "PNG",
                                         target: LearningSession.popup("Format", value: "PNG"))
        )
        let tools = Learning.tools(session)
        let begun = try await Learning.task(tools, #"{"operation":"begin","goal":"Export as JPEG"}"#)
        let taskID = try #require(begun["task"].string)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        _ = try await Learning.call(tools, "batch", #"""
            {"session":"\#(id)","steps":[{"operation":"type_text","target":"foto_demo.png","text":"foto_web.jpg"},
             {"operation":"select","control":"Format","item":"JPEG"},{"operation":"act","target":"Save"}]}
            """#)
        _ = try await Learning.task(tools, #"{"operation":"end","outcome":"failed"}"#)
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(session.directory)

        let inspection = try Self.inspection(taskID, session)
        let calls = try #require(inspection.attempts.first).calls
        #expect(calls.map { "\($0.tool.rawValue):\($0.role.rawValue)" }
                == ["open_session:context", "batch:container", "type_text:step", "select:step", "act:skipped"]
                || calls.map { "\($0.tool.rawValue):\($0.role.rawValue)" }
                == ["open_session:context", "batch:container", "act:skipped", "type_text:step", "select:step"],
                "\(calls.map { ($0.tool.rawValue, $0.role.rawValue, $0.position) })")
        #expect(inspection.counts.operationalSteps == 2 && inspection.counts.containers == 1 && inspection.counts.skipped == 1)
        #expect(inspection.counts.operationalSteps == (try Self.count("SELECT count(*) FROM memory_step_occurrences", session)))
        #expect(calls.filter { $0.role == .step }.allSatisfy { $0.stepOccurrenceID != nil }
                && calls.filter { $0.role != .step }.allSatisfy { $0.stepOccurrenceID == nil })
        #expect(calls.first { $0.tool == .select }?.check == "value_read_back failed")
        #expect(inspection.counts.versions == 0, "nothing was interpreted: no version")
    }

    @Test("a menu path that ends on a menu lists its items and presses nothing: read as context, no step and no occurrence; the item pressed after it is the step")
    func menuListingIsNoStep() async throws {
        let session = Learning.photoSession(try W.directory())
        // The listing: the path ends on the File menu, nothing is pressed, no gesture goes out, no check is made.
        session.script["menu|File"] = LearningSession.Outcome(kind: .actedNoop, gesture: false)
        let tools = Learning.tools(session)
        let begun = try await Learning.task(tools, #"{"operation":"begin","goal":"Export the photo"}"#)
        let taskID = try #require(begun["task"].string)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        let listed = try await Learning.call(tools, "menu", #"{"session":"\#(id)","path":"File"}"#)
        #expect(listed["status"].string == "acted_noop", "\(listed)")
        _ = try await Learning.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let checkpoint = try await Learning.task(tools, #"{"operation":"checkpoint","note":"exported"}"#)
        #expect(checkpoint["candidate"]["steps"].array?.count == 2, "the listing is no step: \(checkpoint)")
        _ = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(session.directory)

        let inspection = try Self.inspection(taskID, session)
        let calls = try #require(inspection.attempts.first).calls
        #expect(calls.map { "\($0.tool.rawValue):\($0.role.rawValue)" }
                == ["open_session:context", "menu:context", "menu:step", "press:step"],
                "\(calls.map { ($0.tool.rawValue, $0.role.rawValue, $0.position) })")
        #expect(inspection.counts.operationalSteps == 2 && inspection.counts.contextCalls == 2)
        #expect(inspection.counts.operationalSteps == (try Self.count("SELECT count(*) FROM memory_step_occurrences", session)))
        #expect(calls.first { $0.role == .context && $0.tool == .menu }?.stepOccurrenceID == nil)
        #expect(inspection.text.contains { $0.contains("menu completed") && $0.contains("— context") }, "\(inspection.text)")
        #expect(try #require(inspection.attempts.first).candidates.allSatisfy { $0.policyVersion == "app-blocks-2" })
    }

    @Test("the Recall of a task read by its id: the proposal with its sources, the choice and its validated query, the calls linked to the tract, the use declared")
    func recallInTheDiagnosis() async throws {
        typealias L = RecallLifecycleTests
        typealias C = RecallChoiceToolTests
        let directory = try W.directory()
        let learner = Learning.photoSession(directory)
        let (_, routeID) = try await L.learnPhoto(learner)
        let session = Learning.photoSession(directory)
        let tools = Learning.tools(session, stream: "chooser")
        let begun = try await Learning.task(tools, C.proposeRequest)
        let taskID = try #require(begun["task"].string, "\(begun)")
        let proposal = begun["recall_proposal"]
        let proposalID = try #require(proposal["proposal"].string, "\(proposal)")
        let key = try #require(RecallProductPathTests.source(proposal, routeID), "\(proposal)")
        let chosen = try await Learning.task(tools, C.choose(proposalID, [(key, 4, 7)]))
        let queryID = try #require(chosen["recall"]["query"].string, "\(chosen)")
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        _ = try await Learning.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await Learning.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"foto_mail.png"}"#)
        _ = try await Learning.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"PNG"}"#)
        _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let ended = try await Learning.task(tools, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(queryID)","need":1,"outcome":"followed"}]}
            """#)
        #expect(ended["status"].string == "ended", "\(ended)")
        await L.close(session)

        let inspection = try Self.inspection(taskID, session)
        let attempt = try #require(inspection.attempts.first)
        let stored = try #require(attempt.proposals.first)
        #expect(stored.proposalID == proposalID && stored.channel == "lexical" && stored.searchStatus == "completed", "\(stored)")
        #expect(stored.needs.count == 1 && stored.sources.contains { $0.key == key && $0.routeID == routeID }, "\(stored)")
        #expect(stored.choice?.queryID == queryID && stored.choice?.needs.first?.declared == "all", "\(String(describing: stored.choice))")
        let query = try #require(attempt.queries.first)
        #expect(query.queryID == queryID && query.proposalID == proposalID && query.delivery == "delivered", "\(query)")
        let need = try #require(query.needs.first)
        // Stored from 0, as every step of the diagnosis; the agent chose 4–7 as the proposal numbered them, from 1.
        #expect(need.selections.contains { $0.role == "selected" && $0.routeID == routeID && $0.firstPosition == 3 && $0.lastPosition == 6 },
                "\(need.selections)")
        #expect(need.links.count == 4 && need.links.filter(\.confirmed).count == 4, "the four calls of the tract, each confirmed: \(need.links)")
        #expect(need.reports.map(\.declared) == ["followed"])
        #expect(inspection.counts.proposals == 1 && inspection.counts.choices == 1 && inspection.counts.queries == 1
                && inspection.counts.useReports == 1)
        let text = inspection.text
        #expect(text.contains { $0.contains("proposal \(proposalID) rev 1, initial: lexical completed") }, "\(text)")
        #expect(text.contains { $0.contains("chosen → query \(queryID): need 1 all") }, "\(text)")
        #expect(text.contains { $0.contains("selected \(routeID) steps 3–6 (4–7 as proposed)") }, "\(text)")
        #expect(text.contains { $0.contains("linked calls 4: 4 confirmed, 0 undetermined") }, "\(text)")
        #expect(text.contains { $0.contains("use 1: followed") }, "\(text)")
        #expect(text.contains { $0.contains("Recall: proposals 1, chosen 1, queries 1, uses 1") }, "\(text)")

        // The listing: both tasks, newest first, each counted; a producer kind that opened none lists nothing.
        guard case .found(let rows) = SQLiteMemoryInspection.tasks(in: Self.archive(session), limit: 10) else {
            Issue.record("the tasks were not listed"); return
        }
        #expect(rows.count == 2 && rows.first?.taskID == taskID, "\(rows)")
        #expect(rows.first.map { ($0.source, $0.streamID, $0.status, $0.attempts, $0.versions, $0.proposals, $0.choices, $0.queries) }
                    .map { "\($0)" } == "\(("app", "chooser", "completed", 1, 0, 1, 1, 1))", "\(String(describing: rows.first))")
        #expect(rows.last.map { ($0.streamID, $0.versions, $0.proposals) }.map { "\($0)" } == "\(("worker-1", 1, 0))", "\(String(describing: rows.last))")
        #expect(rows.allSatisfy { $0.closedAtMS != nil && $0.closedAtMS! >= $0.openedAtMS && !$0.goal.isEmpty })
        guard case .found(let one) = SQLiteMemoryInspection.tasks(in: Self.archive(session), limit: 1) else { Issue.record("not listed"); return }
        #expect(one.map(\.taskID) == [taskID], "the limit keeps the newest")
        guard case .found(let none) = SQLiteMemoryInspection.tasks(in: Self.archive(session), limit: 10, source: "mcp") else {
            Issue.record("not listed"); return
        }
        #expect(none.isEmpty)

        // The index as a reader finds it: one ready lexical generation holding the version's parts, nothing pending.
        guard case .found(let index) = SQLiteMemoryInspection.recallIndex(in: Self.archive(session)) else {
            Issue.record("the index was not read"); return
        }
        #expect(index.generations.contains { $0.status == "ready" && $0.spaceID == nil && $0.isEnumerated }, "\(index)")
        #expect(index.entries > 0 && index.vectorBacklog == 0 && index.pendingWork == 0, "\(index)")
    }

    @Test("the secret parameter's task read by its id prints no secret, in the text or the graph")
    func noSecretInTheDiagnosis() async throws {
        let session = LearningSession(directory: try W.directory())
        let password = SceneElement(id: "field|password", kind: .control, label: "Password",
                                    bounds: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.04), role: "AXTextField",
                                    labelOrigin: .description)
        session.windows[Learning.finder] = LearningSession.Window(elements: [password, LearningSession.button("Sign In")], surface: .dialog)
        let tools = Learning.tools(session)
        let canary = "pin-9Z2-canary"
        let begun = try await Learning.task(tools, #"""
            {"operation":"begin","goal":"Sign in","inputs":[{"name":"pin","value":"\#(canary)","secret":true}]}
            """#)
        let taskID = try #require(begun["task"].string)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.finder)"}"#)
        _ = try await Learning.call(tools, "type_text", #"{"session":"\#(id)","target":"Password","text":"\#(canary)"}"#)
        _ = try await Learning.call(tools, "act", #"{"session":"\#(id)","target":"Sign In"}"#)
        let ended = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        _ = try await Learning.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Sign in with <pin>"},
             "parameters":[{"name":"pin","role":"the person's code","kind":"text","secret":true}],
             "uses":[{"step":1,"argument":"text","template":"{pin}"}]}
            """#)
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(session.directory)

        let inspection = try Self.inspection(taskID, session)
        let text = inspection.text.joined(separator: "\n")
        #expect(!text.contains(canary) && !inspection.graph.contains(canary))
        #expect(text.contains("bound from request: withheld"), "\(text)")
        if case .notFound = SQLiteMemoryInspection.task("no-such-task", in: Self.archive(session)) {} else {
            Issue.record("an unknown id is not found")
        }
    }
}
