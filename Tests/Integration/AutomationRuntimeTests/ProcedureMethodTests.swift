//
//  ProcedureMethodTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
@testable import Memory
@testable import SQLiteMemory
import Testing

/// What a completed task teaches since 14 October 2026, through the tools as an agent calls them: the method
/// without the attempt's mistakes, the agent's phases as subprocedures, the result Braus reads on disk as the
/// evidence a procedure rests on (qualification B), and a task that repeats a learned method as a new run of it.
@MainActor
@Suite("The method a completed task teaches", .serialized)
struct ProcedureMethodTests {

    typealias P = ProcedureLearningTests

    static let unknownEffect = LearningSession.check(.structuralEffect, .unknown, method: .sceneDifference,
                                                     limits: [.windowWide, .noExpectation, .unattributed])

    /// Rotates the open image and exports it as `name`.jpg: a miss first (step 1), a wrong pop-up whose check fails
    /// (step 5), and `markup` as an extra step 8 whose check is unknown when asked.
    static func run(_ tools: AutomationTools, _ session: LearningSession, name: String, mistakes: Bool = true,
                    unknownStep: Bool = false) async throws {
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        if mistakes { _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Crop"}"#) }
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        _ = try await P.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"\#(name).jpg"}"#)
        if mistakes { _ = try await P.call(tools, "select", #"{"session":"\#(id)","control":"Quality","item":"High"}"#) }
        _ = try await P.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"JPEG"}"#)
        _ = try await P.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        if unknownStep { _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#) }
    }

    static func session(_ directory: URL, unknownMarkup: Bool = false) -> LearningSession {
        let session = P.photoSession(directory)
        session.script["act|Crop"] = LearningSession.Outcome(kind: .honestMiss, check: .unchecked(performed: .none, limits: [.targetNotResolved]))
        session.script["select|Quality"] = LearningSession.Outcome(
            check: LearningSession.check(.valueReadBack, .failed, method: .controlValue, expected: "High", observed: "Low"))
        if unknownMarkup { session.script["act|Markup"] = LearningSession.Outcome(kind: .actedUnverified, check: unknownEffect) }
        return session
    }

    static func begin(_ name: String) -> String {
        #"""
        {"operation":"begin","goal":"Rotate the open image and export it as \#(name).jpg in JPEG","recall":false,
         "inputs":[{"name":"output_name","value":"\#(name)","role":"name of the exported file without extension"}]}
        """#
    }

    static func end(result file: URL?) -> String {
        guard let file else { return #"{"operation":"end","outcome":"completed"}"# }
        return #"{"operation":"end","outcome":"completed","result_check":{"file":"\#(file.path)"}}"#
    }

    /// The interpretation of the run with its mistakes: phases rotate (step 2) and export (steps 3 to 7).
    static func interpretation(_ candidate: String, mistakes: Bool = true, markup: Bool = false) -> String {
        let shift = mistakes ? 1 : 0
        let steps = (mistakes ? [#"{"step":1,"label":"Crop"}"#] : [])
            + [#"{"step":\#(1 + shift),"label":"Rotate right"}"#, #"{"step":\#(2 + shift),"label":"Open the Export dialog"}"#,
               #"{"step":\#(3 + shift),"label":"Name the file"}"#]
            + (mistakes ? [#"{"step":5,"label":"Choose the quality"}"#] : [])
            + [#"{"step":\#(4 + 2 * shift),"label":"Choose JPEG"}"#, #"{"step":\#(5 + 2 * shift),"label":"Save"}"#]
            + (markup ? [#"{"step":\#(6 + 2 * shift),"label":"Show the markup bar"}"#] : [])
        return #"""
        {"operation":"interpret","candidate":"\#(candidate)",
         "procedure":{"label":"Rotate the open image and export it as <name>.jpg","outcome":"completed"},
         "phases":[{"from":\#(1 + shift),"to":\#(1 + shift),"label":"Rotate the image"},
                   {"from":\#(2 + shift),"to":\#(5 + 2 * shift),"label":"Export it as <name>.jpg in JPEG"}],
         "steps":[\#(steps.joined(separator: ","))],
         "parameters":[{"name":"output_name","role":"name of the exported file","kind":"text"}],
         "uses":[{"step":\#(3 + shift),"argument":"text","template":"{output_name}.jpg"}]}
        """#
    }

    static func written(_ directory: URL, _ name: String) throws -> URL {
        let file = directory.appendingPathComponent("\(name).jpg")
        try Data("jpeg".utf8).write(to: file)
        return file
    }

    @Test("a completed task's version keeps the method: the miss and the failed choice are left out and said, the phases are subprocedures, the file on disk is checked")
    func theMethodOnly() async throws {
        let directory = try W.directory()
        let session = Self.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, Self.begin("foto_web"))
        try await Self.run(tools, session, name: "foto_web")
        let ended = try await P.task(tools, Self.end(result: try Self.written(directory, "foto_web")))
        #expect(ended["result_check"].array?.first?["verdict"].string == "passed", "\(ended["result_check"])")
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await P.task(tools, Self.interpretation(candidate))
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        let leftOut = interpreted["left_out"].array?.map { "\(RecallCycleTests.int($0["step"]) ?? 0):\($0["why"].string ?? "")" }
        #expect(leftOut == ["1:nothing_sent", "5:check_failed"], "\(interpreted)")

        let memory = MemoryService.shared(for: directory)
        let routeID = try #require(interpreted["version"].string)
        let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
        #expect(stored.version.definition.steps.map(\.position) == [0, 1, 2, 3, 4])
        #expect(stored.version.candidatePositions == [1, 2, 3, 5, 6], "the method's steps keep the candidate's numbers")
        let phases = stored.version.parts.filter { $0.kind == .subprocedure }
        #expect(phases.map(\.label) == ["Rotate the image", "Export it as <name>.jpg in JPEG"])
        #expect(phases.map { [$0.firstPosition, $0.lastPosition] } == [[0, 0], [1, 4]])
        #expect(stored.version.parts.filter { $0.kind == .step }.allSatisfy { step in phases.contains { $0.partID == step.parentPartID } },
                "every step of the method is in a phase")
        #expect(stored.qualifications.values.allSatisfy { $0.verdict == .admitted }, "\(stored.qualifications)")
        #expect(try P.rows("SELECT scope || ':' || method || ':' || verdict FROM memory_verifications WHERE scope = 'task'", in: session)
                == ["task:file_check:passed"])
        await memory.close()
    }

    @Test("a use of the task's file on a row clicked by its id mark is the file's name: no mismatch, the row a parameter, the procedure admitted",
          arguments: ["{input_name}", "control|{input_name}"])
    func fileRowByItsMark(_ template: String) async throws {
        let directory = try W.directory()
        let session = Self.session(directory)
        let tools = P.tools(session)
        let id = session.id!.uuidString
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Open foto_1.png and export it","recall":false,
             "inputs":[{"name":"input_name","value":"foto_1.png","role":"the file to open"}]}
            """#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"control|foto1png","section":"list view / Today at 15:52"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Rotate Right"}"#)
        let ended = try await P.task(tools, Self.end(result: try Self.written(directory, "foto_web")))
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await P.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Open a file and rotate it","outcome":"completed"},
             "steps":[{"step":1,"label":"Select the file"},{"step":2,"label":"Rotate right"}],
             "parameters":[{"name":"input_name","role":"the file to open","kind":"text"}],
             "uses":[{"step":1,"argument":"target","template":"\#(template)"}]}
            """#)
        #expect(interpreted["findings"] == .null, "\(interpreted)")
        #expect((interpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }?["admitted"].bool == true, "\(interpreted)")
        let memory = MemoryService.shared(for: directory)
        let routeID = try #require(interpreted["version"].string)
        let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
        switch stored.version.definition.steps.first?.operations.first?.arguments.first(where: { $0.name == "target" })?.value {
            case .parameter?: break
            default: Issue.record("the row's target is the parameter whole, its name: \(String(describing: stored.version.definition.steps.first))")
        }
        #expect(stored.version.definition.steps.first?.operations.first?.arguments.contains { $0.name == "section" } == false,
                "the dated section is left out of the method")
        await memory.close()
    }

    @Test("qualification B: a step whose check is unknown keeps itself out and not its procedure when the result is on disk; a result that is not keeps the procedure out")
    func resultAdmitsTheProcedure() async throws {
        for written in [true, false] {
            let directory = try W.directory()
            let session = Self.session(directory, unknownMarkup: true)
            let tools = P.tools(session)
            _ = try await P.task(tools, Self.begin("foto_web"))
            try await Self.run(tools, session, name: "foto_web", mistakes: false, unknownStep: true)
            let file = written ? try Self.written(directory, "foto_web") : directory.appendingPathComponent("foto_web.jpg")
            let ended = try await P.task(tools, Self.end(result: file))
            #expect(ended["result_check"].array?.first?["verdict"].string == (written ? "passed" : "failed"), "\(ended["result_check"])")
            let candidate = try #require(ended["candidate"]["id"].string)
            let interpreted = try await P.task(tools, Self.interpretation(candidate, mistakes: false, markup: true))
            let parts = Dictionary(uniqueKeysWithValues: (interpreted["parts"].array ?? []).map {
                ($0["part"].string ?? "", $0["admitted"].bool == true)
            })
            #expect(parts["procedure"] == written, "\(interpreted)")
            #expect(parts["s6"] == false, "the unknown step itself stays out: \(interpreted)")
            #expect(parts["s1"] == true)
            if !written {
                let reasons = (interpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }?["reasons"].array ?? []
                #expect(reasons.contains(.string("verification_failed")), "\(reasons)")
            }
            await MemoryService.shared(for: directory).close()
        }
    }

    @Test("a task's value typed as it is, with no use stated, is read as its parameter; a label equal to a value keeps its role")
    func usesBrausInfers() async throws {
        let directory = try W.directory()
        let session = Self.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Rotate the open image and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"output_name","value":"foto_web","role":"name of the exported file without extension"},
                       {"name":"format","value":"JPEG","role":"format chosen in the Export dialog"}]}
            """#)
        try await Self.run(tools, session, name: "foto_web", mistakes: false)
        let ended = try await P.task(tools, Self.end(result: try Self.written(directory, "foto_web")))
        var interpretation = Self.interpretation(try #require(ended["candidate"]["id"].string), mistakes: false)
        interpretation = interpretation.replacingOccurrences(of: #","uses":[{"step":3,"argument":"text","template":"{output_name}.jpg"}]"#, with: "")
        let interpreted = try await P.task(tools, interpretation)
        let routeID = try #require(interpreted["version"].string, "\(interpreted)")
        let memory = MemoryService.shared(for: directory)
        let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
        let steps = stored.version.definition.steps
        let names = Dictionary(uniqueKeysWithValues: stored.version.definition.parameters.map { ($0.parameterID, $0.name) })
        func argument(_ step: Int, _ name: String) -> OperationValue? {
            steps[step].operations[0].arguments.first { $0.name == name }?.value
        }
        guard case .template(let segments)? = argument(2, "text") else {
            Issue.record("the typed name is a template: \(String(describing: argument(2, "text")))"); return
        }
        #expect(segments.count == 2, "{output_name} then .jpg: \(segments)")
        if case .parameter(let id) = segments.first { #expect(names[id] == "output_name") } else { Issue.record("\(segments)") }
        guard case .parameter(let format)? = argument(3, "item") else {
            Issue.record("the format chosen is the task's: \(String(describing: argument(3, "item")))"); return
        }
        #expect(names[format] == "format")
        if case .literal(.text("Format"))? = argument(3, "control") {} else { Issue.record("the pop-up keeps its label: \(String(describing: argument(3, "control")))") }
        #expect(InferredUses.extensionAfter("foto_web", in: "foto_web.jpg") == ".jpg")
        #expect(InferredUses.extensionAfter("foto_web", in: "foto_web copia.jpg") == nil)
        await memory.close()
    }

    @Test("a completed task left uninterpreted is interpreted by Braus from its goal, with the uses its calls show; a failed one is not")
    func brausInterpretsWhatTheAgentLeft() async throws {
        for completed in [true, false] {
            let directory = try W.directory()
            let session = Self.session(directory)
            let tools = P.tools(session)
            _ = try await P.task(tools, Self.begin("foto_web"))
            try await Self.run(tools, session, name: "foto_web", mistakes: false)
            let file = try Self.written(directory, "foto_web")
            let ended = try await P.task(tools, completed ? Self.end(result: file)
                                                          : #"{"operation":"end","outcome":"failed","note":"not exported"}"#)
            #expect(ended["candidate"]["id"].string != nil, "\(ended)")
            let left = await tools.interpretLeftCandidate()
            guard completed else {
                #expect(left == nil, "a failed task is not interpreted by Braus")
                await MemoryService.shared(for: directory).close()
                continue
            }
            let answer = try #require(left?.answer.payload, "Braus interprets the completed task")
            let routeID = try #require(answer["version"].string, "\(answer)")
            #expect((answer["parts"].array ?? []).first { $0["part"].string == "procedure" }?["admitted"].bool == true, "\(answer)")
            let memory = MemoryService.shared(for: directory)
            let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
            #expect(stored.version.definition.name == "Rotate the open image and export it as foto_web.jpg in JPEG")
            #expect(stored.version.definition.parameters.map(\.name) == ["output_name"], "the typed name is the task's value")
            #expect(await tools.interpretLeftCandidate() == nil, "nothing is left once interpreted")
            await memory.close()
        }
    }

    @Test("a repeat whose procedure is refused does not replace the admitted one it repeats: both stay current, the admitted one offered")
    func aWeakerRepeat() async throws {
        let directory = try W.directory()
        let first = Self.session(directory)
        let learner = P.tools(first, stream: "learner-1")
        _ = try await P.task(learner, Self.begin("foto_web"))
        try await Self.run(learner, first, name: "foto_web")
        let firstEnd = try await P.task(learner, Self.end(result: try Self.written(directory, "foto_web")))
        let firstInterpreted = try await P.task(learner, Self.interpretation(try #require(firstEnd["candidate"]["id"].string)))
        let firstVersion = try #require(firstInterpreted["version"].string)
        #expect((firstInterpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }?["admitted"].bool == true)

        // The second run names a result that is not on disk: its check fails and its procedure is refused.
        let second = Self.session(directory)
        let repeater = P.tools(second, stream: "learner-2")
        _ = try await P.task(repeater, Self.begin("foto_mail"))
        try await Self.run(repeater, second, name: "foto_mail", mistakes: false)
        let secondEnd = try await P.task(repeater, Self.end(result: directory.appendingPathComponent("foto_mail.jpg")))
        #expect(secondEnd["result_check"].array?.first?["verdict"].string == "failed", "\(secondEnd["result_check"])")
        let interpreted = try await P.task(repeater, Self.interpretation(try #require(secondEnd["candidate"]["id"].string),
                                                                         mistakes: false))
        let secondVersion = try #require(interpreted["version"].string)
        #expect(interpreted["repeats"] == nil || interpreted["repeats"] == .null, "\(interpreted)")
        #expect((interpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }?["admitted"].bool == false)

        let memory = MemoryService.shared(for: directory)
        let kept = try #require(try await memory.perform { try await $0.procedures.version(firstVersion) })
        #expect(kept.isCurrent, "the admitted version stays in the catalogue")
        let catalogue = try await memory.perform { try await $0.procedures.catalogue() }
        #expect(catalogue.contains { $0.part.routeID == firstVersion && $0.part.kind == .procedure })
        #expect(!catalogue.contains { $0.part.routeID == secondVersion && $0.part.kind == .procedure })
        await memory.close()
    }

    @Test("a task that repeats a learned method with other values is a new run of it: its version replaces the first and inherits the step the first one verified")
    func aRepeatedMethod() async throws {
        let directory = try W.directory()
        let first = Self.session(directory)
        let learner = P.tools(first, stream: "learner-1")
        _ = try await P.task(learner, Self.begin("foto_web"))
        try await Self.run(learner, first, name: "foto_web", unknownStep: true)
        let firstEnd = try await P.task(learner, Self.end(result: try Self.written(directory, "foto_web")))
        let firstCandidate = try #require(firstEnd["candidate"]["id"].string)
        let firstInterpreted = try await P.task(learner, Self.interpretation(firstCandidate, markup: true))
        let firstVersion = try #require(firstInterpreted["version"].string)

        // The second run makes no mistake, but its last step's check is unknown this time.
        let second = Self.session(directory, unknownMarkup: true)
        let repeater = P.tools(second, stream: "learner-2")
        _ = try await P.task(repeater, Self.begin("foto_mail"))
        try await Self.run(repeater, second, name: "foto_mail", mistakes: false, unknownStep: true)
        let secondEnd = try await P.task(repeater, Self.end(result: try Self.written(directory, "foto_mail")))
        let secondCandidate = try #require(secondEnd["candidate"]["id"].string)
        let interpreted = try await P.task(repeater, Self.interpretation(secondCandidate, mistakes: false, markup: true))
        let secondVersion = try #require(interpreted["version"].string)
        #expect(interpreted["repeats"].string == firstVersion, "\(interpreted)")
        let parts = (interpreted["parts"].array ?? []).filter { $0["admitted"].bool != true }
        #expect(parts.isEmpty, "the unknown step is verified by the first run: \(interpreted)")

        let memory = MemoryService.shared(for: directory)
        let replaced = try #require(try await memory.perform { try await $0.procedures.version(firstVersion) })
        #expect(!replaced.isCurrent, "the first run's version left the catalogue")
        let catalogue = try await memory.perform { try await $0.procedures.catalogue() }
        #expect(!catalogue.contains { $0.part.routeID == firstVersion })
        #expect(catalogue.contains { $0.part.routeID == secondVersion && $0.part.kind == .procedure })
        let inheritedFrom = try P.rows(
            "SELECT e.call_event_id FROM memory_part_qualification_evidence e WHERE e.part_id = '\(secondVersion)/step-5'", in: second)
        let firstCalls = try P.rows(
            "SELECT e.event_id FROM memory_task_events e JOIN memory_agent_actions a ON a.event_id = e.event_id"
            + " WHERE e.task_occurrence_id = (SELECT task_occurrence_id FROM memory_procedure_versions WHERE route_id = '\(firstVersion)')",
            in: first)
        #expect(inheritedFrom.count == 1 && firstCalls.contains(inheritedFrom[0]), "the evidence names the first run's call")
        await memory.close()
    }
}

/// The method's identity, the result's verdict and qualification B, alone.
@Suite("Method identity, result check and qualification B")
struct ProcedureMethodRuleTests {

    static func step(_ tool: AgentTool, _ arguments: [(String, OperationValue)], bundle: String = "com.apple.Preview") -> ProcedureStep {
        ProcedureStep(stepID: "s", position: 0, goalText: "g", bundleID: bundle, operations: [
            StepOperation(operationID: "o", position: 0, tool: tool,
                          arguments: arguments.map { OperationArgument(name: $0.0, position: 0, value: $0.1) })
        ])
    }

    @Test("a method is its tools, fixed choices and elements; a typed text, a parameter, a file's row and a section are not")
    func signature() {
        func target(_ label: String, _ role: String = "AXRow") -> OperationCheck.Target {
            OperationCheck.Target(elementID: "e", role: role, label: label, section: nil)
        }
        let typed = { (text: String) in Self.step(.typeText, [("target", .literal(.text("foto_demo.png"))), ("text", .literal(.text(text))),
                                                               ("replace", .literal(.boolean(true)))]) }
        #expect(ProcedureMethod.signature(of: typed("a.jpg"), target: target("foto_demo.png", "AXTextField"))
                == ProcedureMethod.signature(of: typed("b.jpg"), target: target("foto_4 copy.psd", "AXTextField")))
        let row = { (file: String) in Self.step(.act, [("target", .literal(.text("control|\(file)"))), ("verb", .literal(.text("click"))),
                                                        ("section", .literal(.text("list view / Today")))]) }
        #expect(ProcedureMethod.signature(of: row("foto3png"), target: target("foto_3.png"))
                == ProcedureMethod.signature(of: row("foto4png"), target: target("foto_4.png")), "a file's row is an item")
        let menu = { (path: String) in Self.step(.menu, [("path", .literal(.text(path)))]) }
        #expect(ProcedureMethod.signature(of: menu("Immagine > Regolazioni > Inverti"), target: nil)
                != ProcedureMethod.signature(of: menu("Immagine > Metodo > Scala di grigio"), target: nil))
        let button = { (title: String) in Self.step(.act, [("target", .literal(.text(title))), ("verb", .literal(.text("click")))]) }
        #expect(ProcedureMethod.signature(of: button("Open"), target: target("Open", "AXButton"))
                != ProcedureMethod.signature(of: button("Cancel"), target: target("Cancel", "AXButton")), "a button is its title")
        let parameter = Self.step(.select, [("control", .literal(.text("Inputs"))), ("item", .parameter("p"))])
        let other = Self.step(.select, [("control", .literal(.text("BrausPhotoCraft"))), ("item", .parameter("q"))])
        #expect(ProcedureMethod.signature(of: parameter, target: nil) == ProcedureMethod.signature(of: other, target: nil),
                "a parameter is the same whatever its value, and a pop-up is its role")
        #expect(!ProcedureMethod.same([], []) && ProcedureMethod.same(["a", "b"], ["a", "b"]) && !ProcedureMethod.same(["a"], ["a", "b"]))
    }

    @Test("the same method despite: a dialog's button pressed or clicked, a file's row named or a parameter, a form's fields in another order")
    func tolerance() {
        func target(_ label: String, _ role: String) -> OperationCheck.Target {
            OperationCheck.Target(elementID: "e", role: role, label: label, section: nil)
        }
        let press = ProcedureMethod.signature(of: Self.step(.press, [("button", .literal(.text("Save")))]), target: nil)
        let click = ProcedureMethod.signature(of: Self.step(.act, [("target", .literal(.text("Save"))), ("verb", .literal(.text("click")))]),
                                              target: target("Save", "AXButton"))
        #expect(press == click)
        let cancel = ProcedureMethod.signature(of: Self.step(.press, [("button", .literal(.text("Cancel")))]), target: nil)
        #expect(cancel != click, "another button is another method")
        let named = ProcedureMethod.signature(of: Self.step(.act, [("target", .literal(.text("control|foto1png"))), ("verb", .literal(.text("click")))]),
                                              target: target("foto_1.png", "AXRow"))
        let parameter = ProcedureMethod.signature(of: Self.step(.act, [("target", .parameter("p")), ("verb", .literal(.text("click")))]),
                                                  target: target("foto_3.png", "AXRow"))
        #expect(named == parameter, "a file's row by its name or by the task's value")
        let name = ProcedureMethod.signature(of: Self.step(.typeText, [("target", .literal(.text("control|foto1copypsd"))), ("text", .parameter("n")),
                                                                        ("replace", .literal(.boolean(true)))]), target: target("foto_1 copy.psd", "AXTextField"))
        let folder = ProcedureMethod.signature(of: Self.step(.select, [("control", .literal(.text("Inputs"))), ("item", .parameter("f"))]),
                                               target: target("Inputs", "AXPopUpButton"))
        let format = ProcedureMethod.signature(of: Self.step(.select, [("control", .literal(.text("Format"))), ("item", .literal(.text("JPEG")))]),
                                               target: target("Format", "AXPopUpButton"))
        let anyFormat = ProcedureMethod.signature(of: Self.step(.select, [("control", .literal(.text("Format"))), ("item", .parameter("x"))]),
                                                  target: target("Format", "AXPopUpButton"))
        let open = ProcedureMethod.signature(of: Self.step(.menu, [("path", .literal(.text("File > Save a Copy…")))]), target: nil)
        #expect(ProcedureMethod.same([open, name, folder, press], [open, folder, name, click]), "a form's fields in any order")
        #expect(!ProcedureMethod.same([open, name, press], [name, open, press]), "a menu and a field are not a form's fields")
        #expect(ProcedureMethod.same([open, format], [open, anyFormat]), "a fixed choice made a parameter covers its value")
        #expect(!ProcedureMethod.same([open, name, folder, press], [open, name, press, folder]), "the button ends the form")
    }

    @Test("a section that names a day, an hour or a file is no part of a method; a panel's name is")
    func stableSections() {
        for section in ["list view / Today at 15:52", "Yesterday", "Oggi", "14/10/2026", "content (foto_1.png @ 100% (RGB/8))"] {
            #expect(!ProcedureAssembly.isStableSection(section), "\(section)")
        }
        for section in ["sidebar", "toolbar", "list view", "Favorites", "content"] {
            #expect(ProcedureAssembly.isStableSection(section), "\(section)")
        }
    }

    @Test("the result check passes a file written during the task and fails one missing or older")
    func resultVerdict() {
        #expect(TaskResultCheck.file("/a", attemptID: "t", openedAtMS: 10_000, modifiedAtMS: 12_000).verdict == .passed)
        #expect(TaskResultCheck.file("/a", attemptID: "t", openedAtMS: 10_000, modifiedAtMS: 9_000).verdict == .passed,
                "within the clocks' tolerance")
        #expect(TaskResultCheck.file("/a", attemptID: "t", openedAtMS: 10_000, modifiedAtMS: 7_000).verdict == .failed)
        #expect(TaskResultCheck.file("/a", attemptID: "t", openedAtMS: 10_000, modifiedAtMS: nil).verdict == .failed)
    }

    @Test("qualification B: a passed result covers a step only unproven or delivered uncertainly, never a failed check or another gesture")
    func policyB() throws {
        let part = try ProcedurePart(partID: "v/procedure", routeID: "v", kind: .procedure, parentPartID: nil, firstPosition: 0,
                                     lastPosition: 1, stepID: nil, bundleID: nil, label: "p", declaredOutcome: .completed)
        func fact(_ verdict: OperationCheck.Verdict, performed: OperationCheck.Performed = .requested) -> QualificationPolicy.VerificationFact {
            QualificationPolicy.VerificationFact(eventID: "v\(verdict)", condition: .structuralEffect, verdict: verdict, performed: performed,
                                                 limits: [])
        }
        func step(_ position: Int, _ facts: [QualificationPolicy.VerificationFact]) -> QualificationPolicy.StepFacts {
            QualificationPolicy.StepFacts(position: position, callEventID: "c\(position)", status: .completed, hasRecordingGap: false,
                                          verifications: facts)
        }
        func evaluate(_ second: [QualificationPolicy.VerificationFact], result: VerificationVerdict?) -> PartQualification {
            QualificationPolicy.evaluate(QualificationPolicy.PartFacts(part: part, attemptEnd: .completed, interpretationState: .ended,
                                                                       steps: [step(0, [fact(.passed)]), step(1, second)], result: result))
        }
        #expect(evaluate([fact(.unknown)], result: .passed).verdict == .admitted)
        #expect(evaluate([], result: .passed).verdict == .admitted, "no check at all is unproven too")
        #expect(evaluate([fact(.unknown)], result: nil).findings.map(\.reason) == [.verificationUnknown])
        #expect(evaluate([fact(.failed)], result: .passed).findings.map(\.reason) == [.verificationFailed])
        #expect(evaluate([fact(.unknown, performed: .uncertain)], result: .passed).verdict == .admitted,
                "an uncertain delivery is unproven, not refuted")
        #expect(evaluate([fact(.unknown, performed: .uncertain)], result: nil).verdict == .refused)
        #expect(evaluate([fact(.passed, performed: .substitute)], result: .passed).verdict == .refused, "another gesture than the one asked")
        #expect(evaluate([fact(.passed)], result: .failed).findings.map(\.reason) == [.verificationFailed],
                "a result not on disk keeps out a procedure whose every step passed")
    }
}
