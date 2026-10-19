@testable import AppAdapters
import Darwin
import EngineCore
import Foundation
import LocalMCP
import Testing

/// The Files adapter on a temporary root, with a Trash of its own: paths kept inside the root and out
/// of Library, moves that never replace, each change read back from the disk. P12 adds a working directory of the
/// instance, finding, reading, copying, writing, appending and editing, each bounded, each refusal with nothing done,
/// each change compared exactly with the bytes on disk; confinement by descriptors, with no link followed and
/// Library refused under any spelling; a spent budget stopping a read and refusing a change before it.
@Suite("Files adapter")
struct FilesAdapterTests {

    let root: URL
    let trash: URL
    let adapter: FilesAdapter
    /// The adapter behind the schema check and the policies, as the tools reach it; the person allows every irreversible call here.
    let guarded: AppAdapters

    init() throws {
        root  = FileManager.default.temporaryDirectory.appendingPathComponent("braus-files-\(UUID().uuidString)")
        trash = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-trash")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        adapter = FilesAdapter(root: root, trash: Self.trashing(into: trash))
        guarded = AppAdapters([adapter], approver: FakeApprover(.allow))
    }

    static func trashing(into bin: URL) -> @Sendable (URL) throws -> URL? {
        { url in
            let moved = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
    }

    /// A call whose arguments are all texts.
    private func call(_ verb: String, _ arguments: [String: String]) async throws -> AdapterOutcome {
        try await adapter.call(verb, .object(arguments.mapValues { .string($0) }))
    }

    /// A call with arguments of their own JSON types: a number is a number, a flag a bool, as the schema admits them.
    private func json(_ verb: String, _ arguments: [String: JSONValue]) async throws -> AdapterOutcome {
        try await adapter.call(verb, .object(arguments))
    }

    /// A call through `AppAdapters`, so the schema (empty strings, ranges, unknown arguments) is checked first; what
    /// the schema refuses, thrown there, is answered as refused here.
    private func checked(_ verb: String, _ arguments: [String: JSONValue]) async throws -> AdapterOutcome {
        do { return try await guarded.call(app: "files", verb: verb, arguments: .object(arguments)) }
        catch let failure as AdapterFailure { return .refused(failure.description) }
    }

    private func touch(_ path: String, _ text: String = "Braus test") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func bytes(_ path: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(path)) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    /// Every file under the root with its bytes, so a refusal can be shown to have changed nothing.
    private func tree() throws -> [String: Data] {
        var found: [String: Data] = [:]
        let files = FileManager.default
        for case let item as URL in files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found[item.path] = try Data(contentsOf: item)
        }
        return found
    }

    @Test("Paths outside the root or inside Library are refused", arguments: ["/etc", "~/../x", "~/Library/Mail", "Library"])
    func outside(path: String) async throws {
        #expect(try await call("list", ["path": path]).kind == .refused)
        #expect(try await call("make_folder", ["path": path + "/new"]).kind == .refused)
    }

    @Test("make_folder makes parents, then is a no-op; a file in the way is refused")
    func makeFolder() async throws {
        #expect(try await call("make_folder", ["path": "~/A/B"]).kind == .foundActed)
        #expect(try await call("make_folder", ["path": "~/A/B"]).kind == .actedNoop)
        try touch("file.txt")
        #expect(try await call("make_folder", ["path": "~/file.txt"]).kind == .refused)
    }

    @Test("list answers items sorted, folders marked, hidden ones only when asked")
    func list() async throws {
        try touch("b.txt")
        try touch(".hidden")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        let listed = try await call("list", ["path": "~"])
        let names = listed.result["items"].array?.compactMap { $0["name"].string }
        #expect(names == ["a", "b.txt", "Library"])
        #expect(listed.result["items"].array?.first?["kind"] == .string("folder"))
        #expect(try await call("list", ["path": "~/b.txt"]).kind == .refused)
        #expect(try await call("list", ["path": "~/none"]).kind == .honestMiss)
        let hidden = try await json("list", ["path": .string("~"), "hidden": .bool(true)])
        #expect(hidden.result["items"].array?.compactMap { $0["name"].string } == [".hidden", "a", "b.txt", "Library"])
    }

