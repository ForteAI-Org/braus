import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// FakeNotesTransport is Notes in memory, turning the adapter's HTML back into plain text as Notes
/// does. `dropsWrites` plays a Notes that takes a change and does not keep it; `misfile(into:)` one that
/// files a new note in another folder than asked, and `hideFolder` one whose read-back lacks the folder.
actor FakeNotesTransport: NotesTransporting {
    var folders: [NotesFolder] = [
        NotesFolder(id: "f-notes", name: "Notes", account: "iCloud", count: 1),
        NotesFolder(id: "f-work", name: "Work", account: "iCloud", count: 0),
        NotesFolder(id: "f-work-2", name: "Work", account: "On My Mac", count: 0),
    ]
    var notes: [StoreNote] = [
        StoreNote(id: "n-1", title: "Shopping", folder: "Notes", modified: Date(timeIntervalSince1970: 1_000),
                  text: "Shopping\nMilk"),
    ]
    var dropsWrites = false
    private(set) var html: [String: String] = [:]
    private(set) var writes = 0
    private var readFailure: (any Error & Sendable)?
    private var writeFailure: (any Error & Sendable)?
    private var refusesBeforeWrite = false
    private var misfiled: String?
    private var hidesFolder = false

    /// New notes go into the folder `id`, whatever the call asked.
    func misfile(into id: String) { misfiled = id }

    /// A note read back says nothing of its folder's id or account.
    func hideFolder() { hidesFolder = true }

    /// A write fails once it went out: a permission refused while the script ran, a failure midway.
    func failWrites(with error: any Error & Sendable) { writeFailure = error }

    /// The check before any script refuses: no write goes out.
    func refuseBeforeWrite() { refusesBeforeWrite = true }

    func dropWrites() { dropsWrites = true }

    /// Notes reads fail once a note was created or added to.
    func failReads(afterWrite error: any Error & Sendable) { readFailure = error }

    func availability() async -> AdapterAvailability { .ready }

    func folders() async throws -> [NotesFolder] { folders }

    func notes(matching query: String?, folderID: String?, limit: Int) async throws -> [StoreNote] {
        let folder = folderID.flatMap { id in folders.first { $0.id == id }?.name }
        return notes.filter { note in
            (folder.map { note.folder == $0 } ?? true)
                && (query.map { (note.title + (note.text ?? "")).contains($0) } ?? true)
        }.map { StoreNote(id: $0.id, title: $0.title, folder: $0.folder, modified: $0.modified) }
    }

    func note(id: String) async throws -> StoreNote? {
        if writes > 0, let readFailure { throw readFailure }
        guard let note = notes.first(where: { $0.id == id }) else { return nil }
        guard hidesFolder else { return note }
        return StoreNote(id: note.id, title: note.title, folder: note.folder, modified: note.modified, text: note.text)
    }

    func create(html: String, folderID: String?) async throws -> String {
        if refusesBeforeWrite { throw AutomationPermissionNeeded("Allow Notes in Automation.", beforeAnyEvent: true) }
        writes += 1
        if let writeFailure { throw writeFailure }
        let id = "n-\(notes.count + 1)"
        guard !dropsWrites else { return id }
        let text   = Self.plain(html)
        let folder = folders.first { $0.id == (misfiled ?? folderID ?? "f-notes") } ?? folders[0]
        notes.append(StoreNote(id: id, title: text.components(separatedBy: "\n")[0], folder: folder.name,
                               modified: Date(), text: text, folderID: folder.id, account: folder.account))
        self.html[id] = html
        return id
    }

    func append(html: String, to id: String) async throws {
        if refusesBeforeWrite { throw AutomationPermissionNeeded("Allow Notes in Automation.", beforeAnyEvent: true) }
        writes += 1
        if let writeFailure { throw writeFailure }
        guard !dropsWrites, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[index]
        notes[index] = StoreNote(id: id, title: note.title, folder: note.folder, modified: Date(),
                                 text: (note.text ?? "") + "\n" + Self.plain(html))
    }

    /// Notes' plain text: each div a line, the entities read back.
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .newlines)
    }
}

/// The Notes adapter on a fake Notes: notes created and added to and read back by id, folders picked
/// by name or id, the agent's text escaped so it never becomes markup.
@Suite("Notes adapter")
struct NotesAdapterTests {

