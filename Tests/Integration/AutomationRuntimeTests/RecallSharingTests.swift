//
//  RecallSharingTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallSharingTests prove that the app's workers and an external MCP client search one Recall over the user's one
/// archive, through their own entries: the client speaks JSON-RPC to an `MCPRouter` over `AutomationTools` with its
/// `mcp` producer, as production composes it. What one learns, the other is offered; each query, link and declared
/// use stays its producer's; and a use is credited only for the steps the calls carried out and verified, never for
/// what an agent declares. These are integration proofs over the session double, not a live run.
@MainActor
@Suite("The Recall shared by the app's workers and an MCP client, with use credited from facts only", .serialized, .automaticSelection)
struct RecallSharingTests {

    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    /// An MCP client's entry: its router over the tools of its own session and producer.
    static func client(_ session: LearningSession, stream: String = "mcp-client") async throws -> MCPRouter {
        let tools = P.tools(session, source: .mcp, stream: stream)
        let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in try await tools.call(name, arguments) }
        let initialized = await router.handle(.object(["jsonrpc": .string("2.0"), "id": .number(0), "method": .string("initialize"),
                                                        "params": .object(["protocolVersion": .string("2025-11-25")])]))
        #expect(initialized?["result"]["serverInfo"]["name"].string == "braus")
        return router
    }

    static var requestID = 0

    /// One `tools/call` through the router, answered as the client reads it.
    static func call(_ router: MCPRouter, _ name: String, _ arguments: String) async throws -> JSONValue {
        requestID += 1
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(requestID)), "method": .string("tools/call"),
                                          "params": .object(["name": .string(name), "arguments": P.json(arguments)])])
        let answer = try #require(await router.handle(request))
        #expect(answer["error"] == .null, "\(answer)")
        return answer["result"].payload
    }

    static func task(_ router: MCPRouter, _ arguments: String) async throws -> JSONValue {
        try await call(router, "memory_task", arguments)
    }

    static func rows(_ sql: String, _ session: LearningSession) throws -> [String] { try P.rows(sql, in: session) }

    /// The export tract of the photo, carried out by a client with the task's values.
    static func export(_ router: MCPRouter, session: LearningSession, name: String = "foto_mail.png", format: String = "PNG") async throws {
        let id = session.id!.uuidString
        _ = try await call(router, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await call(router, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await call(router, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"\#(name)"}"#)
        _ = try await call(router, "select", #"{"session":"\#(id)","control":"Format","item":"\#(format)"}"#)
        _ = try await call(router, "press", #"{"session":"\#(id)","button":"Save"}"#)
    }

    @Test("learned by an app worker, recalled and carried out by an MCP client through its router: the client's query, links and use, the app's version untouched")
    func appToClient() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        let (_, routeID) = try await L.learnPhoto(worker)
        let qualifications = try Self.rows("SELECT count(*) FROM memory_part_qualifications", worker)

        let session = P.photoSession(directory)
        let client = try await Self.client(session)
        let begun = try await Self.task(client, RecallCycleTests.exportRequest)
        let recall = begun["recall"]
        #expect(recall["search"]["status"].string == "completed" && recall["coverage"].string == "complete", "\(recall)")
        let selection = recall["needs"].array?.first?["selection"] ?? .null
        #expect(selection["version"].string == routeID)
        #expect(selection["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } == [4, 5, 6, 7])
        let query = try #require(recall["query"].string)
        try await Self.export(client, session: session)
        let ended = try await Self.task(client, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first)
        #expect(used["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7], "\(ended)")

        #expect(try Self.rows("SELECT source || ':' || source_stream_id FROM memory_recall_queries", worker) == ["mcp:mcp-client"])
        #expect(try Self.rows("SELECT DISTINCT source || ':' || source_stream_id FROM memory_procedure_interpretations", worker)
                == ["app:worker-1"], "the version stays the worker's")
        #expect(try Self.rows("SELECT count(*) FROM memory_recall_links WHERE confirmed = 1", worker) == ["4"])
        #expect(try Self.rows("SELECT count(*) FROM memory_part_qualifications", worker) == qualifications,
                "a reuse proves its own calls: the source is not evaluated again")

        // The next search, by another worker, sees one reuse carried out and verified.
        let again = try await P.task(P.tools(P.photoSession(directory), stream: "worker-2"), RecallCycleTests.exportRequest)
        #expect(again["recall"]["needs"].array?.first?["selection"]["evidence"].string?.contains("1 earlier reuse") == true, "\(again)")
        await L.close(worker)
    }

    @Test("learned by an MCP client through its router, recalled by an app worker: the client's version, the worker's query")
    func clientToApp() async throws {
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let session = P.photoSession(directory)
        let client = try await Self.client(session)
        _ = try await Self.task(client, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        let id = session.id!.uuidString
        _ = try await Self.call(client, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await Self.call(client, "type_text", #"{"session":"\#(id)","target":"Search","text":"foto_demo"}"#)
        _ = try await Self.call(client, "act", #"{"session":"\#(id)","target":"foto_demo.png"}"#)
        _ = try await Self.call(client, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await Self.call(client, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        try await Self.export(client, session: session, name: "foto_web.jpg", format: "JPEG")
        _ = try await Self.call(client, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await Self.call(client, "act", #"{"session":"\#(id)","target":"Show Preview","verb":"set_toggle","value":"on"}"#)
        let ended = try await Self.task(client, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await Self.task(client, P.photoInterpretation(candidate))
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))

        let worker = P.photoSession(directory)
        let begun = try await P.task(P.tools(worker, stream: "worker-1"), RecallCycleTests.exportRequest)
        #expect(begun["recall"]["needs"].array?.first?["selection"]["version"].string
                == ProcedureAssembly.routeID(candidateID: candidate, revision: 1), "\(begun)")
        #expect(try Self.rows("SELECT source || ':' || source_stream_id FROM memory_procedure_interpretations", worker) == ["mcp:mcp-client"])
        #expect(try Self.rows("SELECT source || ':' || source_stream_id FROM memory_recall_queries", worker) == ["app:worker-1"])
        await L.close(worker)
    }

    @Test("a later query is motivated and searches the residual work with the task's current values; an observation queries nothing")
    func motivatedQuery() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        _ = try await L.learnPhoto(worker)
        let session = P.photoSession(directory)
        let tools = P.tools(session, stream: "worker-2")
        let begun = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find ritratto, rotate it and export it as ritratto_web.jpg",
             "inputs":[{"name":"criterion","value":"ritratto"},{"name":"output_name","value":"ritratto_web"}]}
            """#)
        #expect(begun["recall"]["query"].string != nil, "\(begun)")
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "observe", #"{"session":"\#(session.id!.uuidString)"}"#)
        #expect(try Self.rows("SELECT count(*) FROM memory_recall_queries", worker) == ["1"], "a new scene is no reason to search")
        let refused = try await P.task(tools, #"{"operation":"recall","reason":"initial"}"#)
        #expect(refused["error"].string == "invalid_task", "\(refused)")
        let missing = try await P.task(tools, #"{"operation":"recall"}"#)
        #expect(missing["error"].string == "invalid_task")
        _ = try await P.task(tools, #"""
            {"operation":"update","revision":1,"inputs":[{"name":"output_name","value":"ritratto_mail"},
             {"name":"output_extension","value":"png"},{"name":"output_format","value":"PNG"}]}
            """#)
        let again = try await P.task(tools, #"""
            {"operation":"recall","reason":"input_changed","remaining":"Export the edited photo in Preview with a new name and format"}
            """#)
        #expect(again["status"].string == "recalled" && again["recall"]["reason"].string == "input_changed", "\(again)")
        let name = again["recall"]["needs"].array?.first?["selection"]["parameters"].array?.first { $0["name"].string == "output_name" }
        #expect(name?["value"].string == "ritratto_mail", "the current revision's value: \(again)")
        #expect(try Self.rows("SELECT reason || ':' || task_revision FROM memory_recall_queries ORDER BY recorded_at_ms, rowid", worker)
                == ["initial:1", "input_changed:2"])
        await L.close(worker)
    }

    @Test("an adapted use links the steps carried out and the agent's own operation; abandoned and merely declared uses credit nothing")
    func feedback() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        let (_, routeID) = try await L.learnPhoto(worker)

        // Adapted: the client names the file otherwise, so the naming step is its own operation.
        let first = P.photoSession(directory)
        let adapting = try await Self.client(first, stream: "mcp-adapting")
        let adapted = try await Self.task(adapting, RecallCycleTests.exportRequest)
        let adaptedQuery = try #require(adapted["recall"]["query"].string)
        try await Self.export(adapting, session: first, name: "foto_mail_v2.png")
        let adaptedEnd = try await Self.task(adapting, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(adaptedQuery)","need":1,"outcome":"adapted","cause":"agent",
             "note":"another name was asked"}]}
            """#)
        let adaptedUse = try #require(adaptedEnd["recall_use"].array?.first)
        #expect(adaptedUse["steps_carried_out"].array?.compactMap { RecallCycleTests.int($0) } == [4, 6, 7], "\(adaptedEnd)")
        #expect(adaptedUse["not_carried_out"].array?.compactMap { RecallCycleTests.int($0) } == [5])
        #expect(RecallCycleTests.int(adaptedUse["own_operations"]) == 1)

        // Abandoned: delivered, nothing carried out.
        let second = P.photoSession(directory)
        let abandoning = try await Self.client(second, stream: "mcp-abandoning")
        let abandoned = try await Self.task(abandoning, RecallCycleTests.exportRequest)
        let abandonedQuery = try #require(abandoned["recall"]["query"].string)
        _ = try await Self.task(abandoning, #"""
            {"operation":"end","outcome":"failed","use":[{"query":"\#(abandonedQuery)","need":1,"outcome":"abandoned","cause":"method"}]}
            """#)

        // Declared followed, carried out by nothing: a declaration is not a verification.
        let third = P.photoSession(directory)
        let declaring = try await Self.client(third, stream: "mcp-declaring")
        let declared = try await Self.task(declaring, RecallCycleTests.exportRequest)
        let declaredQuery = try #require(declared["recall"]["query"].string)
        let declaredEnd = try await Self.task(declaring, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(declaredQuery)","need":1,"outcome":"followed"}]}
            """#)
        #expect(declaredEnd["recall_use"] == .null || declaredEnd["recall_use"].array?.first?["verified"].array?.isEmpty == true,
                "\(declaredEnd)")

        #expect(try Self.rows("SELECT declared FROM memory_recall_reports ORDER BY rowid", worker)
                == ["adapted", "abandoned", "followed"])
        #expect(try Self.rows("SELECT ifnull(cause, '-') FROM memory_recall_reports ORDER BY rowid", worker)
                == ["agent", "method", "-"])
        #expect(try Self.rows("SELECT count(*) FROM memory_recall_links WHERE query_id = '\(abandonedQuery)'", worker) == ["0"])
        #expect(try Self.rows("SELECT count(*) FROM memory_recall_links WHERE query_id = '\(declaredQuery)'", worker) == ["0"])
        let source = try #require(try await MemoryService.shared(for: directory).perform { try await $0.recall.sources([routeID]) }.first)
        #expect(source.confirmedUses == 0, "no selection was carried out whole and verified")
        let stored = try await MemoryService.shared(for: directory).perform { try await $0.procedures.version(routeID) }
        #expect(stored?.qualifications.values.allSatisfy { $0.verdict == .admitted } == true, "nothing of the source is changed by its uses")
        await L.close(worker)
    }

    // MARK: Attribution from facts

    @Test("a verified click on another control after the delivery is the agent's own operation and credits nothing")
    func otherControlCreditsNothing() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        let (_, routeID) = try await L.learnPhoto(worker)
        let session = P.photoSession(directory)
        let client = try await Self.client(session, stream: "mcp-cancelling")
        let begun = try await Self.task(client, RecallCycleTests.exportRequest)
        let query = try #require(begun["recall"]["query"].string)
        let id = session.id!.uuidString
        _ = try await Self.call(client, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await Self.call(client, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await Self.call(client, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"foto_mail.png"}"#)
        _ = try await Self.call(client, "select", #"{"session":"\#(id)","control":"Format","item":"PNG"}"#)
        _ = try await Self.call(client, "press", #"{"session":"\#(id)","button":"Cancel"}"#)
        let ended = try await Self.task(client, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first)
        #expect(used["steps_carried_out"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6], "\(ended)")
        #expect(used["not_carried_out"].array?.compactMap { RecallCycleTests.int($0) } == [7], "Cancel is not the remembered Save")
        #expect(RecallCycleTests.int(used["own_operations"]) == 1)
        let source = try #require(try await MemoryService.shared(for: directory).perform { try await $0.recall.sources([routeID]) }.first)
        #expect(source.confirmedUses == 0, "a selection not carried out whole credits no reuse, whatever was declared")
        await L.close(worker)
    }

    @Test("a field labelled by its value: under another value it is the same field when the Brain identifies it, and the step is confirmed")
    func dynamicFieldResolvedByIdentity() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        _ = try await L.learnPhoto(worker)
        // The export dialog of another document: the name field shows another value.
        let session = P.photoSession(directory)
        let renamed = LearningSession.Window(elements: [
            LearningSession.field("ritratto.png", x: 0.3), LearningSession.popup("Format", value: "PNG"),
            LearningSession.button("Save", x: 0.8), LearningSession.button("Cancel", x: 0.7),
        ], surface: .dialog, title: "Export")
        session.script["menu|File > Export…"] = LearningSession.Outcome(next: renamed)
        let client = try await Self.client(session, stream: "mcp-renamed")
        let begun = try await Self.task(client, RecallCycleTests.exportRequest)
        let query = try #require(begun["recall"]["query"].string)
        let id = session.id!.uuidString
        _ = try await Self.call(client, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await Self.call(client, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await Self.call(client, "type_text", #"{"session":"\#(id)","target":"ritratto.png","text":"foto_mail.png"}"#)
        _ = try await Self.call(client, "select", #"{"session":"\#(id)","control":"Format","item":"PNG"}"#)
        _ = try await Self.call(client, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let ended = try await Self.task(client, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first)
        #expect(used["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7],
                "the name field is identified by its function, not by the value it shows: \(ended)")
        await L.close(worker)
    }

    @Test("a link uses the values of the revision the query was made under, not a later revision's")
    func linkUsesTheQueryRevision() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        _ = try await L.learnPhoto(worker)
        let session = P.photoSession(directory)
        let tools = P.tools(session, stream: "worker-2")
        let begun = try await P.task(tools, RecallCycleTests.exportRequest)
        let query = try #require(begun["recall"]["query"].string)
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"foto_mail.png"}"#)
        _ = try await P.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"PNG"}"#)
        _ = try await P.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        // The request changes afterwards: a later name. The calls made under the first revision keep its values.
        _ = try await P.task(tools, #"{"operation":"update","revision":1,"inputs":[{"name":"output_name","value":"foto_new"}]}"#)
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first)
        #expect(used["verified"].array?.compactMap { RecallCycleTests.int($0) } == [4, 5, 6, 7], "\(ended)")
        await L.close(worker)
    }

    // MARK: Rows of one template

    /// The photo export learned with the file selected in Finder's results as a parameter: the row clicked is the
    /// task's value, and every row of the list shares one item template.
    static func learnPhotoWithSelectedFile(_ session: LearningSession) async throws {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpretation = P.photoInterpretation(candidate)
            .replacingOccurrences(of: #"{"name":"criterion","role":"text searched for the input file","kind":"text"},"#, with: #"""
                {"name":"criterion","role":"text searched for the input file","kind":"text"},
                {"name":"selected_file","role":"name of the file selected among the results","kind":"text","value":"foto_demo.png","source":"observation"},
                """#)
            .replacingOccurrences(of: #"{"step":1,"argument":"text","template":"{criterion}"},"#, with: #"""
                {"step":1,"argument":"text","template":"{criterion}"},{"step":2,"argument":"target","template":"{selected_file}"},
                """#)
        let interpreted = try await P.task(tools, interpretation)
        #expect(interpreted["error"] == .null, "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
    }

    /// A task that searches a file in Finder and selects it, then clicks the row `clicked`; the verified steps.
    static func selectFile(_ directory: URL, stream: String, inputs: String, clicked: String) async throws -> ([Int], JSONValue) {
        let session = P.photoSession(directory)
        let tools = P.tools(session, stream: stream)
        let begun = try await P.task(tools, #"""
            {"operation":"begin","goal":"Search altro in Finder and select the file found","remaining":"Search altro in Finder and select the file found",
             "needs":[{"text":"Search altro in Finder and select the file found","app":"\#(P.finder)"}],"inputs":\#(inputs)}
            """#)
        let query = try #require(begun["recall"]["query"].string, "\(begun)")
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"altro"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"\#(clicked)"}"#)
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"\#(query)","need":1,"outcome":"followed"}]}
            """#)
        let used = try #require(ended["recall_use"].array?.first, "\(ended)")
        return (used["verified"].array?.compactMap { RecallCycleTests.int($0) } ?? [], begun["recall"])
    }

    @Test("two rows of one item template with different labels: the row the task names is the step; another row, or none named, is not")
    func rowsOfOneTemplate() async throws {
        let directory = try W.directory()
        let worker = P.photoSession(directory)
        try await Self.learnPhotoWithSelectedFile(worker)
        // The click on a result row is keyed by the list's item template, which every row shares.
        let keys = try Self.rows("""
            SELECT DISTINCT r.element_key FROM brain_relations r JOIN brain_relation_evidence v ON v.relation_id = r.relation_id
            JOIN memory_operation_arguments a ON a.event_id = v.call_event_id AND a.argument_name = 'target' AND a.text_value = 'foto_demo.png'
            JOIN memory_agent_actions c ON c.event_id = v.call_event_id AND c.tool_kind = 'act'
            """, worker)
        #expect(keys.count == 1 && keys.allSatisfy { $0.hasPrefix("item_template|") }, "\(keys)")

        let both = #"[{"name":"criterion","value":"altro"},{"name":"selected_file","value":"altro.png","role":"name of the file selected among the results"}]"#
        let (right, recall) = try await Self.selectFile(directory, stream: "right", inputs: both, clicked: "altro.png")
        #expect(recall["needs"].array?.first?["selection"]["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } == [1, 2], "\(recall)")
        #expect(right == [1, 2], "the row the task names, under the template the step was keyed by")
        let (wrong, _) = try await Self.selectFile(directory, stream: "wrong", inputs: both, clicked: "foto_demo.png")
        #expect(wrong == [1], "the same template, another row: not the record the task asked for")
        let (unbound, missing) = try await Self.selectFile(directory, stream: "unbound", inputs: #"[{"name":"criterion","value":"altro"}]"#,
                                                            clicked: "altro.png")
        #expect(missing["coverage"].string == "ambiguous", "\(missing)")
        #expect(unbound == [1], "a row the task left unresolved is not confirmed by the template")
        let calls = try Self.rows("""
            SELECT count(DISTINCT r.element_key) FROM brain_relations r JOIN brain_relation_evidence v ON v.relation_id = r.relation_id
            JOIN memory_operation_arguments a ON a.event_id = v.call_event_id AND a.argument_name = 'target' AND a.text_value IN ('altro.png', 'foto_demo.png')
            JOIN memory_agent_actions c ON c.event_id = v.call_event_id AND c.tool_kind = 'act'
            """, worker)
        let rowCalls = try Self.rows("""
            SELECT count(*) FROM brain_relation_evidence v JOIN memory_agent_actions c ON c.event_id = v.call_event_id AND c.tool_kind = 'act'
            JOIN memory_operation_arguments a ON a.event_id = v.call_event_id AND a.argument_name = 'target' AND a.text_value IN ('altro.png', 'foto_demo.png')
            """, worker)
        #expect(calls == ["1"] && rowCalls.first.flatMap(Int.init).map { $0 >= 3 } == true,
                "the rows' calls of every task carry the one template key: \(rowCalls)")
        await L.close(worker)
    }
}
