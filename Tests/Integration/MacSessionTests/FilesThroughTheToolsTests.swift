import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import MacDriver
@testable import MacSession
import Memory
import PerceptionCore
import Router
@testable import SQLiteMemory
import Synchronization
import Testing

/// P12 through the host's tools: the `files` adapter reached by `app_call` with a memory in front, on a temporary
/// root. Each change is read from the disk by the test and compared byte for byte; the memory holds one call per
/// verb, with its dispatch, its task and arguments whose content is the marker; no transcript line, no answer's
/// record and no file of the memory (the database, its WAL) holds a byte of what was written or read; the working
/// directory is the instance's; a refusal changes nothing; without the channel, nothing runs; a start the memory does
/// not confirm acts nothing, an end it cannot save suspends the call and nothing is repeated.
///
/// Offline: `AutomationTools` over the route fake of M05, whose knowledge folder is the memory; no app, Seat, account,
/// personal file or network. The Trash is a folder of the test's.
@MainActor
@Suite("P12: folders, files and text through the tools, on the record", .serialized)
struct FilesThroughTheToolsTests {

    /// Texts no file of the test's machine holds, each a sentence of ordinary words: what the records must not keep.
    static let written  = "braus p12 nonce one: the quick brown fox wrote this line\n"
    static let appended = "braus p12 nonce two: and the lazy dog appended this one\n"
    static let replaced = "braus p12 nonce three: a sleepy cat"
    static let nonces   = ["quick brown fox", "lazy dog", "sleepy cat"]

    /// The transcript the tools hand over, line by line.
    final class Transcript: @unchecked Sendable {
        let lines = Mutex<[String]>([])
        var text: String { lines.withLock { $0.joined(separator: "\n") } }
    }

    /// A root with a Library, a Trash beside it, a knowledge folder, and tools with the memory and the adapter on them.
    @MainActor
    final class Fixture {
        let base      : URL
        let root      : URL
        let trash     : URL
        let knowledge : URL
        let transcript = Transcript()
        let tools     : AutomationTools
        let trace     = "p12-\(UUID().uuidString)"

        /// `base` holds the three folders, unless `root` names another fixture's root to share; `beforeTrash` runs
        /// inside the Trash's move, before it, with the item.
        init(base: URL = Fixture.base(), root shared: URL? = nil, adapters: Bool = true, allowsIrreversible: Bool = true,
             beforeTrash: (@Sendable (URL) throws -> Void)? = nil) throws {
            self.base = base
            root      = shared ?? base.appendingPathComponent("Home")
            trash     = base.appendingPathComponent("Trash")
            knowledge = base.appendingPathComponent("Knowledge")
            for folder in [root.appendingPathComponent("Library"), trash, knowledge] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            tools = AutomationTools(session: CallDispatchRecordTests.RouteFake(.native, memory: knowledge))
            let bin = trash
            tools.adapters = adapters ? AppAdapters([FilesAdapter(root: root, trash: { url in
                try beforeTrash?(url)
                let moved = bin.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: moved)
                return moved
            })], approver: allowsIrreversible ? FileWriteApproval() : nil) : nil
            tools.producer = CallProducer(source: .app, streamID: "p12", traceID: trace)
            let transcript = self.transcript
            tools.record = { line in transcript.lines.withLock { $0.append(line) } }
        }

