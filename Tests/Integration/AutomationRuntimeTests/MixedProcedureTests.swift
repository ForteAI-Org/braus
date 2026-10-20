//
//  MixedProcedureTests.swift
//  Braus
//

import AppAdapters
import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// P2-01, P2-04 and the acceptance scenarios 1 and 2 through the tools: one task searches a shop through its interface,
/// creates a note through an adapter and appends to it by the identifier the creation produced. The candidate keeps the
/// three kinds of step in order, each adapter step admitted on its own oracle under the current qualification policy;
/// the Recall delivers the dependent step's identifier as a reference to the new run's result, never as the historical
/// value, and the tools refuse a call that reuses the historical identifier with no run of its own producing it.
///
/// Offline: `LearningSession` for the interface, a scripted adapter in place of Notes'. No app or account.
@MainActor
@Suite("P2-01/P2-04: a mixed procedure learned, qualified and recalled", .serialized, .automaticSelection)
struct MixedProcedureTests {

    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    nonisolated static let shop = "web:shop.example"

    /// A notes adapter whose created note gets a fresh identifier, read back after the change.
    final class NotesFake: AppAdapting, @unchecked Sendable {
        let name = "notes"
        let appNames = ["Notes"]
        let bundleIDs: Set<String> = ["com.apple.Notes"]
        let verbs = [
            AdapterVerb("create_note", "Create a note.",
                        parameters: [AdapterParameter("title", .string, "title", confidential: .content)],
                        safety: .write, readBack: "the new note", results: .identifiersAndDates),
            AdapterVerb("append_to_note", "Append.",
                        parameters: [AdapterParameter("id", .string, "the note's id"),
                                     AdapterParameter("text", .string, "text", confidential: .content)],
                        safety: .write, readBack: "the note", results: .identifiersAndDates),
        ]
        private(set) var created: [String] = []

        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            if verb == "create_note" {
                let id = "x-coredata://note/m\(UUID().uuidString.prefix(8))"
                created.append(id)
                return await .afterChange("Notes took the note", look: "Read it") {
                    .confirmed("Created.", .object(["id": .string(id)]))
                }
            }
            return await .afterChange("Notes took the text", look: "Read it") { .confirmed("Added.", .object(["id": arguments["id"]])) }
        }
    }

    static func session(_ directory: URL) -> LearningSession {
        let session = LearningSession(directory: directory)
        session.windows[shop] = LearningSession.Window(elements: [
            SceneElement(id: "field|search", kind: .control, label: "Search",
                         bounds: NormalizedRect(x: 0.3, y: 0.05, width: 0.3, height: 0.04), role: "AXTextField",
                         labelOrigin: .description),
            LearningSession.button("Go", x: 0.7),
        ], title: "Shop")
        return session
    }

    static func tools(_ session: LearningSession, _ adapter: NotesFake, stream: String) -> AutomationTools {
        let tools = P.tools(session, stream: stream)
        tools.adapters = AppAdapters([adapter])
        return tools
    }

    static func answered(_ result: JSONValue) -> JSONValue {
        if result["structuredContent"] != .null { return result["structuredContent"] }
        let text = result["content"].array?.first?["text"].string ?? ""
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    static func appCall(_ tools: AutomationTools, _ verb: String, _ arguments: JSONValue) async throws -> JSONValue {
        answered(try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string(verb), "arguments": arguments])))
    }

    @Test("scenarios 1 and 2: UI, adapter and dependent adapter steps kept in order, admitted on their own oracles; the Recall refers to the new run's result and the historical identifier is refused")
    func mixedProcedure() async throws {
        let session = Self.session(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let adapter = NotesFake()
        let tools = Self.tools(session, adapter, stream: "learn")
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Search lamps on the shop and note them","recall":false,
             "inputs":[{"name":"query","value":"lamps"}]}
            """#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(Self.shop)"}"#)
        let id = try #require(session.id).uuidString
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"lamps"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Go"}"#)
        let created = try await Self.appCall(tools, "create_note", .object(["title": .string("SYNTH-LAMPS")]))
        let noteID = try #require(created["result"]["id"].string, "\(created)")
        _ = try await Self.appCall(tools, "append_to_note", .object(["id": .string(noteID), "text": .string("SYNTH-BODY")]))
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = ended["candidate"]
        let candidateID = try #require(candidate["id"].string, "\(ended)")
        #expect(candidate["blocks"].array?.map { $0["app"].string ?? "" } == [Self.shop, "com.apple.Notes"], "\(candidate)")
        #expect(candidate["steps"].array?.map { $0["check"].string ?? "" }
                == ["value_read_back passed", "structural_effect passed", "adapter_effect passed", "adapter_effect passed"])

        let interpreted = try await P.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidateID)",
             "procedure":{"label":"Search <query> on the shop and note the result"},
             "parts":[{"part":"b1","label":"Search <query> on the shop","outcome":"completed"},
                      {"part":"b2","label":"Note the result in Notes","outcome":"completed"}],
             "steps":[{"step":1,"label":"Type <query> in Search"},{"step":2,"label":"Run the search"},
                      {"step":3,"label":"Create a note"},{"step":4,"label":"Append to the note created"}],
             "parameters":[{"name":"query","role":"text searched for on the shop","kind":"text"}],
             "uses":[{"step":1,"argument":"text","template":"{query}"}]}
            """#)
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        let parts = interpreted["parts"].array ?? []
        #expect(parts.count == 1 + 2 + 4 && parts.allSatisfy { $0["admitted"].bool == true },
                "each adapter step is admitted on its own oracle: \(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))

        // The archive: the candidate's step kinds in order, under the mixed rule; the evidence is each step's own.
        let kinds = try P.rows("SELECT step_kind FROM memory_candidate_steps WHERE candidate_id = '\(candidateID)' ORDER BY position", in: session)
        #expect(kinds == ["operation", "operation", "adapter_call", "adapter_call"], "\(kinds)")
        let policy = try P.rows("SELECT policy_version FROM memory_procedure_candidates WHERE candidate_id = '\(candidateID)'", in: session)
        #expect(policy == [ProcedureSegmentation.mixedPolicyVersion], "\(policy)")
        let versions = try P.rows("SELECT DISTINCT policy_version FROM memory_part_qualifications", in: session)
        #expect(versions == [QualificationPolicy.version], "\(versions)")
        let inherited = try P.rows("SELECT count(*) FROM memory_part_qualification_evidence WHERE origin = 'inherited'", in: session)
        #expect(inherited == ["0"], "a learned procedure's evidence is its own")

        // Scenario 2: a new task's Recall refers the dependent step to the new run's result, never to the historical id.
        let asking = Self.tools(session, adapter, stream: "ask")
        let begun = try await P.task(asking, #"""
            {"operation":"begin","goal":"Search lamps on the shop and note them","remaining":"Search lamps on the shop and note them",
             "inputs":[{"name":"query","value":"lamps"}],
             "needs":[{"text":"Search lamps on the shop, then create a note and append to the note created"}]}
            """#)
        let need = begun["recall"]["needs"].array?.first ?? .null
        let delivered = "\(need)"
        #expect(!delivered.contains(noteID), "the historical identifier is never delivered: \(delivered)")
        #expect(!delivered.contains("SYNTH-LAMPS") && !delivered.contains("SYNTH-BODY"), "no confidential content is delivered")
        let steps = need["selection"]["steps"].array ?? []
        if steps.count == 4 {
            let conditions = need["selection"]["conditions"].array ?? []
            #expect(conditions.contains { $0["kind"].string == "account_to_resolve" && $0["step"] == .number(3) }, "\(conditions)")
            let append = steps[3]["arguments"].array ?? []
            #expect(append.contains { $0["name"].string == "arguments/id" && $0["value"].string == "{@step 3:/id}"
                                      && $0["kind"].string == "result" }, "\(append)")
            #expect(append.contains { $0["name"].string == "arguments/text" && $0["kind"].string == "parameter" }, "\(append)")
        } else {
            Issue.record("the procedure is selected whole: \(need)")
        }

        // The historical identifier, with no call of this run producing it, is refused before anything is sent.
        let sent = adapter.created.count
        await #expect(throws: AutomationFailure.self) {
            _ = try await Self.appCall(asking, "append_to_note", .object(["id": .string(noteID), "text": .string("again")]))
        }
        #expect(adapter.created.count == sent)
        // This run's own note: its identifier is the new result, accepted.
        let fresh = try await Self.appCall(asking, "create_note", .object(["title": .string("SYNTH-NEW")]))
        let freshID = try #require(fresh["result"]["id"].string)
        #expect(freshID != noteID)
        let appended = try await Self.appCall(asking, "append_to_note", .object(["id": .string(freshID), "text": .string("more")]))
        #expect(appended["evidence"]["command"] == .string("accepted"), "\(appended)")
        await L.close(session)
    }

    @Test("scenario 8: an evaluation under an earlier policy is kept; the next Recall appends one under the current policy, linked by sequence, and quarantines the earlier policy")
    func historicalEvaluationReevaluated() async throws {
        let session = CrossRouteRecallTests.session(try W.directory())
        try await CrossRouteRecallTests.learn(on: CrossRouteRecallTests.web, session)
        await L.close(session)
        // An archive whose last evaluation of each part was made under the earlier policy.
        let url = L.url(session)
        let connection = try SQLiteConnection(path: url.path)
        let earlier = try #require(QualificationPolicy.earlierVersions.first)
        try connection.execute("INSERT OR IGNORE INTO memory_qualification_policies (policy_version, status, changed_at_ms) VALUES ('\(earlier)', 'active', 1)")
        try connection.execute("""
            INSERT INTO memory_part_qualifications (part_id, sequence, policy_version, verdict, evaluated_at_ms)
            SELECT part_id, max(sequence) + 1, '\(earlier)', 'admitted', max(evaluated_at_ms) + 1
            FROM memory_part_qualifications GROUP BY part_id
            """)
        connection.close()
        let before = try rawRows("SELECT part_id || '#' || sequence || '#' || policy_version FROM memory_part_qualifications ORDER BY 1", at: url)

        let need = try await CrossRouteRecallTests.need(on: CrossRouteRecallTests.web, session)
        #expect(need["coverage"].string == "complete", "the procedure is evaluated again and still selected: \(need)")
        let after = try rawRows("SELECT part_id || '#' || sequence || '#' || policy_version FROM memory_part_qualifications ORDER BY 1", at: url)
        #expect(Set(before).isSubset(of: Set(after)), "every earlier evaluation is kept")
        let latest = try rawRows("""
            SELECT q.policy_version FROM memory_part_qualifications q
            WHERE q.sequence = (SELECT max(sequence) FROM memory_part_qualifications WHERE part_id = q.part_id)
            """, at: url)
        #expect(!latest.isEmpty && latest.allSatisfy { $0 == QualificationPolicy.version }, "\(latest)")
        let status = try rawRows("SELECT status FROM memory_qualification_policies WHERE policy_version = '\(earlier)'", at: url)
        #expect(status == ["quarantined"], "\(status)")
        await L.close(session)
    }
}
