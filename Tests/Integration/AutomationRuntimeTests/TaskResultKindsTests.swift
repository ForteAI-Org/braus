//
//  TaskResultKindsTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import TestScratch
import Testing

/// A task's result is not always a new file (14 October 2026): a file changed in place, an original kept, a switch the
/// app shows, a window closed, or nothing to read. Braus reads each kind itself, and a stage checked at a checkpoint
/// verifies the phase before it.
@MainActor
@Suite("The kinds of a task's result", .serialized)
struct TaskResultKindsTests {

    typealias P = ProcedureLearningTests

    static let unknownEffect = ProcedureMethodTests.unknownEffect

    /// A folder of the person's files, apart from the archive's, as on a Mac: what a task reads and writes.
    static func workFolder() throws -> URL {
        let folder = Scratch.directory("braus-lavoro")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("a file changed in place passes when its content differs from the start, and fails when it was only saved again")
    func aFileChangedInPlace() async throws {
        for changed in [true, false] {
            let directory = try W.directory()
            let work = try Self.workFolder()
            let document = work.appendingPathComponent("lettera.txt")
            try Data("prima".utf8).write(to: document)
            let original = work.appendingPathComponent("originale.txt")
            try Data("intatto".utf8).write(to: original)
            let session = ProcedureMethodTests.session(directory, unknownMarkup: true)
            let tools = P.tools(session)
            let id = session.id!.uuidString
            _ = try await P.task(tools, #"""
                {"operation":"begin","goal":"Rotate the document and save it in place","recall":false,
                 "inputs":[{"name":"document","value":"\#(document.path)","kind":"file","role":"the document to change"},
                           {"name":"original","value":"\#(original.path)","kind":"file","role":"a file to leave as it is"}]}
                """#)
            _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
            _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
            // Saved: written again, with new content or the same one.
            try await Task.sleep(for: .milliseconds(20))
            try Data((changed ? "dopo" : "prima").utf8).write(to: document)
            let ended = try await P.task(tools, #"""
                {"operation":"end","outcome":"completed","result_check":[{"file_changed":"\#(document.path)"},
                 {"file_unchanged":"\#(original.path)"}]}
                """#)
            let verdicts = ended["result_check"].array?.map { $0["verdict"].string ?? "" }
            #expect(verdicts == [changed ? "passed" : "failed", "passed", "passed"], "the folder's guard third: \(ended["result_check"])")
            let candidate = try #require(ended["candidate"]["id"].string)
            let interpreted = try await P.task(tools, #"""
                {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Mark up the document and save it","outcome":"completed"},
                 "steps":[{"step":1,"label":"Show the markup bar"}]}
                """#)
            let procedure = (interpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }
            #expect(procedure?["admitted"].bool == changed, "\(interpreted)")
            #expect(try P.rows("SELECT method || ':' || verdict FROM memory_verifications WHERE scope = 'task' ORDER BY rowid", in: session)
                    == ["file_check:\(changed ? "passed" : "failed")", "file_check:passed", "guard:passed"], "the folder's guard is a guard")
            await MemoryService.shared(for: directory).close()
            try? FileManager.default.removeItem(at: work)
        }
    }

    @Test("a task with no file: the switch the app shows, checked at a checkpoint, verifies the phase before it and the procedure")
    func aSwitchCheckedAtACheckpoint() async throws {
        for expected in ["off", "on"] {
            let directory = try W.directory()
            let session = P.photoSession(directory)
            var off = P.Finder.window
            off.elements = off.elements.map { $0.label == "Show Preview" ? LearningSession.checkbox("Show Preview", state: .off) : $0 }
            session.script["act|Show Preview"] = LearningSession.Outcome(kind: .actedUnverified, check: Self.unknownEffect, next: off)
            session.script["act|Search"] = LearningSession.Outcome(kind: .actedUnverified, check: Self.unknownEffect)
            let tools = P.tools(session)
            let id = session.id!.uuidString
            _ = try await P.task(tools, #"{"operation":"begin","goal":"Turn off Show Preview in Finder","recall":false}"#)
            _ = try await P.call(tools, "open_session", #"{"app":"\#(P.finder)"}"#)
            _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Show Preview"}"#)
            let checkpoint = try await P.task(tools, #"""
                {"operation":"checkpoint","note":"switched","result_check":{"element":"Show Preview","state":"\#(expected)"}}
                """#)
            #expect(checkpoint["result_check"].array?.first?["verdict"].string == (expected == "off" ? "passed" : "failed"),
                    "\(checkpoint)")
            _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Search"}"#)
            let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
            #expect(ended["result_check"] == nil || ended["result_check"] == .null,
                    "the checkpoint read the result: nothing is missing at the end: \(ended)")
            let candidate = try #require(ended["candidate"]["id"].string)
            let interpreted = try await P.task(tools, #"""
                {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Turn off a Finder switch","outcome":"completed"},
                 "phases":[{"from":1,"to":1,"label":"Turn the switch off"},{"from":2,"to":2,"label":"Go back to the search"}],
                 "steps":[{"step":1,"label":"Turn off Show Preview"},{"step":2,"label":"Click the search field"}],
                 "result_check":{"none":"the setting is shown only in the window"}}
                """#)
            #expect(interpreted["result_check"]["status"].string == "already checked", "\(interpreted)")
            let parts = Dictionary(uniqueKeysWithValues: (interpreted["parts"].array ?? []).map {
                ($0["part"].string ?? "", $0["admitted"].bool == true)
            })
            #expect(parts["steps 1–1"] == (expected == "off"), "the checkpoint's check verifies the phase before it: \(interpreted)")
            #expect(parts["procedure"] == (expected == "off"), "\(interpreted)")
            #expect(parts["steps 2–2"] == false, "no check follows the second phase, whose step is unknown: \(interpreted)")
            await MemoryService.shared(for: directory).close()
        }
    }

    @Test("an end that said it leaves nothing to read is asked for its result, and the check named at the interpretation is read")
    func noneAtTheEndThenAFile() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(tools, session, name: "foto_web", mistakes: false)
        let file = try ProcedureMethodTests.written(directory, "foto_web")
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed","result_check":{"none":"nothing to read"}}"#)
        #expect(ended["result_check"].array?.first?["verdict"].string == "unknown", "\(ended)")
        let candidate = try #require(ended["candidate"]["id"].string)
        var interpretation = ProcedureMethodTests.interpretation(candidate, mistakes: false)
        interpretation.removeLast()
        interpretation += #","result_check":{"file":"\#(file.path)"}}"#
        let interpreted = try await P.task(tools, interpretation)
        #expect(interpreted["result_check"].array?.first?["verdict"].string == "passed",
                "a none is no reading: the file named now is read: \(interpreted)")
        await MemoryService.shared(for: directory).close()
    }

    @Test("an end with no result check and a file output by its path checks that file; one named in interpret is read then")
    func resultFromOutputsOrInterpretation() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(tools, session, name: "foto_web", mistakes: false)
        let file = try ProcedureMethodTests.written(directory, "foto_web")
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","outputs":[{"name":"exported","value":"\#(file.path)","kind":"file"}]}
            """#)
        #expect(ended["result_check"].array?.first?["check"].string?.hasPrefix("file_written") == true, "\(ended)")
        #expect(ended["result_check"].array?.first?["verdict"].string == "passed")
        await MemoryService.shared(for: directory).close()

        let other = try W.directory()
        let second = ProcedureMethodTests.session(other)
        let worker = P.tools(second)
        _ = try await P.task(worker, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(worker, second, name: "foto_web", mistakes: false)
        let written = try ProcedureMethodTests.written(other, "foto_web")
        let end = try await P.task(worker, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(end["candidate"]["id"].string)
        var interpretation = ProcedureMethodTests.interpretation(candidate, mistakes: false)
        interpretation.removeLast()
        interpretation += #","result_check":{"file_written":"\#(written.path)"}}"#
        let interpreted = try await P.task(worker, interpretation)
        #expect(interpreted["result_check"].array?.first?["verdict"].string == "passed", "\(interpreted)")
        #expect((interpreted["parts"].array ?? []).allSatisfy { $0["admitted"].bool == true }, "\(interpreted)")
        await MemoryService.shared(for: other).close()
    }

    @Test("a task that wrote another file leaves its file input intact: Braus adds the guard and shows a rewritten original, without refusing the procedure")
    func originalGuard() async throws {
        for rewritten in [false, true] {
            let directory = try W.directory()
            let original = try Self.workFolder().appendingPathComponent("foto_demo.png")
            try Data("originale".utf8).write(to: original)
            let session = ProcedureMethodTests.session(directory)
            let tools = P.tools(session)
            _ = try await P.task(tools, #"""
                {"operation":"begin","goal":"Rotate the open image and export it as foto_web.jpg in JPEG","recall":false,
                 "inputs":[{"name":"output_name","value":"foto_web","role":"name of the exported file without extension"},
                           {"name":"photo","value":"\#(original.path)","kind":"file","role":"the photo to export"}]}
                """#)
            try await ProcedureMethodTests.run(tools, session, name: "foto_web", mistakes: false)
            if rewritten { try Data("cambiato".utf8).write(to: original) }
            let ended = try await P.task(tools, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_web")))
            let checks = ended["result_check"].array ?? []
            #expect(checks.count == 2 && checks.last?["check"].string?.hasPrefix("file_unchanged") == true, "\(checks)")
            #expect(checks.last?["verdict"].string == (rewritten ? "failed" : "passed"), "\(checks)")
            #expect(checks.last?["guard"].string != nil, "Braus's guard says it is one")
            let candidate = try #require(ended["candidate"]["id"].string)
            let interpreted = try await P.task(tools, ProcedureMethodTests.interpretation(candidate, mistakes: false))
            let procedure = (interpreted["parts"].array ?? []).first { $0["part"].string == "procedure" }
            #expect(procedure?["admitted"].bool == true, "a guard is shown, never what refuses the procedure: \(interpreted)")
            await MemoryService.shared(for: directory).close()
        }
    }

    @Test("a task that changes only what the app shows still keeps its file input: an original saved over by the app is shown by the guard")
    func anInAppTaskKeepsItsInput() async throws {
        for saved in [false, true] {
            let directory = try W.directory()
            let original = try Self.workFolder().appendingPathComponent("nota.txt")
            try Data("originale".utf8).write(to: original)
            let session = ProcedureMethodTests.session(directory, unknownMarkup: true)
            let tools = P.tools(session)
            let id = session.id!.uuidString
            _ = try await P.task(tools, #"""
                {"operation":"begin","goal":"Show the markup bar on the open document","recall":false,
                 "inputs":[{"name":"document","value":"\#(original.path)","kind":"file","role":"the open document"}]}
                """#)
            _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
            _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
            if saved { try Data("salvato da solo".utf8).write(to: original) }
            let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed","result_check":{"none":"the bar is shown only"}}"#)
            let guards = (ended["result_check"].array ?? []).filter { $0["guard"] != nil && $0["guard"] != .null }
            #expect(guards.count == 1 && guards.first?["check"].string?.hasPrefix("file_unchanged") == true, "\(ended["result_check"])")
            #expect(guards.first?["verdict"].string == (saved ? "failed" : "passed"), "\(guards)")
            let task = try #require(ended["task"].string)
            let archive = directory.appendingPathComponent("memory.sqlite")
            _ = await MemoryService.shared(for: directory).flush(within: .seconds(5))
            guard case .found(let before) = SQLiteMemoryInspection.tasks(in: archive, ids: [task]) else {
                Issue.record("the task was not read"); return
            }
            #expect(before.first?.guardsFailed == (saved ? 1 : 0), "a changed input no check names is counted")
            if saved {
                // The change was the task's own: named at the interpretation, it explains the guard.
                let interpreted = try await P.task(tools, #"""
                    {"operation":"interpret","candidate":"\#(try #require(ended["candidate"]["id"].string))",
                     "procedure":{"label":"Show the markup bar","outcome":"completed"},"steps":[{"step":1,"label":"Show the markup bar"}],
                     "result_check":{"file_changed":"\#(original.path)"}}
                    """#)
                #expect(interpreted["result_check"].array?.first?["verdict"].string == "passed", "\(interpreted)")
                guard case .found(let after) = SQLiteMemoryInspection.tasks(in: archive, ids: [task]) else {
                    Issue.record("the task was not read"); return
                }
                #expect(after.first?.guardsFailed == 0, "a check that passed on the same file explains the guard")
            }
            await MemoryService.shared(for: directory).close()
        }
    }

    @Test("an end whose use names no query is recorded: the use is answered as not recorded, the task ends and its candidate is built")
    func aBadUseDoesNotKeepTheTaskOpen() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(tools, session, name: "foto_web", mistakes: false)
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","use":[{"query":"no-such-query","need":1,"outcome":"followed"}]}
            """#)
        #expect(ended["status"].string == "ended", "\(ended)")
        #expect(ended["use_not_recorded"].array?.count == 1, "\(ended)")
        #expect(ended["candidate"]["id"].string != nil, "\(ended)")
        let status = try await P.task(tools, #"{"operation":"status"}"#)
        #expect(status["status"].string == "no open task", "\(status)")
        await MemoryService.shared(for: directory).close()
    }

    @Test("a screen check naming a file is read on disk too; a stray file in the folder fails the guard, which is shown as one")
    func whatBrausAdds() async throws {
        let directory = try W.directory()
        let folder = Scratch.directory("braus-lavoro")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("lavoro_A.png")
        try Data("prima".utf8).write(to: document)
        let session = ProcedureMethodTests.session(directory, unknownMarkup: true)
        let tools = P.tools(session)
        let id = session.id!.uuidString
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Mark up the image and save it in place","recall":false,
             "inputs":[{"name":"file","value":"\#(document.path)","kind":"file","role":"the image"}]}
            """#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.preview)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Markup"}"#)
        try await Task.sleep(for: .milliseconds(20))
        try Data("dopo".utf8).write(to: document)
        try Data("rtf".utf8).write(to: folder.appendingPathComponent("lavoro_A.png.rtf"))
        let ended = try await P.task(tools, #"""
            {"operation":"end","outcome":"completed","result_check":{"element":"Salvato: \#(document.path)","present":true}}
            """#)
        let checks = (ended["result_check"].array ?? []).map { ($0["check"].string ?? "").split(separator: " ").first.map(String.init) ?? "" }
        let verdicts = (ended["result_check"].array ?? []).map { $0["verdict"].string ?? "" }
        #expect(checks == ["element", "file_changed", "no_other_files"], "\(ended["result_check"])")
        #expect(verdicts == ["failed", "passed", "failed"], "the element is not in the double's scene; the file changed; a stray file appeared")
        #expect((ended["result_check"].array ?? []).map { $0["guard"] != .null } == [false, false, true])
        await MemoryService.shared(for: directory).close()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("a result check naming a relative path or a secret is refused before anything is recorded")
    func refusedChecks() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let tools = P.tools(session)
        _ = try await P.task(tools, ProcedureMethodTests.begin("foto_web"))
        let relative = try await P.task(tools, #"{"operation":"end","outcome":"completed","result_check":{"file_written":"foto.png"}}"#)
        #expect(relative["error"].string == "invalid_task", "\(relative)")
        let unknown = try await P.task(tools, #"{"operation":"end","outcome":"completed","result_check":{"folder":"/tmp"}}"#)
        #expect(unknown["error"].string == "invalid_task", "\(unknown)")
        await MemoryService.shared(for: directory).close()
    }
}

/// The verdicts of every kind of result, from what was read, and the record a kind keeps.
@Suite("Result checks by kind")
struct TaskResultJudgmentTests {

    typealias C = TaskResultCheck

    static func facts(_ modified: Int64, _ digest: String, holds: Bool? = nil) -> C.FileFacts {
        C.FileFacts(exists: true, modifiedAtMS: modified, size: 10, digest: digest, holdsText: holds)
    }

    @Test("the disk: written, changed, unchanged, absent and holding a text")
    func disk() {
        func judge(_ expectation: C.Expectation, before: C.FileFacts?, now: C.FileFacts) -> VerificationVerdict {
            C.judge(expectation, attemptID: "a", openedAtMS: 10_000, before: before, now: now).verdict
        }
        #expect(judge(.fileWritten(path: "/f"), before: nil, now: Self.facts(12_000, "x")) == .passed)
        #expect(judge(.fileWritten(path: "/f"), before: nil, now: .missing) == .failed)
        #expect(judge(.fileChanged(path: "/f"), before: Self.facts(5_000, "x"), now: Self.facts(12_000, "y")) == .passed)
        #expect(judge(.fileChanged(path: "/f"), before: Self.facts(5_000, "x"), now: Self.facts(12_000, "x")) == .failed,
                "saved again with the same content")
        #expect(judge(.fileChanged(path: "/f"), before: nil, now: Self.facts(12_000, "x")) == .passed, "no reading at the start: by time")
        #expect(judge(.fileChanged(path: "/f"), before: Self.facts(5_000, "x"), now: Self.facts(6_000, "y")) == .failed,
                "not written during the task")
        #expect(judge(.fileUnchanged(path: "/f"), before: Self.facts(5_000, "x"), now: Self.facts(5_000, "x")) == .passed)
        #expect(judge(.fileUnchanged(path: "/f"), before: Self.facts(5_000, "x"), now: Self.facts(12_000, "y")) == .failed)
        #expect(judge(.fileUnchanged(path: "/f"), before: nil, now: Self.facts(5_000, "x")) == .passed)
        #expect(judge(.fileAbsent(path: "/f"), before: Self.facts(5_000, "x"), now: .missing) == .passed)
        #expect(judge(.fileAbsent(path: "/f"), before: .missing, now: .missing) == .unknown, "nothing was there to remove")
        #expect(judge(.fileAbsent(path: "/f"), before: nil, now: Self.facts(5_000, "x")) == .failed)
        #expect(judge(.fileContains(path: "/f", text: "ciao"), before: nil, now: Self.facts(12_000, "x", holds: true)) == .passed)
        #expect(judge(.fileContains(path: "/f", text: "ciao"), before: nil, now: Self.facts(12_000, "x", holds: false)) == .failed)
        func move(_ expectation: C.Expectation, before: C.FileFacts?, from: C.FileFacts, to: C.FileFacts) -> VerificationVerdict {
            C.judge(expectation, attemptID: "a", openedAtMS: 10_000, before: before, now: from, other: to).verdict
        }
        let moved = C.Expectation.fileMoved(from: "/a", to: "/b")
        #expect(move(moved, before: Self.facts(5_000, "x"), from: .missing, to: Self.facts(5_000, "x")) == .passed,
                "a rename keeps the time of last writing: the content is what proves it")
        #expect(move(moved, before: Self.facts(5_000, "x"), from: Self.facts(5_000, "x"), to: Self.facts(5_000, "x")) == .failed)
        #expect(move(moved, before: Self.facts(5_000, "x"), from: .missing, to: Self.facts(5_000, "y")) == .failed)
        #expect(move(moved, before: nil, from: .missing, to: Self.facts(5_000, "x")) == .unknown)
        let copied = C.Expectation.fileCopied(from: "/a", to: "/b")
        #expect(move(copied, before: nil, from: Self.facts(5_000, "x"), to: Self.facts(5_000, "x")) == .passed)
        #expect(move(copied, before: nil, from: Self.facts(5_000, "x"), to: .missing) == .failed)
    }

    @Test("the screen: a window by its title, an element's value, state and presence")
    @MainActor
    func screen() {
        let scene = SceneSnapshot(bundleID: "b", appName: "B", windowTitle: "Impostazioni",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [
            SceneElement(id: "w", kind: .control, label: "Larghezza", bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                         role: "AXTextField", value: "640"),
            SceneElement(id: "g", kind: .control, label: "Griglia", bounds: NormalizedRect(x: 0.2, y: 0, width: 0.1, height: 0.1),
                         role: "AXCheckBox", state: .on),
        ])
        func judge(_ expectation: C.Expectation, windows: [String]? = nil, scene: SceneSnapshot? = scene) -> VerificationVerdict {
            C.judge(expectation, attemptID: "a", windows: windows, scene: scene).verdict
        }
        #expect(judge(.window(app: nil, title: "foto_1", open: true), windows: ["foto_1.png — PhotoCraft"]) == .passed)
        #expect(judge(.window(app: nil, title: "foto_1", open: false), windows: ["foto_1.png — PhotoCraft"]) == .failed)
        #expect(judge(.window(app: nil, title: "foto_1", open: false), windows: []) == .passed)
        #expect(judge(.window(app: nil, title: "foto_1", open: true), windows: nil) == .failed, "the application is not running")
        let unread = C.judge(.window(app: "Photo", title: "foto_1", open: false), attemptID: "a", openedAtMS: 0,
                             reading: .unread("the name given answers to several running applications"))
        #expect(unread.verdict == .unknown && unread.observed.contains("several"),
                "an application Braus could not read is never taken as one that is not running")
        #expect(RunningApplicationLookup.isNotRunning("com.example.never-installed-\(UUID().uuidString)"))
        #expect(!RunningApplicationLookup.isNotRunning("com.apple.finder"), "the Finder is always running")
        #expect(judge(.element(app: nil, label: "Larghezza", expect: .value("640"))) == .passed)
        #expect(judge(.element(app: nil, label: "larghezza", expect: .value("320"))) == .failed)
        #expect(judge(.element(app: nil, label: "Griglia", expect: .state(.on))) == .passed)
        #expect(judge(.element(app: nil, label: "Griglia", expect: .state(.off))) == .failed)
        #expect(judge(.element(app: nil, label: "Altezza", expect: .present)) == .failed)
        #expect(judge(.element(app: nil, label: "Altezza", expect: .absent)) == .passed)
        #expect(judge(.element(app: nil, label: "Griglia", expect: .state(.on)), scene: nil) == .unknown, "no session to read")
        #expect(judge(.nothing(reason: "r")) == .unknown)
        #expect(C.combined([.passed, .passed]) == .passed && C.combined([.passed, .failed]) == .failed
                && C.combined([.passed, .unknown]) == .unknown && C.combined([]) == nil)
    }

    @Test("every kind is kept as text and read back the same; the first version's plain path is a file written")
    func stored() {
        let kinds: [C.Expectation] = [
            .fileWritten(path: "/a/b.png"), .fileChanged(path: "/a"), .fileUnchanged(path: "/a"), .fileAbsent(path: "/a"),
            .fileContains(path: "/a.txt", text: "ciao \"mondo\""), .window(app: "PhotoCraft", title: "foto", open: false),
            .element(app: nil, label: "Larghezza", expect: .value("640")), .element(app: nil, label: "Griglia", expect: .state(.off)),
            .element(app: "X", label: "Y", expect: .present), .element(app: nil, label: "Y", expect: .absent), .nothing(reason: "niente"),
            .fileMoved(from: "/a", to: "/b"), .fileCopied(from: "/a", to: "/c"),
        ]
        for kind in kinds {
            #expect(C.Expectation(stored: kind.stored, method: kind.method) == kind, "\(kind.stored)")
        }
        #expect(C.Expectation(stored: "/Users/x/out.png", method: .fileCheck) == .fileWritten(path: "/Users/x/out.png"))
        #expect(C.Expectation(stored: "/Users/x/out.png", method: .controlValue) == nil)
    }
}

/// A procedure keeps how its result was checked as a template over its parameters, and a reuse receives it with its own
/// values (14 October 2026).
@MainActor
@Suite("The result check a procedure carries", .serialized)
struct ProcedureResultTemplateTests {

    typealias P = ProcedureLearningTests

    @Test("a template writes a run's values as parameters, and is bound again to another task's")
    func template() {
        let check = TaskResultCheck.Expectation.fileWritten(path: "/Users/x/Uscite/foto_1_inv.png")
        let values = [(name: "output_folder", value: "/Users/x/Uscite"), (name: "output_name", value: "foto_1_inv"),
                      (name: "input_name", value: "foto_1.png"), (name: "n", value: "1")]
        let template = check.template(over: values)
        #expect(template == .fileWritten(path: "{output_folder}/{output_name}.png"))
        #expect(template.parameterNames == ["output_folder", "output_name"])
        #expect(template.bound(to: ["output_folder": "/Users/y/Out", "output_name": "foto_3_inv"])
                == .fileWritten(path: "/Users/y/Out/foto_3_inv.png"))
        #expect(TaskResultCheck.Expectation.element(app: nil, label: "Larghezza", expect: .value("640"))
                .template(over: [(name: "width", value: "640")]) == .element(app: nil, label: "Larghezza", expect: .value("{width}")))
        #expect(TaskResultCheck.Expectation.fileWritten(path: "/a/foto_10.png").template(over: [(name: "n", value: "foto_1")])
                == .fileWritten(path: "/a/foto_10.png"), "only a whole name before the extension")
        #expect(TaskResultCheck.Expectation.element(app: nil, label: "Salvato: /Users/x/Lavoro/lavoro_A.png", expect: .present)
                .template(over: [(name: "folder", value: "/Users/x/Lavoro"), (name: "file_name", value: "lavoro_A.png"), (name: "n", value: "Salvato")])
                == .element(app: nil, label: "Salvato: {folder}/{file_name}", expect: .present), "a path and a file's name inside a text; other words stay")
    }

    @Test("a learned procedure proposes how its result was checked, and a whole choice delivers it with the new task's values")
    func proposedAndDelivered() async throws {
        let directory = try W.directory()
        let folder = Scratch.directory("braus-uscite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = ProcedureMethodTests.session(directory)
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: RecallLifecycleTests.configuration()))
        let learner = P.tools(session, stream: "learner")
        _ = try await P.task(learner, #"""
            {"operation":"begin","goal":"Rotate the open image and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"output_name","value":"foto_web","role":"name of the exported file without extension"},
                       {"name":"output_folder","value":"\#(folder.path)","kind":"folder","role":"folder of the exported file"}]}
            """#)
        try await ProcedureMethodTests.run(learner, session, name: "foto_web", mistakes: false)
        let written = folder.appendingPathComponent("foto_web.jpg")
        try Data("jpeg".utf8).write(to: written)
        let ended = try await P.task(learner, ProcedureMethodTests.end(result: written))
        let candidate = try #require(ended["candidate"]["id"].string)
        var interpretation = ProcedureMethodTests.interpretation(candidate, mistakes: false)
        interpretation = interpretation.replacingOccurrences(
            of: #""parameters":[{"name":"output_name","role":"name of the exported file","kind":"text"}]"#,
            with: #""parameters":[{"name":"output_name","role":"name of the exported file","kind":"text"},{"name":"output_folder","role":"folder of the exported file","kind":"folder"}]"#)
        let interpreted = try await P.task(learner, interpretation)
        let routeID = try #require(interpreted["version"].string, "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))

        let source = try #require(try await memory.perform { try await $0.recall.sources([routeID]) }.first)
        #expect(source.results.map(\.expectation) == [.fileWritten(path: "{output_folder}/{output_name}.jpg")], "\(source.results)")
        #expect(source.results.map(\.atEnd) == [true])
        #expect(source.resultVerdict == .passed)

        let chooser = P.tools(session, stream: "chooser")
        let begun = try await P.task(chooser, #"""
            {"operation":"begin","goal":"Rotate the open image and export it as foto_mail.jpg in JPEG",
             "inputs":[{"name":"output_name","value":"foto_mail","role":"name of the exported file without extension"},
                       {"name":"output_folder","value":"\#(folder.path)","kind":"folder","role":"folder of the exported file"}]}
            """#)
        let offered = try #require(begun["recall_proposal"]["sources"].array?.first { $0["version"].string == routeID }, "\(begun)")
        #expect(offered["result"].array?.compactMap(\.string) == ["at the end: file_written {output_folder}/{output_name}.jpg"], "\(offered)")
        #expect(offered["evidence"].string?.contains("result checked by Braus") == true, "\(offered)")
        let key = try #require(offered["source"].string)
        let proposal = try #require(begun["recall_proposal"]["proposal"].string)
        #expect(begun["recall_proposal"]["needs"].array?.first?["readyPlan"].string?.contains(#""source":"\#(key)""#) == true,
                "the need carries the plan item that chooses the first source: \(begun["recall_proposal"]["needs"])")
        // The plan declares the need covered as the suggestion covers it: a partial suggestion is no whole need.
        if let need = begun["recall_proposal"]["needs"].array?.first, let suggested = need["suggested"].string,
           let plan = need["readyPlan"].string {
            #expect(plan.contains(suggested.hasSuffix("(complete)") ? #""covered":"all""# : #""covered":"part""#), "\(need)")
        }
        let chosen = try await P.task(chooser, RecallChoiceToolTests.choose(proposal, [(key, 1, 5)]))
        let tract = chosen["recall"]["needs"].array?.first?["tracts"].array?.first
        #expect(tract?["resultCheck"].array?.compactMap(\.string) == ["at the end: file_written \(folder.path)/foto_mail.jpg"], "\(chosen)")
        await RecallLifecycleTests.close(session)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("a run that chose a learned source and did the work another way is that source's variant, from the step where they part")
    func aChosenSourceAdapted() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory, unknownMarkup: true)
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: RecallLifecycleTests.configuration()))
        let learner = P.tools(session, stream: "learner")
        _ = try await P.task(learner, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(learner, session, name: "foto_web", mistakes: false)
        let ended = try await P.task(learner, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_web")))
        let interpreted = try await P.task(learner, ProcedureMethodTests.interpretation(try #require(ended["candidate"]["id"].string),
                                                                                         mistakes: false))
        let source = try #require(interpreted["version"].string, "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))

        // The second run chooses the learned source and then adds a step of its own after the export.
        let adapter = P.tools(session, stream: "adapter")
        let begun = try await P.task(adapter, #"""
            {"operation":"begin","goal":"Rotate the open image and export it as foto_mail.jpg in JPEG, then show the markup bar",
             "inputs":[{"name":"output_name","value":"foto_mail","role":"name of the exported file without extension"}]}
            """#)
        let offered = try #require(begun["recall_proposal"]["sources"].array?.first { $0["version"].string == source }, "\(begun)")
        let proposal = try #require(begun["recall_proposal"]["proposal"].string)
        _ = try await P.task(adapter, RecallChoiceToolTests.choose(proposal, [(try #require(offered["source"].string), 1, 5)]))
        try await ProcedureMethodTests.run(adapter, session, name: "foto_mail", mistakes: false, unknownStep: true)
        let adapted = try await P.task(adapter, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_mail")))
        let second = try await P.task(adapter, ProcedureMethodTests.interpretation(try #require(adapted["candidate"]["id"].string),
                                                                                   mistakes: false, markup: true))
        let variant = try #require(second["version"].string, "\(second)")
        #expect(second["repeats"] == nil || second["repeats"] == .null, "another method is no repeat: \(second)")
        let stored = try #require(try await memory.perform { try await $0.procedures.version(variant) })
        #expect(stored.version.variantOf == source, "the chosen source is its origin")
        #expect(stored.version.divergencePosition == 5, "the five steps of the source, then its own")
        #expect(try P.rows("SELECT status FROM memory_variant_prefix_checks WHERE route_id = '\(variant)'", in: session) == ["verified"])
        await RecallLifecycleTests.close(session)
    }

    @Test("a run that repeats a proposed source without choosing it is said to have followed it unchosen")
    func followedWithoutAChoice() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: RecallLifecycleTests.configuration()))
        let learner = P.tools(session, stream: "learner")
        _ = try await P.task(learner, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(learner, session, name: "foto_web", mistakes: false)
        let first = try await P.task(learner, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_web")))
        let firstCandidate = try #require(first["candidate"]["id"].string)
        let firstInterpreted = try await P.task(learner, ProcedureMethodTests.interpretation(firstCandidate, mistakes: false))
        let firstVersion = try #require(firstInterpreted["version"].string)
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))

        let follower = P.tools(session, stream: "follower")
        let begun = try await P.task(follower, ProcedureMethodTests.begin("foto_mail").replacingOccurrences(of: #""recall":false,"#, with: ""))
        #expect(begun["recall_proposal"]["sources"].array?.contains { $0["version"].string == firstVersion } == true, "\(begun)")
        try await ProcedureMethodTests.run(follower, session, name: "foto_mail", mistakes: false)
        let second = try await P.task(follower, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_mail")))
        let secondCandidate = try #require(second["candidate"]["id"].string)
        let interpreted = try await P.task(follower, ProcedureMethodTests.interpretation(secondCandidate, mistakes: false))
        #expect(interpreted["repeats"].string == firstVersion, "\(interpreted)")
        #expect(interpreted["reuse"].string?.contains("without choosing it") == true, "\(interpreted)")
        await RecallLifecycleTests.close(session)
    }

    @Test("a check made at a checkpoint is carried with its step: a reuse is told to make it after that step, not at the end")
    func checkpointCheckKeepsItsPlace() async throws {
        let directory = try W.directory()
        let session = P.photoSession(directory)
        var off = P.Finder.window
        off.elements = off.elements.map { $0.label == "Show Preview" ? LearningSession.checkbox("Show Preview", state: .off) : $0 }
        session.script["act|Show Preview"] = LearningSession.Outcome(kind: .actedUnverified, check: TaskResultKindsTests.unknownEffect, next: off)
        let tools = P.tools(session)
        let id = session.id!.uuidString
        _ = try await P.task(tools, #"{"operation":"begin","goal":"Turn off Show Preview in Finder","recall":false}"#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(P.finder)"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Show Preview"}"#)
        _ = try await P.task(tools, #"{"operation":"checkpoint","note":"off","result_check":{"element":"Show Preview","state":"off"}}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Search"}"#)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed","result_check":{"none":"the window shows the switch only"}}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await P.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Turn off a Finder switch","outcome":"completed"},
             "steps":[{"step":1,"label":"Turn off Show Preview"},{"step":2,"label":"Click the search field"}]}
            """#)
        let routeID = try #require(interpreted["version"].string)
        let memory = MemoryService.shared(for: directory)
        let source = try #require(try await memory.perform { try await $0.recall.sources([routeID]) }.first)
        #expect(source.results.map(\.afterStep) == [0] && source.results.map(\.atEnd) == [false], "\(source.results)")
        #expect(source.results.first?.line().hasPrefix("after step 1, at a checkpoint") == true)
        await memory.close()
    }
}