        static func base() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("braus-p12-\(UUID().uuidString)")
        }

        /// Runs `body` on the fixture and ends it, whether `body` returns or throws.
        static func with(_ fixture: Fixture, _ body: (Fixture) async throws -> Void) async throws {
            do { try await body(fixture) } catch {
                await fixture.end()
                throw error
            }
            await fixture.end()
        }

        /// One `app_call` on `files`, answered as the model reads it: the outcome object, or the error's text.
        func files(_ verb: String, _ arguments: [String: JSONValue] = [:]) async -> (answer: JSONValue, error: String?) {
            do {
                let result = try await tools.call("app_call", .object([
                    "app": .string("files"), "verb": .string(verb), "arguments": .object(arguments),
                ]))
                if result["structuredContent"] != .null { return (result["structuredContent"], nil) }
                let text = result["content"].array?.first?["text"].string ?? ""
                return ((try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null, nil)
            } catch {
                return (.null, String(describing: error))
            }
        }

        func bytes(_ path: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(path)) }

        /// Every file under `folder` with its bytes.
        static func files(under folder: URL) throws -> [String: Data] {
            var found: [String: Data] = [:]
            for case let item as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                found[item.path] = try Data(contentsOf: item)
            }
            return found
        }

        func tree() throws -> [String: Data] { try Self.files(under: root) }

        /// The files of the memory's folder (the database, its WAL and index, whatever else) that hold `text`'s bytes.
        func memoryFiles(holding text: String) throws -> [String] {
            let needle = Data(text.utf8)
            return try Self.files(under: knowledge).filter { $0.value.range(of: needle) != nil }.map { ($0.key as NSString).lastPathComponent }
        }

        func beginTask(_ goal: String) async throws -> String {
            _ = try await tools.call("memory_task", .object(["operation": .string("begin"), "goal": .string(goal),
                                                             "remaining": .string(goal)]))
            return try #require(tools.openTask?.taskID)
        }

        /// The app calls of the trace as the memory holds them, in order.
        func recorded() async throws -> [Recorded] {
            let memory = MemoryService.shared(for: knowledge)
            _ = await memory.flush(within: .seconds(5))
            var found: [Recorded] = []
            for call in try await memory.calls(inTrace: trace) {
                guard case .appCall(let app, let verb, let arguments) = call.request else { continue }
                let id = call.event.eventID
                let dispatch = try await memory.perform { try await $0.facts.adapterDispatch(of: id) }
                let task = try await memory.perform { try await $0.facts.attribution(of: id) }?.taskID
                let redactions = try await memory.perform { try await $0.facts.redactions(of: id) }
                found.append(Recorded(app: app, verb: verb, arguments: arguments, status: call.progress.status,
                                      dispatch: dispatch, task: task, redactions: redactions.count))
            }
            return found
        }

        func end() async {
            await MemoryService.closeAll()
            try? FileManager.default.removeItem(at: base)
        }
    }

    struct Recorded {
        let app       : String
        let verb      : String
        let arguments : String
        let status    : AgentCallStatus?
        let dispatch  : AdapterDispatch?
        let task      : String?
        let redactions: Int
    }

    /// Holds a write lock on the memory's file from another connection, so the memory's next write is refused at once.
    nonisolated final class ArchiveLock: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: SQLiteConnection?

        func hold(_ knowledge: URL) throws {
            let held = try SQLiteConnection(path: knowledge.appendingPathComponent("memory.sqlite").path)
            try held.execute("BEGIN IMMEDIATE")
            lock.withLock { connection = held }
        }

        func release() {
            lock.withLock {
                try? connection?.execute("COMMIT")
                connection?.close()
                connection = nil
            }
        }
    }

    @Test("a tree made, written, read, copied, moved, appended, edited, listed, found and trashed: each change read from the disk by the test; one call per verb on the record with its dispatch and task; content nowhere but on the disk and in the model's answer")
    func treeOnTheRecord() async throws {
        try await Fixture.with(try Fixture()) { fixture in
            let task = try await fixture.beginTask("Keep notes in a folder")

            #expect(await fixture.files("make_folder", ["path": .string("~/P12")]).answer["outcome"] == .string("found_acted"))
            #expect(await fixture.files("cd", ["path": .string("~/P12")]).answer["result"]["path"] == .string("~/P12"))
            #expect(await fixture.files("pwd").answer["result"]["path"] == .string("~/P12"))

            let wrote = await fixture.files("write", ["path": .string("a.txt"), "text": .string(Self.written)])
            #expect(wrote.answer["outcome"] == .string("found_acted")
                    && wrote.answer["result"]["bytes"] == .number(Double(Self.written.utf8.count)), "\(wrote)")
            #expect(fixture.bytes("P12/a.txt") == Data(Self.written.utf8), "relative to the working directory")

            let read = await fixture.files("read", ["path": .string("a.txt")])
            #expect(read.answer["result"]["text"] == .string(Self.written), "the model reads the text: \(read)")

            #expect(await fixture.files("copy", ["from": .string("a.txt"), "to": .string("b.txt")]).answer["outcome"] == .string("found_acted"))
            #expect(fixture.bytes("P12/b.txt") == Data(Self.written.utf8) && fixture.bytes("P12/a.txt") == Data(Self.written.utf8))
            #expect(await fixture.files("move", ["from": .string("b.txt"), "to": .string("c.txt")]).answer["outcome"] == .string("found_acted"))
            #expect(fixture.bytes("P12/b.txt") == nil && fixture.bytes("P12/c.txt") == Data(Self.written.utf8))
            #expect(await fixture.files("append", ["path": .string("c.txt"), "text": .string(Self.appended)]).answer["outcome"] == .string("found_acted"))
            #expect(fixture.bytes("P12/c.txt") == Data((Self.written + Self.appended).utf8))
            let edited = await fixture.files("edit", ["path": .string("c.txt"), "find": .string("the lazy dog"),
                                                      "replace": .string(Self.replaced)])
            #expect(edited.answer["outcome"] == .string("found_acted"), "\(edited)")
            let expected = Self.written + Self.appended.replacingOccurrences(of: "the lazy dog", with: Self.replaced)
            #expect(fixture.bytes("P12/c.txt") == Data(expected.utf8))
            let listed = await fixture.files("list", ["path": .string(".")])
            #expect(listed.answer["result"]["items"].array?.compactMap { $0["name"].string } == ["a.txt", "c.txt"], "\(listed)")
            let found = await fixture.files("find", ["path": .string("~"), "name": .string("*.txt")])
            #expect(found.answer["result"]["matches"].array?.compactMap { $0["path"].string } == ["~/P12/a.txt", "~/P12/c.txt"], "\(found)")
            let trashed = await fixture.files("move_to_trash", ["path": .string("a.txt")])
            #expect(trashed.answer["outcome"] == .string("found_acted"), "\(trashed)")
            #expect(fixture.bytes("P12/a.txt") == nil
                    && FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("a.txt").path))

            // The record: one completed call per verb, dispatched as files.<verb>, under the task; content never kept.
            let calls = try await fixture.recorded()
            let verbs = ["make_folder", "cd", "pwd", "write", "read", "copy", "move", "append", "edit", "list", "find", "move_to_trash"]
            #expect(calls.map(\.verb) == verbs, "\(calls.map(\.verb))")
            #expect(calls.allSatisfy { $0.status == .completed && $0.app == "files" && $0.task == task }, "\(calls)")
            #expect(calls.map(\.dispatch) == verbs.map { AdapterDispatch(adapter: "files", verb: $0) }, "\(calls.map(\.dispatch))")
            for call in calls {
                for nonce in Self.nonces { #expect(!call.arguments.contains(nonce), "\(call.verb): \(call.arguments)") }
            }
            let content = calls.filter { ["write", "append", "edit"].contains($0.verb) }
            #expect(content.allSatisfy { $0.arguments.contains(ValueMinimization.marker) && $0.redactions > 0 }, "\(content)")
            #expect(calls.first { $0.verb == "read" }?.arguments == #"{"path":"a.txt"}"#, "a read's arguments are kept whole")
            #expect(calls.first { $0.verb == "write" }?.arguments.contains(#""path":"a.txt""#) == true, "the path is kept")

            // The transcript: the texts and the file's content nowhere; the read's answer keeps its size.
            let transcript = fixture.transcript.text
            for nonce in Self.nonces { #expect(!transcript.contains(nonce), "the transcript holds \(nonce)") }
            #expect(transcript.contains("← app_call") && transcript.contains("\"bytes\":"), "the read's size is there")
            #expect(transcript.contains("→ app_call") && transcript.contains(ValueMinimization.marker))

            // The memory's files, before and after it is closed (the WAL folded in): none holds a nonce.
            for nonce in Self.nonces { #expect(try fixture.memoryFiles(holding: nonce).isEmpty, "the open memory holds \(nonce)") }
            await MemoryService.closeAll()
            for nonce in Self.nonces { #expect(try fixture.memoryFiles(holding: nonce).isEmpty, "the closed memory holds \(nonce)") }
        }
    }

    @Test("two tools instances on the same root keep their own working directory, each resolving a relative path its own way; the process's never moves")
    func separateWorkingDirectories() async throws {
        try await Fixture.with(try Fixture()) { one in
            let two = try Fixture(root: one.root)
            try FileManager.default.createDirectory(at: one.root.appendingPathComponent("Box"), withIntermediateDirectories: true)
            let before = FileManager.default.currentDirectoryPath
            #expect(await one.files("cd", ["path": .string("~/Box")]).answer["result"]["path"] == .string("~/Box"))
            #expect(await one.files("pwd").answer["result"]["path"] == .string("~/Box"))
            #expect(await two.files("pwd").answer["result"]["path"] == .string("~"))
            #expect(await one.files("write", ["path": .string("here.txt"), "text": .string("one")]).answer["outcome"] == .string("found_acted"))
            #expect(await two.files("write", ["path": .string("here.txt"), "text": .string("two")]).answer["outcome"] == .string("found_acted"))
            #expect(one.bytes("Box/here.txt") == Data("one".utf8) && one.bytes("here.txt") == Data("two".utf8), "the same root, two directories")
            #expect(FileManager.default.currentDirectoryPath == before)
            await two.end()
        }
    }

    @Test("content nested where the schema refuses it is withheld all the same: no nonce in the transcript, the record or the memory's files, no dispatch, nothing on the disk")
    func nestedContentRefused() async throws {
        try await Fixture.with(try Fixture()) { fixture in
            let nonce = "braus p12 nested nonce: hidden in an object"
            let answer = await fixture.files("write", ["path": .string("~/nested.txt"),
                                                       "text": .object(["inner": .array([.string(nonce)])])])
            #expect(answer.error != nil, "the schema refuses a text that is not a string: \(answer)")
            #expect(fixture.bytes("nested.txt") == nil)
            #expect(!fixture.transcript.text.contains("hidden in an object") && fixture.transcript.text.contains(ValueMinimization.marker))
            let calls = try await fixture.recorded()
            #expect(calls.count == 1 && calls.first?.dispatch == nil && calls.first?.status == .failed, "\(calls)")
            #expect(calls.first?.arguments.contains("hidden in an object") == false, "\(calls.first?.arguments ?? "")")
            #expect(try fixture.memoryFiles(holding: "hidden in an object").isEmpty)
            await MemoryService.closeAll()
            #expect(try fixture.memoryFiles(holding: "hidden in an object").isEmpty)
        }
    }

    @Test("refusals change nothing: outside the root, Library, cd outside, write over an existing file, copy and move onto one, an edit that finds two, an append to a missing file, a read of a binary, the Trash with destructive off, an empty find, a text over the bound, an unknown verb or argument; the tree byte-identical; no dispatch for a call refused before the adapter")
    func refusalsChangeNothing() async throws {
        try await Fixture.with(try Fixture(allowsIrreversible: false)) { fixture in
            try Data("kept\n".utf8).write(to: fixture.root.appendingPathComponent("kept.txt"))
            try Data("aa\n".utf8).write(to: fixture.root.appendingPathComponent("twice.txt"))
            try Data([0xFF, 0xFE, 0x41]).write(to: fixture.root.appendingPathComponent("bin.dat"))
            let before = try fixture.tree()
            let nonce = "braus p12 refused nonce: this never lands anywhere\n"

            let refused: [(String, [String: JSONValue])] = [
                ("list", ["path": .string("/etc")]),
                ("list", ["path": .string("~/Library")]),
                ("cd", ["path": .string("/tmp")]),
                ("write", ["path": .string("~/kept.txt"), "text": .string(nonce)]),
                ("copy", ["from": .string("~/twice.txt"), "to": .string("~/kept.txt")]),
                ("move", ["from": .string("~/twice.txt"), "to": .string("~/kept.txt")]),
                ("edit", ["path": .string("~/twice.txt"), "find": .string("a"), "replace": .string(nonce)]),
                ("read", ["path": .string("~/bin.dat")]),
                ("move_to_trash", ["path": .string("~/kept.txt")]),
                ("write", ["path": .string("~/big.txt"), "text": .string(String(repeating: "q", count: 65_537))]),
            ]
            for (verb, arguments) in refused {
                let answer = await fixture.files(verb, arguments).answer
                #expect(answer["outcome"] == .string("refused"), "\(verb): \(answer)")
            }
            #expect(await fixture.files("append", ["path": .string("~/none.txt"), "text": .string(nonce)]).answer["outcome"] == .string("honest_miss"))
            // Refused by the schema, before the adapter: an error, and no dispatch on the record.
            #expect(await fixture.files("find", ["path": .string("~"), "name": .string("")]).error != nil)
            #expect(await fixture.files("explode", ["path": .string("~")]).error != nil)
            #expect(await fixture.files("write", ["path": .string("~/x.txt"), "text": .string(nonce), "mode": .string("x")]).error != nil)
            #expect(try fixture.tree() == before, "nothing on the disk changed")
            #expect(!FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("kept.txt").path))

            let calls = try await fixture.recorded()
            #expect(calls.count == refused.count + 4, "\(calls.map(\.verb))")
            for call in calls.prefix(refused.count + 1) {
                // The policy refuses the Trash before the adapter; every other refusal is the adapter's own.
                #expect(call.status == .completed && (call.dispatch == nil) == (call.verb == "move_to_trash"), "\(call)")
            }
            #expect(calls.suffix(3).allSatisfy { $0.dispatch == nil && $0.status == .failed }, "the schema refused them: \(calls.suffix(3))")
            #expect(calls.allSatisfy { !$0.arguments.contains("never lands") }, "\(calls.map(\.arguments))")
            #expect(!fixture.transcript.text.contains("never lands"))
        }
    }

    @Test("without the adapters app_call is not a tool of the instance: refused before its transcript line, nothing done, no content anywhere")
    func withoutTheChannel() async throws {
        try await Fixture.with(try Fixture(adapters: false)) { fixture in
            let nonce = "braus p12 channel-off nonce: no adapter here\n"
            let answer = await fixture.files("write", ["path": .string("~/off.txt"), "text": .string(nonce)])
            #expect(answer.error == "Invalid tool arguments.", "an unknown tool of this composition: \(answer)")
            #expect(fixture.bytes("off.txt") == nil)
            #expect(!fixture.transcript.text.contains("no adapter here") && !fixture.transcript.text.contains("→ app_call"),
                    "refused before the call's own line: \(fixture.transcript.text)")
            let calls = try await fixture.recorded()
            #expect(calls.count == 1 && calls.first?.dispatch == nil && calls.first?.status == .failed, "\(calls)")
            #expect(calls.first?.arguments.contains("no adapter here") == false)
        }
    }

    @Test("the instructions with the adapters name the files adapter's verbs and no Finder, TextEdit or shell; without them, nothing of it")
    func instructions() {
        let with = AutomationTools.instructions(for: .adapters), without = AutomationTools.instructions(for: [])
        #expect(with.contains("files adapter's verbs") && with.contains("never through Finder, TextEdit or a shell"))
        #expect(with.contains("Never use a shell, AppleScript, computer-use fallback"))
        #expect(!without.contains("files adapter"))
    }

    @Test("a start the memory does not confirm acts nothing; an end it cannot save after the change suspends the call, the answer says so, the change happened once and is not repeated; the next call runs")
    func memoryFailures() async throws {
        let base = Fixture.base()
        let knowledge = base.appendingPathComponent("Knowledge")
        let lock = ArchiveLock(), counted = Mutex(0)
        // The Trash hook takes the lock once the item is going: the call's end cannot be saved then.
        let fixture = try Fixture(base: base, beforeTrash: { _ in
            counted.withLock { $0 += 1 }
            try lock.hold(knowledge)
        })
        // A memory that gives a held lock one short attempt, so a refused write is refused at once.
        MemoryService.install(MemoryService(directory: knowledge, configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(100), retryPause: .milliseconds(5),
                                                   maximumRetryPause: .milliseconds(10)),
            essentialAttempts: 1, essentialCycles: 1)))
        do {
            try await Fixture.with(fixture) { fixture in
                try Data("doomed\n".utf8).write(to: fixture.root.appendingPathComponent("doomed.txt"))
                // One call that runs, so the archive is there to lock.
                #expect(await fixture.files("pwd").answer["outcome"] == .string("found_acted"))

                // The start: refused before the adapter, nothing written.
                try lock.hold(knowledge)
                let refusal = await fixture.files("write", ["path": .string("~/unconfirmed.txt"), "text": .string("never\n")])
                lock.release()
                #expect(refusal.error?.contains("did not confirm") == true, "\(refusal)")
                #expect(fixture.bytes("unconfirmed.txt") == nil)

                // The end: the lock is taken inside the Trash's move, after the change; the end cannot be saved.
                let suspended = await fixture.files("move_to_trash", ["path": .string("~/doomed.txt")])
                #expect(suspended.answer["memory"].string?.contains("could not save its record") == true
                        && suspended.answer["memory"].string?.contains("Do not repeat") == true, "\(suspended)")
                #expect(suspended.answer["outcome"] == .string("found_acted"), "the change itself was read back")
                #expect(counted.withLock { $0 } == 1 && fixture.bytes("doomed.txt") == nil
                        && FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("doomed.txt").path))
                lock.release()

                // With the lock gone, the next call saves what waited and runs; the Trash was asked once in all.
                #expect(await fixture.files("pwd").answer["outcome"] == .string("found_acted"))
                #expect(counted.withLock { $0 } == 1, "nothing repeated")
                let calls = try await fixture.recorded()
                #expect(calls.map(\.verb) == ["pwd", "move_to_trash", "pwd"], "\(calls.map(\.verb))")
                #expect(calls.allSatisfy { $0.status == .completed }, "\(calls)")
            }
        } catch {
            lock.release()
            throw error
        }
    }
}

/// A per-call grant for synthetic file writes in the fixture only.
private struct FileWriteApproval: AdapterApproving {
    func approve(_ consent: AdapterConsent) async -> Bool { true }
}