    @Test("A02/A08: the note's read-back failing after it was created, or added to: unverified, it may have happened, written once",
          arguments: ["create_note", "append_to_note"])
    func readBackFailsAfterWrite(verb: String) async throws {
        let transport = FakeNotesTransport()
        let arguments: JSONValue = verb == "create_note"
            ? .object(["title": .string("Braus test"), "text": .string("one")])
            : .object(["id": .string("n-1"), "text": .string("Eggs")])
        await transport.failReads(afterWrite: AutomationPermissionNeeded("Allow Notes in Automation."))
        let outcome = try await NotesAdapter(transport: transport).call(verb, arguments)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await transport.writes == 1)
    }

    @Test("A02: the permission refused while the script ran, after the note was written: unverified, it may have happened, never refused",
          arguments: ["create_note", "append_to_note"])
    func permissionWhileWriting(verb: String) async throws {
        let transport = FakeNotesTransport()
        await transport.failWrites(with: AutomationPermissionNeeded("Allow Notes in Automation."))
        let outcome = try await NotesAdapter(transport: transport).call(verb, Self.arguments(verb))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await transport.writes == 1)
    }

    @Test("A02: a Notes the check before any script refuses: the note is refused, and nothing was written",
          arguments: ["create_note", "append_to_note"])
    func refusedBeforeWrite(verb: String) async throws {
        let transport = FakeNotesTransport()
        await transport.refuseBeforeWrite()
        let outcome = try await NotesAdapter(transport: transport).call(verb, Self.arguments(verb))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(await transport.writes == 0)
    }

    static func arguments(_ verb: String) -> JSONValue {
        verb == "create_note" ? .object(["title": .string("Braus test"), "text": .string("one")])
            : .object(["id": .string("n-1"), "text": .string("Eggs")])
    }

    @Test("create_note reads the new note back, in the named folder")
    func create() async throws {
        let transport = FakeNotesTransport()
        let outcome = try await NotesAdapter(transport: transport).call("create_note", .object([
            "title": .string("Braus test"), "text": .string("one\ntwo"), "folder": .string("f-work"),
        ]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["folder"] == .string("Work"))
        #expect(outcome.result["text"] == .string("Braus test\none\ntwo"))
    }

    @Test("A07: a note created in a folder named by its id is confirmed in that folder, with its account")
    func createdInTheFolderAsked() async throws {
        let transport = FakeNotesTransport()
        let outcome = try await NotesAdapter(transport: transport).call("create_note", .object([
            "title": .string("Braus test"), "folder": .string("f-work-2"),
        ]))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("in Work (On My Mac)"), Comment(rawValue: outcome.message))
        #expect(outcome.result["folder_id"] == .string("f-work-2") && outcome.result["account"] == .string("On My Mac"))
    }

    @Test("A07: a note filed in a folder of the same name in another account is not confirmed, and written once")
    func misfiledNote() async throws {
        let transport = FakeNotesTransport()
        await transport.misfile(into: "f-work")
        let outcome = try await NotesAdapter(transport: transport).call("create_note", .object([
            "title": .string("Braus test"), "folder": .string("f-work-2"),
        ]))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("in Work (iCloud), not in Work (On My Mac)"),
                Comment(rawValue: outcome.message))
        #expect(await transport.writes == 1)
    }

    @Test("A07: a note whose folder does not read back is not confirmed in the folder asked")
    func folderNotReadBack() async throws {
        let transport = FakeNotesTransport()
        await transport.hideFolder()
        let outcome = try await NotesAdapter(transport: transport).call("create_note", .object([
            "title": .string("Braus test"), "folder": .string("f-work"),
        ]))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("not which folder"),
                Comment(rawValue: outcome.message))
    }

    @Test("A07: without a folder, the note is confirmed where Notes put it, its account read back")
    func defaultFolder() async throws {
        let outcome = try await NotesAdapter(transport: FakeNotesTransport()).call("create_note", .object([
            "title": .string("Braus test"),
        ]))
        #expect(outcome.kind == .foundActed && outcome.message.contains("in Notes (iCloud)"),
                Comment(rawValue: outcome.message))
    }

    @Test("The agent's text is escaped: markup stays text")
    func escaped() async throws {
        let transport = FakeNotesTransport()
        let outcome = try await NotesAdapter(transport: transport).call("create_note", .object([
            "title": .string("Braus test <b>"), "text": .string("<script>x</script> & co"),
        ]))
        #expect(outcome.kind == .foundActed)
        let html = try #require(await transport.html.values.first)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;x&lt;/script&gt; &amp; co"))
    }

    @Test("A folder named twice is ambiguous; an unknown one is a miss")
    func folders() async throws {
        let adapter = NotesAdapter(transport: FakeNotesTransport())
        let twice = try await adapter.call("create_note", .object(["title": .string("Braus test"), "folder": .string("work")]))
        #expect(twice.kind == .ambiguous)
        let none = try await adapter.call("find_notes", .object(["folder": .string("Recipes")]))
        #expect(none.kind == .honestMiss)
    }

    @Test("find_notes searches words, read_note answers the text")
    func findAndRead() async throws {
        let adapter = NotesAdapter(transport: FakeNotesTransport())
        let found = try await adapter.call("find_notes", .object(["query": .string("Milk")]))
        #expect(found.result["notes"].array?.first?["id"] == .string("n-1"))
        let note = try await adapter.call("read_note", .object(["id": .string("n-1")]))
        #expect(note.result["text"] == .string("Shopping\nMilk"))
        #expect(try await adapter.call("read_note", .object(["id": .string("n-9")])).kind == .honestMiss)
    }

    @Test("append_to_note reads the added text back and answers the previous length")
    func append() async throws {
        let outcome = try await NotesAdapter(transport: FakeNotesTransport()).call("append_to_note", .object([
            "id": .string("n-1"), "text": .string("Eggs"),
        ]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["previous_length"] == .number(13))
    }

    @Test("A Notes that does not keep the change is unverified")
    func unverified() async throws {
        let transport = FakeNotesTransport()
        await transport.dropWrites()
        let adapter = NotesAdapter(transport: transport)
        #expect(try await adapter.call("append_to_note", .object(["id": .string("n-1"), "text": .string("Eggs")])).kind
                == .actedUnverified)
        #expect(try await adapter.call("create_note", .object(["title": .string("Braus test")])).kind == .actedUnverified)
    }

    @Test("Live: a Braus test note is created, added to and read back", .enabled(if: Live.adapters))
    func live() async throws {
        let adapter = NotesAdapter(transport: MacNotesTransport())
        guard await adapter.availability().isReady else { return }
        let created = try await adapter.call("create_note", .object([
            "title": .string("Braus test"), "text": .string("Created by the Notes adapter's live test."),
        ]))
        guard created.kind != .refused else { return }
        #expect(created.kind == .foundActed)
        let id = try #require(created.result["id"].string)
        let appended = try await adapter.call("append_to_note", .object(["id": .string(id), "text": .string("Added.")]))
        #expect(appended.kind == .foundActed)
    }
}
