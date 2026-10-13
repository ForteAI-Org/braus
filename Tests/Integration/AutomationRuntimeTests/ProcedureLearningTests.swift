//
//  ProcedureLearningTests.swift
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

/// ProcedureLearningTests prove the D2 cycle through the product's own entry: `AutomationTools` with
/// its recorder, the shared `MemoryService`, the real SQLite archive, the scene associations, the
/// relations, the procedure producer and the qualification, over a session double that replaces only
/// the operating system and the applications (`LearningSession`). Nothing is inserted by hand: every
/// row read back was written by the producers. These are integration proofs, not a live run.
@MainActor
@Suite("Procedures and relations learned from the facts of a task, through the tools", .serialized)
struct ProcedureLearningTests {

    static let finder  = "com.apple.finder"
    static let preview = "com.apple.Preview"

    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    static func tools(_ session: LearningSession, source: MemoryEventSource = .app, stream: String = "worker-1") -> AutomationTools {
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: source, streamID: stream, traceID: "message-1", messageRef: "message-1")
        return tools
    }

    static func task(_ tools: AutomationTools, _ arguments: String) async throws -> JSONValue {
        try await tools.call("memory_task", json(arguments)).payload
    }

    static func call(_ tools: AutomationTools, _ name: String, _ arguments: String) async throws -> JSONValue {
        try await tools.call(name, json(arguments)).payload
    }

    /// A Finder window with a search field, a list of files and a toggle; Preview's editing window; the
    /// Export dialog Preview opens over it.
    static func photoSession(_ directory: URL) -> LearningSession {
        let session = LearningSession(directory: directory)
        session.windows[finder] = Finder.window
        session.windows[preview] = Preview.editing
        // Export opens the dialog; Save closes it.
        session.script["menu|File > Export…"] = LearningSession.Outcome(next: Preview.export)
        session.script["press|Save"] = LearningSession.Outcome(next: Preview.editing)
        return session
    }

    @MainActor enum Finder {
        static let window = LearningSession.Window(elements: [
            SceneElement(id: "field|search", kind: .control, label: "Search", bounds: NormalizedRect(x: 0.6, y: 0.05, width: 0.2, height: 0.04),
                         role: "AXTextField", container: "toolbar", labelOrigin: .description),
            LearningSession.row("foto_demo.png", y: 0.3), LearningSession.row("altro.png", y: 0.34),
            LearningSession.checkbox("Show Preview", state: .on),
        ], title: "Prove")
    }

    @MainActor enum Preview {
        static let editing = LearningSession.Window(elements: [
            LearningSession.button("Rotate Right", x: 0.2, container: "toolbar"), LearningSession.button("Markup", x: 0.3, container: "toolbar"),
        ], title: "foto_demo.png")
        static let export = LearningSession.Window(elements: [
            LearningSession.field("foto_demo.png", x: 0.3), LearningSession.popup("Format", value: "PNG"),
            LearningSession.button("Save", x: 0.8), LearningSession.button("Cancel", x: 0.7),
        ], surface: .dialog, title: "Export")
    }

    /// The archive's rows of one query, as text.
    static func rows(_ sql: String, in session: LearningSession) throws -> [String] {
        try rawRows(sql, at: session.directory.appendingPathComponent("memory.sqlite"))
    }

    // MARK: The whole cycle

    /// The interpretation the agent gives the photo export's candidate.
    static func photoInterpretation(_ candidate: String, revision: Int? = nil) -> String {
        """
        {"operation":"interpret","candidate":"\(candidate)",\(revision.map { "\"revision\":\($0)," } ?? "")
         "procedure":{"label":"Find <file> in Finder, rotate it in Preview and export it as <name>.<extension>"},
         "parts":[{"part":"b1","label":"Find <file> in Finder","outcome":"completed"},
                  {"part":"b2","label":"Rotate <file> and export it as <name>.<extension> in <format>","outcome":"completed"},
                  {"part":"b3","label":"Keep Finder's preview shown","outcome":"completed"}],
         "steps":[{"step":1,"label":"Search <criterion> in Finder"},{"step":2,"label":"Select the file found"},
                  {"step":3,"label":"Rotate the image right"},{"step":4,"label":"Open the Export dialog"},
                  {"step":5,"label":"Set <name>.<extension> in the Name field"},{"step":6,"label":"Choose <format>"},
                  {"step":7,"label":"Confirm the export"},{"step":8,"label":"Show the preview in Finder"}],
         "parameters":[{"name":"criterion","role":"text searched for the input file","kind":"text"},
                       {"name":"output_name","role":"name of the exported file without extension","kind":"text"},
                       {"name":"output_extension","role":"extension of the exported file","kind":"text","value":"jpg","source":"derived"},
                       {"name":"output_format","role":"format chosen in the Export dialog","kind":"text","value":"JPEG","source":"request"}],
         "uses":[{"step":1,"argument":"text","template":"{criterion}"},
                 {"step":5,"argument":"text","template":"{output_name}.{output_extension}"},
                 {"step":6,"argument":"item","template":"{output_format}"}]}
        """
    }

    /// Runs the photo export through the tools: two operations in Finder, five in Preview, one in Finder.
    static func runPhotoExport(_ tools: AutomationTools, _ session: LearningSession) async throws {
        let id = session.id!.uuidString
        _ = try await call(tools, "open_session", #"{"app":"\#(finder)"}"#)
        _ = try await call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"foto_demo"}"#)
        _ = try await call(tools, "act", #"{"session":"\#(id)","target":"foto_demo.png"}"#)
        _ = try await call(tools, "open_session", #"{"app":"\#(preview)"}"#)
        _ = try await call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        _ = try await call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"foto_web.jpg"}"#)
        _ = try await call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"JPEG"}"#)
        _ = try await call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        _ = try await call(tools, "open_session", #"{"app":"\#(finder)"}"#)
        _ = try await call(tools, "act", #"{"session":"\#(id)","target":"Show Preview","verb":"set_toggle","value":"on"}"#)
    }

    @Test("A→B→A through the tools: one step per started operation in three blocks, interpreted at the checkpoint, admitted at the end, the same after reopening")
    func wholeCycle() async throws {
        let session = Self.photoSession(try W.directory())
        // Finder's toggle is already on: the operation is a verified no-op, with no gesture.
        session.script["act|Show Preview"] = LearningSession.Outcome(
            kind: .actedNoop,
            check: LearningSession.check(.requestedStateAlreadyPresent, method: .controlState, expected: "on", observed: "on",
                                         performed: .none, target: LearningSession.checkbox("Show Preview", state: .on))
        )
        let tools = Self.tools(session)
        _ = try await Self.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG",
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await Self.runPhotoExport(tools, session)

        let checkpoint = try await Self.task(tools, #"{"operation":"checkpoint","note":"exported"}"#)
        let candidate = checkpoint["candidate"]
        let candidateID = try #require(candidate["id"].string)
        #expect(candidate["steps"].array?.count == 8, "one step per started UI operation; open_session is no step")
        #expect(candidate["blocks"].array?.map { $0["part"].string ?? "" } == ["b1", "b2", "b3"], "Finder, Preview, Finder")
        #expect(candidate["blocks"].array?.map { $0["app"].string ?? "" } == [Self.finder, Self.preview, Self.finder])
        #expect(candidate["steps"].array?[7]["check"].string == "requested_state_already_present passed")

        let interpreted = try await Self.task(tools, Self.photoInterpretation(candidateID))
        #expect(interpreted["status"].string == "interpreted" && interpreted["revision"] == .number(1), "\(interpreted)")
        #expect(interpreted["findings"] == .null, "every use reproduces the recorded argument")
        let parts = try #require(interpreted["parts"].array)
        #expect(parts.count == 1 + 3 + 8)
        let refused = parts.filter { $0["admitted"].bool == false }.map { $0["part"].string ?? "" }
        #expect(refused == ["procedure"], "the procedure waits for the declared end; blocks and steps are admitted")
        #expect(parts.first { $0["part"].string == "procedure" }?["reasons"].array?.map { $0.string ?? "" }
                == ["completion_not_declared"])

        let ended = try await Self.task(tools, #"{"operation":"end","outcome":"completed","outputs":[{"name":"exported","value":"foto_web.jpg","kind":"file"}]}"#)
        #expect(ended["candidate"]["id"].string == candidateID, "the same facts are the same candidate")
        #expect(ended["candidate"]["new"].bool == false)

        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(session.directory)

        // Reopened: the rows read back through the repositories.
        let reopened = MemoryService.shared(for: session.directory)
        let routeID = ProcedureAssembly.routeID(candidateID: candidateID, revision: 1)
        let stored = try #require(try await reopened.perform { try await $0.procedures.version(routeID) })
        #expect(stored.isCurrent)
        #expect(stored.version.definition.steps.count == 8)
        #expect(stored.version.parts.filter { $0.kind == .subprocedure }.map(\.bundleID) == [Self.finder, Self.preview, Self.finder])
        #expect(stored.version.parts.allSatisfy { stored.qualifications[$0.partID]?.verdict == .admitted },
                "after the end every part is admitted: \(stored.qualifications.values.filter { $0.verdict == .refused }.map { ($0.partID, $0.findings) })")
        // Parameters: the definition keeps placeholders, the attempt keeps the values with their sources.
        let name = try #require(stored.version.definition.steps[4].operations[0].arguments.first { $0.name == "text" })
        guard case .template(let segments) = name.value else { Issue.record("not a template: \(name.value)"); return }
        #expect(segments.count == 3, "name, the literal dot, extension")
        #expect(stored.version.definition.steps[4].operations[0].arguments.contains {
            if case .literal(.text(let text)) = $0.value { return $0.name == "target" && text == "foto_demo.png" } else { return false }
        }, "the field the name went into stays a fixed reference")
        #expect(try Self.rows("SELECT count(*) FROM memory_operation_arguments a JOIN memory_step_operations o ON o.operation_id = a.operation_id WHERE o.route_id = '\(routeID)' AND a.text_value = 'foto_web.jpg'", in: session) == ["0"],
                "the episode's name is no literal of the definition")
        let bindings = stored.version.bindings.map { binding -> String in
            let parameter = stored.version.definition.parameters.first { $0.parameterID == binding.parameterID }?.name ?? ""
            if case .text(let text) = binding.content { return "\(parameter)=\(text):\(binding.source.rawValue)" }
            return "\(parameter):\(binding.source.rawValue)"
        }
        #expect(bindings == ["criterion=foto_demo:request", "output_name=foto_web:request", "output_extension=jpg:derived",
                             "output_format=JPEG:request"])
        // The contract propagates the leaves' parameters to the parts that contain them.
        let exportInputs = stored.contract.filter { $0.partID == "\(routeID)/block-1" && $0.kind == .input }.count
        #expect(exportInputs == 3)
        #expect(stored.contract.contains { $0.partID == "\(routeID)/step-5" && $0.kind == .entryState && $0.sceneID != nil },
                "the format step starts from the Export dialog's state")
        #expect(stored.contract.contains { $0.partID == "\(routeID)/step-6" && $0.kind == .entryState && $0.sceneID != nil },
                "a dialog button pressed by title is perceived before it is pressed: its entry state is the dialog's")
        // One occurrence per call, its verification attributed to it.
        let occurrences = try Self.rows("SELECT count(*) FROM memory_step_occurrences", in: session)
        #expect(occurrences == ["8"])
        #expect(try Self.rows("SELECT count(*) FROM memory_verifications WHERE step_occurrence_id IS NOT NULL", in: session) == ["8"])
        // The catalogue offers every admitted part of the current version.
        let catalogue = try await reopened.perform { try await $0.procedures.catalogue(limit: 100) }
        #expect(catalogue.count == 12)
        #expect(catalogue.first { $0.part.kind == .subprocedure && $0.part.bundleID == Self.preview }?.parameters.count == 3)

        // The Brain: one application per operation, with a relation per verified operation that started from a
        // recognized state, and an exclusion said for the others.
        let applications = try Self.rows("""
            SELECT a.tool_kind || ':' || r.outcome || ':' || ifnull(r.reason, '-') FROM brain_relation_evaluations r
            JOIN memory_agent_actions a ON a.event_id = r.call_event_id JOIN memory_events e ON e.event_id = r.call_event_id
            WHERE r.sequence = (SELECT max(v.sequence) FROM brain_relation_evaluations v WHERE v.call_event_id = r.call_event_id)
            ORDER BY e.local_order
            """, in: session)
        #expect(applications == ["type_text:supported:-", "act:supported:-", "act:supported:-", "menu:supported:-",
                                 "type_text:supported:-", "select:supported:-", "press:supported:-", "act:supported:-"],
                "the menu command and the dialog's button are perceived before and after, as every other operation")
        let finder = try await reopened.perform { try await $0.relations.relations(of: Self.finder) }
        let verbs = finder.map { "\($0.key.verb.rawValue)[\($0.key.argumentsKey)]:\($0.key.outcome.rawValue)" }.sorted()
        #expect(verbs == ["click[]:effect", "set_toggle[value=on]:already_satisfied", "type_text[replace=true]:value_set"])
        #expect(finder.allSatisfy { $0.key.toSceneID == $0.key.fromSceneID }, "the Finder window stays one functional state")
        #expect(finder.first { $0.key.verb == .click }?.key.elementKey == "item_template|files|AXRow|",
                "a click on a file's row is a click on the list's rows, whatever file")
        #expect(finder.allSatisfy { $0.standing == .candidate }, "one proof each: kept, not offered yet")
        let export = try await reopened.perform { try await $0.relations.relations(of: Self.preview) }
        #expect(Set(export.map(\.key.fromSceneID)).count == 2, "the editing window and the Export dialog are two states")
        await reopened.close()
        MemoryService.forget(session.directory)
    }

    @Test("the same method with new values: the same relations, now exposed, no relation per value, two versions with their own bindings")
    func newValues() async throws {
        let session = Self.photoSession(try W.directory())
        let tools = Self.tools(session)
        var candidates: [String] = []
        for (criterion, name) in [("foto_demo", "foto_web"), ("ritratto", "ritratto_web")] {
            _ = try await Self.task(tools, #"""
                {"operation":"begin","goal":"Export the photo","inputs":[{"name":"criterion","value":"\#(criterion)"},
                 {"name":"output_name","value":"\#(name)"}]}
                """#)
            let id = session.id!.uuidString
            _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.finder)"}"#)
            _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"\#(criterion)"}"#)
            _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"foto_demo.png"}"#)
            _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.preview)"}"#)
            _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
            _ = try await Self.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
            _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"\#(name).jpg"}"#)
            _ = try await Self.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"JPEG"}"#)
            _ = try await Self.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
            _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.finder)"}"#)
            _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Show Preview","verb":"set_toggle","value":"on"}"#)
            let ended = try await Self.task(tools, #"{"operation":"end","outcome":"completed"}"#)
            let candidate = try #require(ended["candidate"]["id"].string)
            candidates.append(candidate)
            let interpreted = try await Self.task(tools, Self.photoInterpretation(candidate))
            #expect(interpreted["findings"] == .null, "\(interpreted)")
            #expect(interpreted["parts"].array?.allSatisfy { $0["admitted"].bool == true } == true, "\(interpreted)")
            if criterion == "foto_demo" {
                let memory = MemoryService.shared(for: session.directory)
                #expect(await memory.flush(within: .seconds(10)))
                #expect(try Self.rows("SELECT count(*) FROM brain_relations", in: session) == ["8"])
            }
        }
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try Self.rows("SELECT count(*) FROM brain_relations", in: session) == ["8"],
                "new names and texts add proofs to the same relations, never relations of their own")
        let finder = try await memory.perform { try await $0.relations.relations(of: Self.finder) }
        #expect(finder.allSatisfy { $0.supports == 2 && $0.standing == .exposed }, "\(finder.map { ($0.summary, $0.supports) })")
        // Two tasks, two versions: the same labels, distinct parts, each with its own bindings.
        let ids = candidates
        let versions = try await memory.perform { repositories in
            try await ids.asyncMap { try #require(try await repositories.procedures.version(ProcedureAssembly.routeID(candidateID: $0, revision: 1))) }
        }
        #expect(versions.count == 2 && versions[0].version.routeID != versions[1].version.routeID)
        #expect(versions.map { $0.version.definition.name } == Array(repeating: versions[0].version.definition.name, count: 2))
        let names = versions.map { version in
            version.version.bindings.compactMap { binding -> String? in
                guard case .text(let text) = binding.content else { return nil }
                return version.version.definition.parameters.first { $0.parameterID == binding.parameterID }?.name == "output_name" ? text : nil
            }
        }
        #expect(names == [["foto_web"], ["ritratto_web"]])
        // The engine's expectation, in Preview's editing state, now comes from the exposed relation.
        let brain = BrainMemory(brains: memory, applications: memory, relations: memory, clock: { memory.clock.brainNow() })
        let editing = LearningSession.perceived(Preview.editing, of: Self.preview)
        #expect(await brain.expectedEffect(of: .click, on: Preview.editing.elements[0], in: editing) == .elementsAppeared(labels: []))
        #expect(await brain.expectedEffect(of: .doubleClick, on: Preview.editing.elements[0], in: editing) == nil)
        await memory.close()
        MemoryService.forget(session.directory)
    }
}

extension ProcedureLearningTests {

    /// The qualification of each part of an interpretation's answer, as `part:admitted` or `part:reasons`.
    static func verdicts(_ answer: JSONValue) -> [String] {
        (answer["parts"].array ?? []).map { part in
            let name = part["part"].string ?? ""
            if part["admitted"].bool == true { return "\(name):admitted" }
            return "\(name):" + (part["reasons"].array ?? []).map { $0.string ?? "" }.joined(separator: ",")
        }
    }

    @Test("a batch stopped at its second step, a retried click and a failed task: the started steps are steps, the batch and the skipped step are not, the locally verified steps are admitted in the failed procedure")
    func partialBatchRetryAndFailedParent() async throws {
        let session = Self.photoSession(try W.directory())
        session.windows[Self.preview] = Preview.export
        // The format is not where it was: the selection fails its read back, which stops the batch.
        session.script["select|Format"] = LearningSession.Outcome(
            kind: .honestMiss,
            check: LearningSession.check(.valueReadBack, .failed, method: .controlValue, expected: "JPEG", observed: "PNG",
                                         target: LearningSession.popup("Format", value: "PNG"))
        )
        // A first click whose effect could not be attributed, then the same click again, verified.
        var clicks = 0
        session.script["act|Cancel"] = LearningSession.Outcome(
            kind: .actedUnverified,
            check: LearningSession.check(.structuralEffect, .unknown, method: .sceneDifference,
                                         limits: [.unattributed, .noExpectation], target: LearningSession.button("Cancel", x: 0.7))
        )
        let tools = Self.tools(session)
        _ = try await Self.task(tools, #"{"operation":"begin","goal":"Export as JPEG","inputs":[{"name":"output_name","value":"foto_web"}]}"#)
        let id = session.id!.uuidString
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.preview)"}"#)
        let batch = try await Self.call(tools, "batch", #"""
            {"session":"\#(id)","steps":[{"operation":"type_text","target":"foto_demo.png","text":"foto_web.jpg"},
             {"operation":"select","control":"Format","item":"JPEG"},{"operation":"act","target":"Save"}]}
            """#)
        #expect(batch["status"].string == "stopped" && batch["attemptedSteps"] == .number(2))
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Cancel"}"#)
        clicks += 1
        session.script["act|Cancel"] = nil
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Cancel"}"#)
        let ended = try await Self.task(tools, #"{"operation":"end","outcome":"failed","note":"the format could not be chosen"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let steps = try #require(ended["candidate"]["steps"].array)
        #expect(steps.map { $0["tool"].string ?? "" } == ["type_text", "select", "act", "act"],
                "the batch's two started steps and the two clicks: no step for the batch, none for the skipped step")
        #expect(steps.map { $0["check"].string ?? "" } == ["value_read_back passed", "value_read_back failed",
                                                           "structural_effect unknown", "structural_effect passed"])
        let answer = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Export <file> as <name>.jpg in JPEG","outcome":"failed"},
             "steps":[{"step":1,"label":"Set <name>.jpg in the Name field","outcome":"completed"},
                      {"step":2,"label":"Choose JPEG","outcome":"failed"},
                      {"step":3,"label":"Cancel the export","outcome":"not_completed"},
                      {"step":4,"label":"Cancel the export","outcome":"completed"}],
             "parameters":[{"name":"output_name","role":"name of the exported file","kind":"text"}],
             "uses":[{"step":1,"argument":"text","template":"{output_name}.jpg"}]}
            """#)
        #expect(Self.verdicts(answer) == [
            "procedure:declared_failed,verification_failed (step 2),verification_unknown (step 3)",
            "s1:admitted",
            "s2:declared_failed,verification_failed (step 2)",
            "s3:completion_not_declared,verification_unknown (step 3)",
            "s4:admitted",
        ], "\(answer)")
        // The skipped step and the batch are kept as facts, and are no occurrence.
        #expect(try Self.rows("SELECT tool_kind || ':' || execution_status FROM memory_agent_actions WHERE tool_kind IN ('batch', 'act') ORDER BY event_id", in: session).sorted()
                == ["act:completed", "act:completed", "act:skipped", "batch:completed"])
        #expect(try Self.rows("SELECT count(*) FROM memory_step_occurrences", in: session) == ["4"])
        // The retried click stands alone with its own entry state: the dialog it was observed in.
        let memory = MemoryService.shared(for: session.directory)
        let stored = try #require(try await memory.perform {
            try await $0.procedures.version(ProcedureAssembly.routeID(candidateID: candidate, revision: 1))
        })
        #expect(stored.contract.contains { $0.partID.hasSuffix("/step-3") && $0.kind == .entryState && $0.sceneID != nil })
        let catalogue = try await memory.perform { try await $0.procedures.catalogue(limit: 100) }
        #expect(catalogue.map { $0.part.partID.components(separatedBy: "/").last ?? "" }.sorted() == ["step-0", "step-3"],
                "only the two admitted steps of the failed procedure are offered")
        #expect(clicks == 1)
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("an interrupted attempt keeps what was admitted at its checkpoint; a later interpretation gives labels and never a completion; the same statements again add nothing; other statements under a revision conflict; a stale candidate is refused")
    func interruptionAndIdempotency() async throws {
        let session = Self.photoSession(try W.directory())
        let tools = Self.tools(session)
        let begun = try await Self.task(tools, #"{"operation":"begin","goal":"Rotate the photo"}"#)
        let taskID = try #require(begun["task"].string)
        let id = session.id!.uuidString
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.preview)"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        let checkpoint = try await Self.task(tools, #"{"operation":"checkpoint","note":"rotated"}"#)
        let first = try #require(checkpoint["candidate"]["id"].string)
        let statement = #"""
            {"operation":"interpret","candidate":"\#(first)","procedure":{"label":"Rotate <file>"},
             "steps":[{"step":1,"label":"Rotate the image right","outcome":"completed"}]}
            """#
        let interpreted = try await Self.task(tools, statement)
        #expect(Self.verdicts(interpreted) == ["procedure:completion_not_declared", "s1:admitted"])
        let again = try await Self.task(tools, statement)
        #expect(again["status"].string == "already recorded" && again["revision"] == .number(1))
        let conflict = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(first)","revision":1,"procedure":{"label":"Something else"}}
            """#)
        #expect(conflict["error"].string == "interpretation_conflict")
        let skipped = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(first)","revision":3,"procedure":{"label":"Something else"}}
            """#)
        #expect(skipped["error"].string == "revision_out_of_order" && skipped["next_revision"] == .number(2))
        let unknown = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(first)","procedure":{"label":"x"},"steps":[{"step":9,"label":"none"}]}
            """#)
        #expect(unknown["error"].string == "unknown_reference")
        // A new action makes a new candidate; the earlier one is stale.
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
        let later = try await Self.task(tools, #"{"operation":"checkpoint","note":"marked up"}"#)
        let second = try #require(later["candidate"]["id"].string)
        #expect(second != first)
        let stale = try await Self.task(tools, statement)
        #expect(stale["error"].string == "stale_candidate" && stale["current_candidate"].string == second)
        // The producer stops and a new attempt begins: the first attempt never ended.
        let resumed = try await Self.task(tools, #"{"operation":"resume","task":"\#(taskID)"}"#)
        #expect(resumed["status"].string == "resumed")
        let late = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(second)","procedure":{"label":"Rotate and mark up <file>","outcome":"completed"},
             "steps":[{"step":1,"label":"Rotate the image right","outcome":"completed"},{"step":2,"label":"Open markup","outcome":"completed"}]}
            """#)
        #expect(Self.verdicts(late) == ["procedure:declared_late,completion_not_declared", "s1:declared_late", "s2:declared_late"],
                "\(late)")
        // What was admitted at the checkpoint stays admitted in its version, which the later one supersedes.
        let memory = MemoryService.shared(for: session.directory)
        let earlier = try #require(try await memory.perform {
            try await $0.procedures.version(ProcedureAssembly.routeID(candidateID: first, revision: 1))
        })
        #expect(!earlier.isCurrent)
        #expect(earlier.qualifications.values.filter { $0.verdict == .admitted }.count == 1)
        #expect(try Self.rows("SELECT count(*) FROM memory_procedure_interpretations", in: session) == ["2"])
        #expect(try Self.rows("SELECT count(*) FROM memory_step_occurrences", in: session) == ["2"],
                "two candidates and two versions over one call each never make two occurrences of it")
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a file named Export and the Export command keep their roles; a template the call contradicts is a finding that keeps its step out")
    func homonymsAndContradiction() async throws {
        let session = LearningSession(directory: try W.directory())
        session.windows[Self.preview] = LearningSession.Window(elements: [
            LearningSession.field("", x: 0.3), LearningSession.button("Export", x: 0.8),
        ], surface: .dialog, title: "Save")
        let tools = Self.tools(session)
        _ = try await Self.task(tools, #"""
            {"operation":"begin","goal":"Save a copy named Export","inputs":[{"name":"file_name","value":"Export"},{"name":"wanted","value":"B.png"}]}
            """#)
        let id = session.id!.uuidString
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.preview)"}"#)
        _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"Export","text":"Export"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Export"}"#)
        _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"Export","text":"A.png"}"#)
        let ended = try await Self.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let answer = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Save a copy as <file_name>"},
             "steps":[{"step":1,"label":"Type <file_name> as the name"},{"step":2,"label":"Confirm with Export"},
                      {"step":3,"label":"Type the second name"}],
             "parameters":[{"name":"file_name","role":"name of the copy","kind":"text"},
                           {"name":"wanted","role":"name the person asked for","kind":"file"}],
             "uses":[{"step":1,"argument":"text","template":"{file_name}"},{"step":3,"argument":"text","template":"{wanted}"}]}
            """#)
        #expect(answer["findings"].array?.map { ($0["step"], $0["finding"].string ?? "") }.elementsEqual(
            [(JSONValue.number(3), "use_mismatch")], by: { $0.0 == $1.0 && $0.1 == $1.1 }) == true, "\(answer)")
        #expect(Self.verdicts(answer).contains("s3:use_mismatch (step 3)"))
        #expect(Self.verdicts(answer).contains("s1:admitted") && Self.verdicts(answer).contains("s2:admitted"))
        let memory = MemoryService.shared(for: session.directory)
        let stored = try #require(try await memory.perform {
            try await $0.procedures.version(ProcedureAssembly.routeID(candidateID: candidate, revision: 1))
        })
        let steps = stored.version.definition.steps
        let typed = steps[0].operations[0].arguments
        #expect(typed.contains { if case .parameter = $0.value { $0.name == "text" } else { false } }, "the typed name is the parameter")
        #expect(typed.contains { if case .literal(.text("Export")) = $0.value { $0.name == "target" } else { false } },
                "the field is a fixed reference, though its label is the same text")
        #expect(steps[1].operations[0].arguments.contains { if case .literal(.text("Export")) = $0.value { $0.name == "target" } else { false } },
                "the Export command stays the command")
        #expect(steps[2].operations[0].arguments.contains { if case .literal(.text("A.png")) = $0.value { $0.name == "text" } else { false } },
                "a contradicted use leaves the argument as recorded")
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a secret typed into a password field is taken by a secret parameter: the definition keeps the parameter, the binding is withheld, the archive keeps no copy")
    func secretParameter() async throws {
        let session = LearningSession(directory: try W.directory())
        let password = SceneElement(id: "field|password", kind: .control, label: "Password",
                                    bounds: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.04), role: "AXTextField",
                                    labelOrigin: .description)
        session.windows[Self.finder] = LearningSession.Window(elements: [password, LearningSession.button("Sign In")], surface: .dialog)
        let tools = Self.tools(session)
        let canary = "pin-7Q4-canary"
        _ = try await Self.task(tools, #"""
            {"operation":"begin","goal":"Sign in","inputs":[{"name":"pin","value":"\#(canary)","secret":true}]}
            """#)
        let id = session.id!.uuidString
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.finder)"}"#)
        _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"Password","text":"\#(canary)"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Sign In"}"#)
        let ended = try await Self.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        #expect(!"\(ended)".contains(canary), "the candidate shows the withheld marker, never the secret")
        let answer = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Sign in with <pin>"},
             "steps":[{"step":1,"label":"Type <pin> in the password field"},{"step":2,"label":"Confirm sign in"}],
             "parameters":[{"name":"pin","role":"the person's code","kind":"text","secret":true}],
             "uses":[{"step":1,"argument":"text","template":"{pin}"}]}
            """#)
        #expect(Self.verdicts(answer) == ["procedure:admitted", "s1:admitted", "s2:admitted"], "\(answer)")
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try archiveOccurrences(of: canary, in: memory.url).isEmpty)
        #expect(try Self.rows("SELECT content FROM memory_parameter_bindings", in: session) == ["withheld"])
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a candidate of an MCP client's task is the client's: another producer cannot interpret it, and both read the same archive")
    func producersKeepTheirCandidates() async throws {
        let directory = try W.directory()
        let client = Self.photoSession(directory)
        let mcp = Self.tools(client, source: .mcp, stream: "mcp-claude")
        _ = try await Self.task(mcp, #"{"operation":"begin","goal":"Rotate the photo"}"#)
        let id = client.id!.uuidString
        _ = try await Self.call(mcp, "open_session", #"{"app":"\#(Self.preview)"}"#)
        _ = try await Self.call(mcp, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        let ended = try await Self.task(mcp, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let worker = Self.tools(Self.photoSession(directory), source: .app, stream: "worker-1")
        let foreign = try await Self.task(worker, #"{"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"x"}}"#)
        #expect(foreign["error"].string == "foreign_task", "\(foreign)")
        let own = try await Self.task(mcp, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Rotate <file>"},"steps":[{"step":1,"label":"Rotate right"}]}
            """#)
        #expect(Self.verdicts(own) == ["procedure:admitted", "s1:admitted"])
        #expect(try Self.rows("SELECT source || ':' || source_stream_id FROM memory_procedure_interpretations", in: client)
                == ["mcp:mcp-claude"])
        await MemoryService.shared(for: directory).close()
        MemoryService.forget(directory)
    }

    @Test("a method that took another path is a variant of the earlier version from the step it diverged at, with its own qualification; a variant of nothing or past its end is refused")
    func variantOfAnEarlierVersion() async throws {
        let session = Self.photoSession(try W.directory())
        let tools = Self.tools(session)
        _ = try await Self.task(tools, #"{"operation":"begin","goal":"Export the photo"}"#)
        try await Self.runPhotoExport(tools, session)
        let first = try await Self.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let firstCandidate = try #require(first["candidate"]["id"].string)
        _ = try await Self.task(tools, Self.photoInterpretation(firstCandidate))
        let original = ProcedureAssembly.routeID(candidateID: firstCandidate, revision: 1)

        // The same export with a markup before the Export dialog: the paths part at the fourth step.
        _ = try await Self.task(tools, #"{"operation":"begin","goal":"Mark up and export the photo"}"#)
        let id = session.id!.uuidString
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.finder)"}"#)
        _ = try await Self.call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"foto_demo"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"foto_demo.png"}"#)
        _ = try await Self.call(tools, "open_session", #"{"app":"\#(Self.preview)"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        _ = try await Self.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
        _ = try await Self.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await Self.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let second = try await Self.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(second["candidate"]["id"].string)
        #expect(second["candidate"]["steps"].array?.count == 6)

        let statement = #""procedure":{"label":"Find, rotate, mark up and export the photo"}"#
        let unknown = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"candidate-none/version-1","divergence_step":4}
            """#)
        #expect(unknown["error"].string == "unknown_reference", "\(unknown)")
        let beyond = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"\#(original)","divergence_step":10}
            """#)
        #expect(beyond["error"].string == "unknown_reference", "the earlier version has 8 steps: \(beyond)")
        let half = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"\#(original)"}
            """#)
        #expect(half["error"].string == "invalid_interpretation", "a variant names where it diverges: \(half)")

        let variant = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"\#(original)","divergence_step":4}
            """#)
        #expect(variant["status"].string == "interpreted" && variant["revision"] == .number(1), "\(variant)")
        let memory = MemoryService.shared(for: session.directory)
        let stored = try #require(try await memory.perform {
            try await $0.procedures.version(ProcedureAssembly.routeID(candidateID: candidate, revision: 1))
        })
        #expect(stored.version.variantOf == original && stored.version.divergencePosition == 3)
        #expect(stored.variantPrefix == VariantPrefix.Check(status: .verified, comparedSteps: 3, reason: nil),
                "the three steps before the divergence are the same operations, the search text the same literal")
        let earlier = try await memory.perform { try await $0.procedures.version(original) }
        #expect(stored.isCurrent && earlier?.isCurrent == true, "a variant supersedes nothing: both methods stay")
        #expect(stored.version.parts.allSatisfy { stored.qualifications[$0.partID] != nil },
                "the variant is qualified on its own facts, not by the version it varies")

        // The search text a parameter here and a literal in the origin: the two cannot be shown the same, so the
        // prefix is kept as suggested only.
        let parameterized = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"\#(original)","divergence_step":4,
             "parameters":[{"name":"criterion","role":"text searched for the input file","kind":"text","value":"foto_demo","source":"request"}],
             "uses":[{"step":1,"argument":"text","template":"{criterion}"}]}
            """#)
        #expect(parameterized["status"].string == "interpreted" && parameterized["revision"] == .number(2), "\(parameterized)")
        let suggested = try #require(try await memory.perform {
            try await $0.procedures.version(ProcedureAssembly.routeID(candidateID: candidate, revision: 2))
        })
        #expect(suggested.variantPrefix == VariantPrefix.Check(status: .suggested, comparedSteps: 3, reason: .unreadableStep))
        // A prefix that runs past the first step that differs (the menu against the markup) is refused whole.
        let versionsBefore = try Self.rows("SELECT count(*) FROM memory_procedure_versions", in: session)
        let contradicted = try await Self.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",\#(statement),"variant_of":"\#(original)","divergence_step":5}
            """#)
        #expect(contradicted["error"].string == "contradicted_prefix" && contradicted["step"] == .number(4), "\(contradicted)")
        #expect(try Self.rows("SELECT count(*) FROM memory_procedure_versions", in: session) == versionsBefore, "nothing is written")
        await memory.close()
        MemoryService.forget(session.directory)
        // The diagnosis says what was proved of each prefix.
        let taskID = try #require(try Self.rows("SELECT task_id FROM memory_procedure_candidates WHERE candidate_id = '\(candidate)'",
                                                in: session).first)
        let text = try ProcedureInspectionTests.inspection(taskID, session).text
        #expect(text.contains { $0.contains("revision 1 ") && $0.hasSuffix("variant of \(original) from step 3, prefix verified over 3 steps") },
                "\(text.filter { $0.contains("version") })")
        #expect(text.contains { $0.contains("revision 2 ") && $0.hasSuffix("prefix suggested over 3 steps (unreadable_step)") },
                "\(text.filter { $0.contains("version") })")
    }
}
