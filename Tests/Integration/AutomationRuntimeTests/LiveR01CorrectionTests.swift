//
//  LiveR01CorrectionTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
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

/// LiveR01CorrectionTests reproduce, through the product's tools and a new acquisition, the defects the live run R01
/// found in our part of the cycle, and prove their corrections. LV02: an ordinary folder path was withheld as a
/// credential, so its use in the step that typed it was refused and the folder stayed a constant of R01. LV03: a need
/// naming its application by name was compared with the parts' bundle IDs, so a Memory of qualified steps only (a failed
/// parent) was filtered out whole. Only the operating system and the applications are replaced (`LearningSession`); the
/// rows read back were written by the producers. These are integration proofs, not a live run.
@MainActor
@Suite("Corrections of the live run R01, through the tools", .serialized)
struct LiveR01CorrectionTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    static let folderA = "/private/tmp/mecum-live-2026-10-12-R01/Inputs/A"
    static let folderB = "/private/tmp/mecum-live-2026-10-13-R02-haiku/Inputs/B"

    /// Finder's window, the Go to Folder sheet it opens and the folder it shows after.
    @MainActor enum Finder {
        static let goField = SceneElement(id: "field|go", kind: .control, label: "Go to the folder:",
                                          bounds: NormalizedRect(x: 0.3, y: 0.2, width: 0.4, height: 0.04), role: "AXTextField",
                                          labelOrigin: .description)
        static let window = LearningSession.Window(elements: [
            LearningSession.row("Inputs", y: 0.3), LearningSession.row("Outputs", y: 0.34),
        ], title: "R01")
        static let sheet = LearningSession.Window(elements: [goField, LearningSession.button("Go", x: 0.8),
                                                             LearningSession.button("Cancel", x: 0.7)],
                                                  surface: .dialog, title: "Go to Folder")
        static let folder = LearningSession.Window(elements: [
            LearningSession.row("campione_A.png", y: 0.3), LearningSession.row("note.txt", y: 0.34),
        ], title: "A")
    }

    static func finderSession(_ directory: URL) -> LearningSession {
        let session = LearningSession(directory: directory)
        session.windows[P.finder] = Finder.window
        session.script["menu|Go > Go to Folder…"] = LearningSession.Outcome(next: Finder.sheet)
        session.script["press|Go"] = LearningSession.Outcome(next: Finder.folder)
        return session
    }

    /// Goes to `folder` through Finder's sheet and selects the image there: three steps, the second typing the folder.
    static func goToFolder(_ tools: AutomationTools, _ session: LearningSession, _ folder: String) async throws {
        let id = session.id!.uuidString
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await P.call(tools, "menu", #"{"session":"\#(id)","path":"Go > Go to Folder…"}"#)
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"Go to the folder:","text":"\#(folder)"}"#)
        _ = try await P.call(tools, "press", #"{"session":"\#(id)","button":"Go"}"#)
    }

    static func interpretation(_ candidate: String) -> String {
        """
        {"operation":"interpret","candidate":"\(candidate)",
         "procedure":{"label":"Open <source_folder> in Finder","outcome":"completed"},
         "parts":[{"part":"b1","label":"Open <source_folder> in Finder","outcome":"completed"}],
         "steps":[{"step":1,"label":"Open the Go to Folder sheet"},{"step":2,"label":"Type <source_folder>"},
                  {"step":3,"label":"Confirm with Go"}],
         "parameters":[{"name":"source_folder","role":"folder holding the input image","kind":"folder"}],
         "uses":[{"step":2,"argument":"text","template":"{source_folder}"}]}
        """
    }

    /// Learns the folder navigation through the tools, with `folder` as the task's input; answers the interpretation's
    /// answer and the version's id.
    static func learnFolder(_ session: LearningSession, _ folder: String) async throws -> (JSONValue, String) {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Open the folder of the input image in Finder","recall":false,
             "inputs":[{"name":"source_folder","value":"\#(folder)","kind":"folder","role":"folder holding the input image"}]}
            """#)
        try await goToFolder(tools, session, folder)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string, "\(ended)")
        let interpreted = try await P.task(tools, Self.interpretation(candidate))
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        return (interpreted, ProcedureAssembly.routeID(candidateID: candidate, revision: 1))
    }

    // MARK: LV02

    @Test("live R01 LV02: a folder path is kept and typed as given, its use is checked and admitted, and a new task binds its own folder")
    func folderParameter() async throws {
        do {
            let session = Self.finderSession(try W.directory())
            let (interpreted, routeID) = try await Self.learnFolder(session, Self.folderA)
            #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
            #expect(interpreted["findings"] == .null, "the use reproduces the recorded folder: \(interpreted)")
            let refused = (interpreted["parts"].array ?? []).filter { $0["admitted"].bool == false }
            #expect(refused.isEmpty, "\(refused)")
            let file = L.url(session)
            #expect(try rawRows("SELECT count(*) FROM memory_value_redactions", at: file) == ["0"])
            #expect(try rawRows("SELECT name || '=' || ifnull(text_value, '') || ':' || sensitivity FROM memory_task_values ORDER BY position",
                                at: file) == ["source_folder=\(Self.folderA):ordinary"])
            let memory = MemoryService.shared(for: session.directory)
            let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
            #expect(stored.version.withheldLiteralSteps.isEmpty)
            let typed = try #require(stored.version.definition.steps[1].operations[0].arguments.first { $0.name == "text" })
            guard case .parameter = typed.value else { Issue.record("the folder is no parameter: \(typed.value)"); return }

            // A new task in another folder: the proposal binds the source's parameter to its own folder, never to R01's.
            let tools = P.tools(session, stream: "second")
            let begun = try await P.task(tools, #"""
                {"operation":"begin","goal":"Open the folder of the new image in Finder","recall_mode":"propose",
                 "needs":[{"text":"Open the folder of the input image in Finder","app":"com.apple.finder"}],
                 "inputs":[{"name":"source_folder","value":"\#(Self.folderB)","kind":"folder","role":"folder holding the input image"}]}
                """#)
            let proposal = begun["recall_proposal"]
            let source = try #require(proposal["sources"].array?.first { $0["version"].string == routeID }, "\(proposal)")
            let parameters = "\(source["parameters"])"
            #expect(parameters.contains(Self.folderB) && !parameters.contains(Self.folderA), "\(parameters)")
            let chosen = try await P.task(tools, RecallChoiceToolTests.choose(try #require(proposal["proposal"].string),
                                                                             [(try #require(source["source"].string), 1, 3)]))
            let tract = try #require(chosen["recall"]["needs"].array?.first?["tracts"].array?.first, "\(chosen)")
            let bound = (tract["parameters"].array ?? []).first { $0["name"].string == "source_folder" }
            #expect(bound?["status"].string == "bound" && bound?["value"].string == Self.folderB, "\(tract)")
            await L.close(session)
        }
    }

    @Test("live R01 LV02: a key inside a folder path is still withheld, and a use that would make it an ordinary parameter is still refused")
    func keyInFolder() async throws {
        let key = "Qx7Lm2Np9Rs4Tv6Wy8Zb1Cd3Fg5Hj7Kk9M"
        let folder = "/Users/Tester/Library/Caches/\(key)/state"
        let session = Self.finderSession(try W.directory())
        let (interpreted, routeID) = try await Self.learnFolder(session, folder)
        let findings = "\(interpreted["findings"])"
        #expect(findings.contains("use_mismatch"), "a withheld value is taken only by a secret parameter: \(interpreted)")
        let file = L.url(session)
        #expect(try rawRows("SELECT count(*) > 0 FROM memory_value_redactions", at: file) == ["1"])
        #expect(try rawRows("SELECT name || ':' || content || ':' || sensitivity FROM memory_task_values ORDER BY position",
                            at: file) == ["source_folder:withheld:ordinary"])
        let memory = MemoryService.shared(for: session.directory)
        _ = await memory.flush(within: .seconds(10))
        #expect(try archiveOccurrences(of: key, in: file).isEmpty, "the key reaches no row")
        let stored = try #require(try await memory.perform { try await $0.procedures.version(routeID) })
        #expect(stored.version.withheldLiteralSteps == [1], "the step keeps the marker, never the key")
        await L.close(session)
    }

    // MARK: Workspace event 113

    @Test("live R01 Workspace 113: a call that needs a session, with none open, is refused as such, never as the memory's failure; nothing is recorded")
    func noSessionIsNoMemoryFailure() async throws {
        let session = Self.finderSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"{"operation":"begin","goal":"Open the folder","recall":false}"#)
        session.id = nil
        let error = await #expect(throws: AutomationFailure.self) {
            try await tools.call("menu", P.json(#"{"session":"\#(UUID().uuidString)","path":"Go > Go to Folder…"}"#))
        }
        let text = error.map { "\($0)" } ?? ""
        #expect(text.contains("needs an open session") && !text.contains("memory"), "\(text)")
        #expect(session.gestures.isEmpty, "nothing was done")
        #expect(try rawRows("SELECT count(*) FROM memory_agent_actions", at: L.url(session)) == ["0"])
        await L.close(session)
    }

    // MARK: LV03

    /// The applications the session offers the `apps` tool: Preview by its Italian name, as an Italian Mac shows it, and Finder.
    static let offered = [ApplicationCandidate(name: "Anteprima", bundleID: P.preview, version: "11.0", isRunning: true),
                          ApplicationCandidate(name: "Finder", bundleID: P.finder, version: "27.0", isRunning: true)]

    /// Learns the photo export through the tools as a task that failed: the parent procedure is refused and its steps,
    /// each verified, are admitted on their own, as R01's Memory was. Answers the version's id.
    static func learnFailedPhoto(_ session: LearningSession) async throws -> String {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"failed","note":"the export did not reach the folder"}"#)
        let candidate = try #require(ended["candidate"]["id"].string, "\(ended)")
        let interpretation = P.photoInterpretation(candidate)
            .replacingOccurrences(of: #"rotate it in Preview and export it as <name>.<extension>"}"#,
                                  with: #"rotate it in Preview and export it as <name>.<extension>","outcome":"failed"}"#)
        let interpreted = try await P.task(tools, interpretation)
        let parts = interpreted["parts"].array ?? []
        #expect(parts.first { $0["part"].string == "procedure" }?["admitted"].bool == false, "\(interpreted)")
        #expect(parts.contains { $0["part"].string?.hasPrefix("s") == true && $0["admitted"].bool == true }, "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        let routeID = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
        // Every entry of the index runs in one application: nothing general can hide the filter.
        let general = try rawRows("""
            SELECT sum(p.app_id IS NULL) || '/' || count(*) FROM memory_recall_entries e
            JOIN memory_recall_generations g ON g.generation_id = e.generation_id JOIN memory_procedure_parts p ON p.part_id = e.part_id
            WHERE g.status = 'ready'
            """, at: L.url(session))
        #expect(general.first?.hasPrefix("0/") == true && general.first != "0/0", "\(general)")
        return routeID
    }

    /// Proposes for the export of the photo with the need bound to `app`; answers the proposal and the search note recorded.
    static func propose(_ session: LearningSession, app: String, stream: String) async throws -> (JSONValue, String?) {
        let tools = P.tools(session, stream: stream)
        let begun = try await P.task(tools, #"""
            {"operation":"begin","goal":"Rotate the photo right and export it","recall_mode":"propose",
             "needs":[{"text":"Rotate the image right and export it","app":"\#(app)"}],
             "inputs":[{"name":"output_name","value":"foto_mail"},{"name":"output_extension","value":"png"}]}
            """#)
        let id = begun["recall_proposal"]["proposal"].string ?? ""
        let note = try rawRows("SELECT ifnull(search_note, '') FROM memory_recall_proposals WHERE proposal_id = '\(id)'", at: L.url(session)).first
        _ = try await P.task(tools, #"{"operation":"end","outcome":"abandoned"}"#)
        return (begun["recall_proposal"], note.flatMap { $0.isEmpty ? nil : $0 })
    }

    @Test("live R01 LV03: the steps of a failed task are offered whether the need names the application by name, by its localized name or by bundle ID",
          arguments: ["Preview", "preview", "Anteprima", "com.apple.Preview", "COM.APPLE.PREVIEW", "Preview.app"])
    func partialMemoryByAnyName(_ app: String) async throws {
        do {
            let session = P.photoSession(try W.directory())
            session.offered = Self.offered
            let routeID = try await Self.learnFailedPhoto(session)
            let (proposal, note) = try await Self.propose(session, app: app, stream: "lv03")
            #expect((proposal["sources"].array ?? []).contains { $0["version"].string == routeID }, "app=\(app), proposal=\(proposal)")
            #expect(proposal["needs"].array?.first?["app"].string == "Preview", "the need records the resolved application")
            #expect(note == nil || !(note ?? "").contains("could not be resolved"), "\(note ?? "")")
            #expect(try rawRows("SELECT ifnull(bundle_id, '') FROM memory_recall_proposal_needs", at: L.url(session)).allSatisfy { $0 == P.preview })
            await L.close(session)
        }
    }

    @Test("live R01 LV03: an application certainly other excludes the steps; an unknown or ambiguous name excludes nothing and says so")
    func otherUnknownAmbiguous() async throws {
        do {
            let session = P.photoSession(try W.directory())
            session.offered = Self.offered + [ApplicationCandidate(name: "TextEdit", bundleID: "com.apple.TextEdit", version: "1.20", isRunning: true),
                                              ApplicationCandidate(name: "Prevista", bundleID: "com.example.Prevista", version: "1", isRunning: true)]
            let routeID = try await Self.learnFailedPhoto(session)
            func has(_ proposal: JSONValue) -> Bool { (proposal["sources"].array ?? []).contains { $0["version"].string == routeID } }
            let (byBundle, _) = try await Self.propose(session, app: "com.apple.TextEdit", stream: "other-1")
            #expect(!has(byBundle), "a bundle ID is a certain identity: \(byBundle)")
            let (byName, _) = try await Self.propose(session, app: "TextEdit", stream: "other-2")
            #expect(!has(byName), "the open TextEdit is certainly another application: \(byName)")
            let (unknown, unknownNote) = try await Self.propose(session, app: "Pixelmator Pro", stream: "unknown")
            #expect(has(unknown), "an application nobody knows hides nothing: \(unknown)")
            #expect((unknownNote ?? "").contains("Pixelmator Pro") && (unknownNote ?? "").contains("could not be resolved"), "\(unknownNote ?? "")")
            #expect(unknown["needs"].array?.first?["app"] == .null)
            let (ambiguous, ambiguousNote) = try await Self.propose(session, app: "Prev", stream: "ambiguous")
            #expect(has(ambiguous), "a name two applications share hides nothing: \(ambiguous)")
            #expect((ambiguousNote ?? "").contains("ambiguous"), "\(ambiguousNote ?? "")")
            await L.close(session)
        }
    }

    @Test("live R01 LV03: R01's own Finder steps, learned again through the tools in a failed task, are found by Finder and by com.apple.finder",
          arguments: ["Finder", "com.apple.finder"])
    func failedFinderTask(_ app: String) async throws {
        do {
            let session = Self.finderSession(try W.directory())
            session.offered = Self.offered
            let memory = MemoryService.shared(for: session.directory)
            RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
            let tools = P.tools(session)
            _ = try await P.task(tools, #"""
                {"operation":"begin","goal":"Open the folder of the input image in Finder","recall":false,
                 "inputs":[{"name":"source_folder","value":"\#(Self.folderA)","kind":"folder"}]}
                """#)
            try await Self.goToFolder(tools, session, Self.folderA)
            let ended = try await P.task(tools, #"{"operation":"end","outcome":"failed"}"#)
            let candidate = try #require(ended["candidate"]["id"].string)
            let interpretation = Self.interpretation(candidate).replacingOccurrences(of: #""label":"Open <source_folder> in Finder","outcome":"completed"},"parts""#,
                                                                                     with: #""label":"Open <source_folder> in Finder","outcome":"failed"},"parts""#)
            _ = try await P.task(tools, interpretation)
            #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
            let routeID = ProcedureAssembly.routeID(candidateID: candidate, revision: 1)
            let second = P.tools(session, stream: "lv03-finder")
            let begun = try await P.task(second, #"""
                {"operation":"begin","goal":"Open the folder of the new image","recall_mode":"propose",
                 "needs":[{"text":"Open the Go to Folder sheet and type the folder","app":"\#(app)"}],
                 "inputs":[{"name":"source_folder","value":"\#(Self.folderB)","kind":"folder"}]}
                """#)
            #expect((begun["recall_proposal"]["sources"].array ?? []).contains { $0["version"].string == routeID }, "\(begun)")
            await L.close(session)
        }
    }
}