    @Test("move renames, moves into a folder, and never replaces or nests a folder in itself")
    func move() async throws {
        try touch("one.txt")
        try touch("two.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box"), withIntermediateDirectories: true)
        #expect(try await call("move", ["from": "~/one.txt", "to": "~/two.txt"]).kind == .refused)
        let into = try await call("move", ["from": "~/one.txt", "to": "~/Box"])
        #expect(into.kind == .foundActed)
        #expect(into.result["to"] == .string("~/Box/one.txt"))
        #expect(try await call("move", ["from": "~/Box", "to": "~/Box/Inner"]).kind == .refused)
        #expect(try await call("move", ["from": "~/two.txt", "to": "~/Missing/two.txt"]).kind == .honestMiss)
        #expect(try await call("move", ["from": "~/two.txt", "to": "~/three.txt"]).kind == .foundActed)
    }

    @Test("move_to_trash moves the item away and reads it back in the Trash")
    func moveToTrash() async throws {
        try touch("old.txt")
        #expect(try await call("move_to_trash", ["path": "~/old.txt"]).kind == .foundActed)
        #expect(!exists("old.txt"))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("old.txt").path))
        #expect(try await call("move_to_trash", ["path": "~"]).kind == .refused)
    }

    // MARK: P12

    @Test("pwd starts at the root; cd changes where a relative path resolves, only to a folder inside the root; two instances on one root keep their own")
    func workingDirectory() async throws {
        try touch("Box/note.txt", "in the box")
        try touch("note.txt", "at the root")
        #expect(try await call("pwd", [:]).result["path"] == .string("~"))
        #expect(try await call("read", ["path": "note.txt"]).result["text"] == .string("at the root"))
        #expect(try await call("cd", ["path": "~/Box"]).result["path"] == .string("~/Box"))
        #expect(try await call("pwd", [:]).result["path"] == .string("~/Box"))
        #expect(try await call("read", ["path": "note.txt"]).result["text"] == .string("in the box"))
        #expect(try await call("read", ["path": "~/note.txt"]).result["text"] == .string("at the root"), "~ still the root")
        #expect(try await call("cd", ["path": "note.txt"]).kind == .refused)
        #expect(try await call("cd", ["path": "~/Missing"]).kind == .honestMiss)
        #expect(try await call("cd", ["path": "~/Library"]).kind == .refused)
        #expect(try await call("cd", ["path": "/tmp"]).kind == .refused)
        #expect(try await call("pwd", [:]).result["path"] == .string("~/Box"), "a refused cd changes nothing")
        let other = FilesAdapter(root: root, trash: Self.trashing(into: trash))
        #expect(try await other.call("pwd", .object([:])).result["path"] == .string("~"), "another instance's own")
        #expect(FileManager.default.currentDirectoryPath != root.appendingPathComponent("Box").path, "the process never moved")
    }

    @Test("find matches a part of the name or a pattern, case-insensitively, breadth first, within depth; answers the limit and says it stopped; visits a bounded number of entries")
    func find() async throws {
        try touch("Reports/2026/march.txt")
        try touch("Reports/2026/deep/deeper/april.txt")
        try touch("Reports/summary.TXT")
        try touch("notes.md")
        let all = try await json("find", ["path": .string("~"), "name": .string("*.txt"), "depth": .number(4)])
        #expect(all.result["matches"].array?.compactMap { $0["path"].string }
                == ["~/Reports/summary.TXT", "~/Reports/2026/march.txt", "~/Reports/2026/deep/deeper/april.txt"], "\(all.result)")
        #expect(all.result["stopped"] == .null)
        let byDefault = try await call("find", ["path": "~", "name": "*.txt"])
        #expect(byDefault.result["matches"].array?.count == 2, "two levels by default: \(byDefault.result)")
        let shallow = try await json("find", ["path": .string("~/Reports"), "name": .string("txt"), "depth": .number(0)])
        #expect(shallow.result["matches"].array?.count == 1, "\(shallow.result)")
        let limited = try await json("find", ["path": .string("~"), "name": .string("txt"), "limit": .number(1)])
        #expect(limited.result["matches"].array?.count == 1 && limited.result["stopped"].string == "answered 1 matches", "\(limited.result)")
        #expect(try await call("find", ["path": "~/notes.md", "name": "x"]).kind == .refused)
        #expect(try await call("find", ["path": "/etc", "name": "hosts"]).kind == .refused)
        #expect(try await checked("find", ["path": .string("~"), "name": .string("")]).kind == .refused, "an empty name")
        #expect(try await checked("find", ["path": .string("~"), "name": .string("x"), "depth": .number(9)]).kind == .refused)
        for index in 0..<(2000 + 5) { try touch("Many/f\(index).log", "") }
        let capped = try await call("find", ["path": "~/Many", "name": "nothing-is-named-so"])
        #expect(capped.result["visited"] == .number(2000) && capped.result["stopped"].string == "visited 2000 entries", "\(capped.result["stopped"])")
        #expect(capped.result["matches"].array?.count == 0)
        let answered = try await call("find", ["path": "~/Many", "name": "*.log"])
        #expect(answered.result["matches"].array?.count == 200 && answered.result["stopped"].string == "answered 200 matches", "the answer bound comes first")
    }

    @Test("read gives UTF-8 text up to max_bytes, says the size and the cut, never cuts a character in two, and refuses what is not text or not a file")
    func read() async throws {
        try touch("long.txt", String(repeating: "x", count: 100))
        let cut = try await json("read", ["path": .string("~/long.txt"), "max_bytes": .number(10)])
        #expect(cut.result["text"] == .string(String(repeating: "x", count: 10)))
        #expect(cut.result["bytes"] == .number(10) && cut.result["size"] == .number(100) && cut.result["truncated"] == .bool(true))
        let whole = try await call("read", ["path": "~/long.txt"])
        #expect(whole.result["bytes"] == .number(100) && whole.result["truncated"] == .bool(false))
        // "caffè" is 6 bytes; a cut at 5 would split the è: the text ends at "caff", 4 bytes.
        try touch("accent.txt", "caffè latte")
        let split = try await json("read", ["path": .string("~/accent.txt"), "max_bytes": .number(5)])
        #expect(split.result["text"] == .string("caff") && split.result["bytes"] == .number(4) && split.result["truncated"] == .bool(true), "\(split.result)")
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: root.appendingPathComponent("binary.bin"))
        #expect(try await call("read", ["path": "~/binary.bin"]).kind == .refused)
        try Data([0x41, 0xFF]).write(to: root.appendingPathComponent("broken.txt"))
        #expect(try await call("read", ["path": "~/broken.txt"]).kind == .refused, "an incomplete sequence at the real end is not a cut")
        #expect(try await call("read", ["path": "~"]).kind == .refused)
        #expect(try await call("read", ["path": "~/none.txt"]).kind == .honestMiss)
        #expect(try await checked("read", ["path": .string("~/long.txt"), "max_bytes": .number(70_000)]).kind == .refused, "over the bound")
    }

    @Test("write makes a file whose bytes equal the text, refuses an existing one unless overwrite, accepts an empty text, refuses a text over the bound and a link, with nothing done")
    func write() async throws {
        let text = "first line\nsecond \"quoted\" line\n"
        let made = try await call("write", ["path": "~/new.txt", "text": text])
        #expect(made.kind == .foundActed && made.confirmedByReadBack && bytes("new.txt") == Data(text.utf8))
        #expect(try await call("write", ["path": "~/new.txt", "text": "other"]).kind == .refused)
        #expect(bytes("new.txt") == Data(text.utf8), "the refusal changed nothing")
        let replaced = try await json("write", ["path": .string("~/new.txt"), "text": .string("other"), "overwrite": .bool(true)])
        #expect(replaced.kind == .foundActed && bytes("new.txt") == Data("other".utf8))
        let emptied = try await checked("write", ["path": .string("~/empty.txt"), "text": .string("")])
        #expect(emptied.kind == .foundActed && bytes("empty.txt") == Data(), "an empty text is a value")
        #expect(try await call("write", ["path": "~/Missing/x.txt", "text": "x"]).kind == .honestMiss)
        #expect(try await call("write", ["path": "~", "text": "x"]).kind == .refused)
        let big = String(repeating: "y", count: 65_537)
        #expect(try await call("write", ["path": "~/big.txt", "text": big]).kind == .refused)
        #expect(bytes("big.txt") == nil)
        // A link inside the root to a folder outside it: refused by the walk, nothing written anywhere.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("braus-files-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(try await call("write", ["path": "~/link/leak.txt", "text": "x"]).kind == .refused)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("leak.txt").path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("lib"),
                                                   withDestinationURL: root.appendingPathComponent("Library"))
        #expect(try await call("write", ["path": "~/lib/leak.txt", "text": "x"]).kind == .refused)
        #expect(!exists("Library/leak.txt"))
    }

    @Test("append reads back exactly what was there plus the text; a missing file, a folder or one over the bound is refused with nothing done")
    func append() async throws {
        try touch("log.txt", "one\n")
        let added = try await call("append", ["path": "~/log.txt", "text": "two\n"])
        #expect(added.kind == .foundActed && added.confirmedByReadBack && bytes("log.txt") == Data("one\ntwo\n".utf8))
        #expect(try await call("append", ["path": "~/none.txt", "text": "x"]).kind == .honestMiss)
        #expect(try await call("append", ["path": "~", "text": "x"]).kind == .refused)
        try Data(count: 1_048_577).write(to: root.appendingPathComponent("huge.bin"))
        let before = try tree()
        #expect(try await call("append", ["path": "~/huge.bin", "text": "x"]).kind == .refused)
        #expect(try await call("append", ["path": "~/log.txt", "text": String(repeating: "z", count: 65_537)]).kind == .refused)
        #expect(try tree() == before)
    }

    @Test("edit replaces the one occurrence exactly, an empty replacement removes it, and zero or several occurrences refuse with the count and nothing changed")
    func edit() async throws {
        try touch("doc.txt", "alpha beta gamma\n")
        let once = try await call("edit", ["path": "~/doc.txt", "find": "beta", "replace": "delta"])
        #expect(once.kind == .foundActed && once.confirmedByReadBack && bytes("doc.txt") == Data("alpha delta gamma\n".utf8))
        let removed = try await checked("edit", ["path": .string("~/doc.txt"), "find": .string(" delta"), "replace": .string("")])
        #expect(removed.kind == .foundActed && bytes("doc.txt") == Data("alpha gamma\n".utf8))
        let none = try await call("edit", ["path": "~/doc.txt", "find": "beta", "replace": "x"])
        #expect(none.kind == .refused && none.message.contains("0 times"), "\(none.message)")
        let several = try await call("edit", ["path": "~/doc.txt", "find": "a", "replace": "x"])
        #expect(several.kind == .refused && several.message.contains("4 times"), "\(several.message)")
        #expect(bytes("doc.txt") == Data("alpha gamma\n".utf8), "the refusals changed nothing")
        #expect(try await checked("edit", ["path": .string("~/doc.txt"), "find": .string(""), "replace": .string("x")]).kind == .refused)
        try Data([0xFF, 0x41]).write(to: root.appendingPathComponent("bin.dat"))
        #expect(try await call("edit", ["path": "~/bin.dat", "find": "A", "replace": "B"]).kind == .refused)
        #expect(bytes("bin.dat") == Data([0xFF, 0x41]))
        #expect(try await call("edit", ["path": "~/none.txt", "find": "a", "replace": "b"]).kind == .honestMiss)
    }

    @Test("copy reads back the copy's bytes equal to the source's and the source unchanged, into a folder by name, and refuses an existing target, a folder or a file over the bound")
    func copy() async throws {
        let text = "copy me\n"
        try touch("src.txt", text)
        try touch("taken.txt", "taken")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box"), withIntermediateDirectories: true)
        let copied = try await call("copy", ["from": "~/src.txt", "to": "~/dst.txt"])
        #expect(copied.kind == .foundActed && copied.confirmedByReadBack)
        #expect(bytes("dst.txt") == Data(text.utf8) && bytes("src.txt") == Data(text.utf8))
        let into = try await call("copy", ["from": "~/src.txt", "to": "~/Box"])
        #expect(into.result["to"] == .string("~/Box/src.txt") && bytes("Box/src.txt") == Data(text.utf8))
        let before = try tree()
        #expect(try await call("copy", ["from": "~/src.txt", "to": "~/taken.txt"]).kind == .refused)
        #expect(try await call("copy", ["from": "~/src.txt", "to": "~/src.txt"]).kind == .refused)
        #expect(try await call("copy", ["from": "~/Box", "to": "~/Box2"]).kind == .refused)
        #expect(try await call("copy", ["from": "~/none.txt", "to": "~/x.txt"]).kind == .honestMiss)
        #expect(try await call("copy", ["from": "~/src.txt", "to": "~/Missing/x.txt"]).kind == .honestMiss)
        try Data(count: 1_048_577).write(to: root.appendingPathComponent("huge.bin"))
        let bigger = try tree()
        #expect(try await call("copy", ["from": "~/huge.bin", "to": "~/huge2.bin"]).kind == .refused)
        #expect(try tree() == bigger && before.count + 1 == bigger.count)
    }

    @Test("confinement: find never enters Library nor follows a link, and names a folder it cannot read; a link is read, listed or written through nowhere, in or out of the root")
    func confinement() async throws {
        try touch("Library/secret-match.txt", "in Library")
        try touch("Docs/plain-match.txt", "plain")
        try touch("Docs/target.txt", "target")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("braus-files-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside-match.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("away"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("Docs"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut.txt"),
                                                   withDestinationURL: root.appendingPathComponent("Docs/target.txt"))
        let found = try await json("find", ["path": .string("~"), "name": .string("match"), "depth": .number(4)])
        #expect(found.result["matches"].array?.compactMap { $0["path"].string } == ["~/Docs/plain-match.txt"], "\(found.result)")
        #expect(found.result["links_skipped"] == .number(3), "away, alias and shortcut.txt, none followed: \(found.result)")
        #expect(found.result["unreadable"] == .null)
        // The links themselves: never read, listed or written through, whether they point out of the root or into it.
        #expect(try await call("read", ["path": "~/shortcut.txt"]).kind == .refused)
        #expect(try await call("read", ["path": "~/alias/target.txt"]).kind == .refused)
        #expect(try await call("list", ["path": "~/away"]).kind == .refused)
        #expect(try await call("list", ["path": "~/alias"]).kind == .refused)
        #expect(try await call("find", ["path": "~/away", "name": "x"]).kind == .refused)
        #expect(try await call("write", ["path": "~/alias/new.txt", "text": "x"]).kind == .refused)
        #expect(try await call("write", ["path": "~/away/new.txt", "text": "x"]).kind == .refused)
        #expect(try await json("write", ["path": .string("~/shortcut.txt"), "text": .string("x"), "overwrite": .bool(true)]).kind == .refused)
        #expect(try await call("copy", ["from": "~/Docs/target.txt", "to": "~/alias/copy.txt"]).kind == .refused)
        #expect(try await call("move", ["from": "~/Docs/target.txt", "to": "~/away/moved.txt"]).kind == .refused)
        #expect(bytes("Docs/new.txt") == nil && bytes("Docs/copy.txt") == nil && bytes("Docs/target.txt") == Data("target".utf8))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path)
                && !FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved.txt").path))
        let listed = try await call("list", ["path": "~"])
        let links = listed.result["items"].array?.filter { $0["kind"] == .string("link") }.compactMap { $0["name"].string }
        #expect(links == ["alias", "away", "shortcut.txt"], "a link is listed by name alone: \(listed.result)")
        #expect(listed.result["items"].array?.first { $0["name"] == .string("away") }?["modified"] == .null)
        // A folder the search cannot read is named, not passed over as empty.
        try touch("Closed/inner-match.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("Closed").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Closed").path) }
        let partial = try await json("find", ["path": .string("~"), "name": .string("match"), "depth": .number(4)])
        #expect(partial.result["unreadable"].array == [.string("~/Closed")] && partial.message.contains("1 folders could not be read"), "\(partial.result)")
        #expect(try await call("list", ["path": "~/Closed"]).kind == .refused)
    }

    @Test("Library under another case, by identity on a volume that ignores case, or hidden behind a NUL, is refused with nothing done; find never enters it")
    func libraryUnderAnySpelling() async throws {
        try touch("Library/secret-match.txt", "secret")
        try touch("Docs/t.txt", "t")
        let before = try tree()
        for path in ["~/library/leak.txt", "~/LIBRARY/leak.txt", "~/Library\u{0}x/leak.txt", "~/lib\u{0}rary/leak.txt", "library/leak.txt"] {
            #expect(try await call("write", ["path": path, "text": "x"]).kind == .refused, "\(path)")
            #expect(try await call("make_folder", ["path": path]).kind == .refused, "\(path)")
        }
        #expect(try await call("list", ["path": "~/library"]).kind == .refused)
        #expect(try await call("list", ["path": "~/LIBRARY"]).kind == .refused)
        #expect(try await call("read", ["path": "~/library/secret-match.txt"]).kind == .refused)
        #expect(try await call("read", ["path": "~/Library\u{0}/secret-match.txt"]).kind == .refused)
        #expect(try await call("cd", ["path": "~/library"]).kind == .refused)
        #expect(try await call("find", ["path": "~/library", "name": "secret"]).kind == .refused)
        #expect(try await call("move", ["from": "~/Docs/t.txt", "to": "~/library/moved.txt"]).kind == .refused)
        #expect(try await call("move", ["from": "~/Docs/t.txt", "to": "~/library"]).kind == .refused)
        #expect(try await call("copy", ["from": "~/Docs/t.txt", "to": "~/LIBRARY"]).kind == .refused)
        #expect(try await call("move_to_trash", ["path": "~/library"]).kind == .refused)
        #expect(try await call("move_to_trash", ["path": "~/library/secret-match.txt"]).kind == .refused)
        let found = try await json("find", ["path": .string("~"), "name": .string("secret"), "depth": .number(4)])
        #expect(found.result["matches"].array?.isEmpty == true, "\(found.result)")
        #expect(try tree() == before && !exists("Library/leak.txt") && !exists("Library/moved.txt") && !exists("Library/t.txt"))
    }

    @Test("a pipe with no reader is refused at once by every verb that opens a file, nothing blocking and nothing changed")
    func pipeIsRefused() async throws {
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o644) == 0)
        try touch("src.txt", "src")
        let started = ContinuousClock.now
        #expect(try await call("read", ["path": "~/pipe"]).kind == .refused)
        #expect(try await call("append", ["path": "~/pipe", "text": "x"]).kind == .refused)
        #expect(try await call("edit", ["path": "~/pipe", "find": "a", "replace": "b"]).kind == .refused)
        #expect(try await call("copy", ["from": "~/pipe", "to": "~/copy.txt"]).kind == .refused)
        #expect(try await call("write", ["path": "~/pipe", "text": "x"]).kind == .refused)
        #expect(try await json("write", ["path": .string("~/pipe"), "text": .string("x"), "overwrite": .bool(true)]).kind == .refused)
        #expect(ContinuousClock.now - started < .seconds(2), "nothing blocked")
        #expect(bytes("copy.txt") == nil)
        let listed = try await call("list", ["path": "~"])
        #expect(listed.result["items"].array?.first { $0["name"] == .string("pipe") }?["kind"] == .string("other"))
    }

    @Test("a spent budget: a search and a listing stop and say so, every change is refused before it with nothing done, a read refuses")
    func spentBudget() async throws {
        try touch("Docs/a.txt", "a")
        try touch("Docs/b.txt", "b")
        let before = try tree()
        let spent = FilesAdapter(root: root, trash: Self.trashing(into: trash), time: .seconds(-1))
        func run(_ verb: String, _ arguments: [String: JSONValue]) async throws -> AdapterOutcome {
            try await spent.call(verb, .object(arguments))
        }
        let found = try await run("find", ["path": .string("~"), "name": .string("txt")])
        #expect(found.kind == .foundActed && found.result["stopped"].string == "ran out of time" && found.result["visited"] == .number(0), "\(found.result)")
        let listed = try await run("list", ["path": .string("~/Docs")])
        #expect(listed.result["stopped"].string?.hasPrefix("ran out of time") == true && listed.result["items"].array?.isEmpty == true, "\(listed.result)")
        let changes: [(String, [String: JSONValue])] = [
            ("write", ["path": .string("~/new.txt"), "text": .string("x")]),
            ("append", ["path": .string("~/Docs/a.txt"), "text": .string("x")]),
            ("edit", ["path": .string("~/Docs/a.txt"), "find": .string("a"), "replace": .string("b")]),
            ("copy", ["from": .string("~/Docs/a.txt"), "to": .string("~/Docs/c.txt")]),
            ("move", ["from": .string("~/Docs/a.txt"), "to": .string("~/Docs/d.txt")]),
            ("make_folder", ["path": .string("~/New/Deep")]),
            ("move_to_trash", ["path": .string("~/Docs/b.txt")]),
            ("read", ["path": .string("~/Docs/a.txt")]),
        ]
        for (verb, arguments) in changes {
            let answer = try await run(verb, arguments)
            #expect(answer.kind == .refused && answer.message.contains("ran out of"), "\(verb): \(answer.message)")
        }
        #expect(try tree() == before && !exists("New"))
        #expect(try await run("pwd", [:]).kind == .foundActed, "what changes nothing still answers")
    }

    @Test("a working directory that is gone refuses pwd and every relative path, with no fall back to the root; an explicit path still works")
    func goneWorkingDirectory() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box"), withIntermediateDirectories: true)
        #expect(try await call("cd", ["path": "~/Box"]).kind == .foundActed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Box"))
        let gone = try await call("pwd", [:])
        #expect(gone.kind == .refused && gone.message.contains("~/Box"), "\(gone.message)")
        #expect(try await call("write", ["path": "x.txt", "text": "x"]).kind == .refused)
        #expect(try await call("list", ["path": "."]).kind == .refused)
        #expect(bytes("x.txt") == nil && bytes("Box/x.txt") == nil)
        #expect(try await call("write", ["path": "~/y.txt", "text": "y"]).kind == .foundActed)
        #expect(try await call("cd", ["path": "~"]).kind == .foundActed)
        #expect(try await call("pwd", [:]).result["path"] == .string("~"))
    }

    @Test("list reads 2000 entries at most and answers 200, saying it stopped; a replacement leaves no temporary file beside the file")
    func boundedListAndCleanReplace() async throws {
        for index in 0..<(2000 + 5) { try touch("Many/f\(index).txt", "") }
        let listed = try await call("list", ["path": "~/Many"])
        #expect(listed.result["items"].array?.count == 200 && listed.result["more"] == .number(1800)
                && listed.result["stopped"].string == "read 2000 entries", "\(listed.message)")
        #expect(listed.message.hasPrefix("at least 2000 items"))
        try touch("doc.txt", "old text")
        _ = try await json("write", ["path": .string("~/doc.txt"), "text": .string("new text"), "overwrite": .bool(true)])
        _ = try await call("edit", ["path": "~/doc.txt", "find": "new", "replace": "newer"])
        #expect(bytes("doc.txt") == Data("newer text".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".braus-") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test("a replacement keeps the file's permission bits (a private file stays 0600, a script stays 0700), and a new file is the owner's alone")
    func permissionsKept() async throws {
        func mode(_ path: String) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.posixPermissions] as? Int)
        }
        try touch("private.txt", "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("private.txt").path)
        try touch("script.sh", "#!/bin/sh\necho old\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("script.sh").path)
        let replaced = try await json("write", ["path": .string("~/private.txt"), "text": .string("new"), "overwrite": .bool(true)])
        #expect(replaced.kind == .foundActed && bytes("private.txt") == Data("new".utf8))
        #expect(try mode("private.txt") == 0o600)
        let edited = try await call("edit", ["path": "~/script.sh", "find": "old", "replace": "new"])
        #expect(edited.kind == .foundActed && bytes("script.sh") == Data("#!/bin/sh\necho new\n".utf8))
        #expect(try mode("script.sh") == 0o700)
        #expect(try await call("write", ["path": "~/fresh.txt", "text": "fresh"]).kind == .foundActed)
        #expect(try mode("fresh.txt") == 0o600)
        #expect(try await call("copy", ["from": "~/script.sh", "to": "~/copy.sh"]).kind == .foundActed)
        #expect(try mode("copy.sh") == 0o600, "a copy is a new file, the owner's alone")
        // overwrite true on a file that is not there makes it, exclusively, the owner's alone.
        let made = try await json("write", ["path": .string("~/absent.txt"), "text": .string("made"), "overwrite": .bool(true)])
        #expect(made.kind == .foundActed && bytes("absent.txt") == Data("made".utf8), "\(made.message)")
        #expect(try mode("absent.txt") == 0o600)
    }

    @Test("a call cancelled before it runs throws and writes nothing")
    func cancelled() async throws {
        let adapter = self.adapter
        let task = Task { try await adapter.call("write", .object(["path": .string("~/never.txt"), "text": .string("x")])) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bytes("never.txt") == nil)
    }

    @Test("the verbs' schema: content parameters marked, empty allowed only for text and replace, read's text a content result")
    func schema() {
        let verbs = Dictionary(uniqueKeysWithValues: adapter.verbs.map { ($0.name, $0) })
        func parameter(_ verb: String, _ name: String) -> AdapterParameter? { verbs[verb]?.parameters.first { $0.name == name } }
        #expect(parameter("write", "text")?.isContent == true && parameter("write", "text")?.allowsEmpty == true)
        #expect(parameter("append", "text")?.isContent == true)
        #expect(parameter("edit", "find")?.isContent == true && parameter("edit", "find")?.allowsEmpty == false)
        #expect(parameter("edit", "replace")?.isContent == true && parameter("edit", "replace")?.allowsEmpty == true)
        #expect(parameter("write", "path")?.isContent == false && parameter("find", "name")?.allowsEmpty == false)
        #expect(verbs["read"]?.contentResults == ["text"] && verbs["list"]?.contentResults == [])
        #expect(verbs["move_to_trash"]?.safety == .irreversible && verbs["write"]?.safety == .write && verbs["cd"]?.safety == .read)
    }
}
