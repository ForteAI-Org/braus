//
//  AdapterContentRecordingTests.swift
//  Braus
//
//  Created by Eliomar Rodriguez on 19/10/2026.
//

import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import Testing

/// What a person writes, reads or is called, given to an adapter or answered by it, reaches the model and never a
/// record: not the recorded request, not a transcript line, not the archive. Each adapter runs on an in-memory
/// transport whose every text carries the canary.
@Suite("Adapter content stays out of the records")
@MainActor
struct AdapterContentRecordingTests {

    nonisolated static let canary = "cnry5821"

    /// One adapter and the calls that pass the canary through it, each answered as confirmed.
    struct Scenario: Sendable, CustomTestStringConvertible {
        let adapter: @Sendable () -> any AppAdapting
        let calls  : [(verb: String, arguments: [String: JSONValue])]
        let name   : String
        var testDescription: String { name }
    }

    nonisolated static let scenarios: [Scenario] = [
        Scenario(adapter: { MailAdapter(transport: CanaryMail(), readBackPause: .zero) }, calls: [
            ("find_messages", ["query": .string(canary)]),
            ("read_message", ["id": .string("<m1@x>")]),
            ("send", ["to": .string("\(canary)@example.com"), "subject": .string("\(canary) hello"),
                      "body": .string("\(canary) words"), "from": .string("\(canary).me@example.com")]),
        ], name: "mail"),
        Scenario(adapter: { MessagesAdapter(transport: CanaryMessages(), readBackPause: .zero) }, calls: [
            ("send_message", ["to": .string("\(canary)@example.com"), "text": .string("\(canary) text")]),
        ], name: "messages"),
        Scenario(adapter: { NotesAdapter(transport: CanaryNotes()) }, calls: [
            ("find_notes", ["query": .string(canary)]),
            ("read_note", ["id": .string("n-1")]),
            ("create_note", ["title": .string("\(canary) new"), "text": .string("\(canary) more")]),
            ("append_to_note", ["id": .string("n-1"), "text": .string("\(canary) added")]),
        ], name: "notes"),
        Scenario(adapter: { ContactsAdapter(store: CanaryContacts()) }, calls: [
            ("find_contacts", ["name": .string(canary)]),
            ("read_contact", ["id": .string("p-1")]),
        ], name: "contacts"),
        Scenario(adapter: { CalendarAdapter(store: CanaryEvents()) }, calls: [
            ("create_event", ["title": .string("\(canary) lunch"), "start": .string("2026-10-20T12:00:00Z"),
                              "location": .string("\(canary) place"), "notes": .string("\(canary) notes")]),
            ("find_events", ["from": .string("2026-10-20"), "to": .string("2026-10-21"), "query": .string(canary)]),
            ("update_event", ["id": .string("e-1"), "title": .string("\(canary) dinner")]),
            ("delete_event", ["id": .string("e-1")]),
        ], name: "calendar"),
        Scenario(adapter: { RemindersAdapter(store: CanaryEvents()) }, calls: [
            ("create_reminder", ["title": .string("\(canary) buy"), "notes": .string("\(canary) note")]),
            ("find_reminders", ["query": .string(canary)]),
            ("complete_reminder", ["id": .string("r-1")]),
        ], name: "reminders"),
    ]

    @Test("an adapter's content reaches the model, and neither its recorded request, its transcript nor the archive",
          arguments: scenarios)
    func contentWithheld(_ scenario: Scenario) async throws {
        let directory = try W.directory()
        let adapter   = scenario.adapter()
        let tools     = AutomationTools(session: RecordedSession(directory: directory),
                                        adapters: AppAdapters([adapter], approver: Allowing()))
        var lines = [String]()
        tools.record   = { lines.append($0) }
        tools.producer = CallProducer(source: .mcp, streamID: "mcp-profile", traceID: "content-\(scenario.name)")
        var answers = [String]()
        for call in scenario.calls {
            let answer = try await tools.call("app_call", .object([
                "app": .string(adapter.name), "verb": .string(call.verb), "arguments": .object(call.arguments),
            ]))
            answers.append(String(describing: answer))
        }
        #expect(answers.contains { $0.contains(Self.canary) }, "the model reads the content")
        let service = MemoryService.shared(for: directory)
        #expect(await service.flush(within: .seconds(10)))
        let calls = try await service.calls(inTrace: "content-\(scenario.name)")
        #expect(calls.count == scenario.calls.count)
        for call in calls {
            if case .outcome(let kind, _)? = call.progress.result { #expect(kind == .foundActed, "\(call.request)") }
            else { Issue.record("outcome missing for \(call.request)") }
            #expect(!String(describing: call.request).contains(Self.canary), "\(call.request)")
            #expect(!String(describing: call.progress.result).contains(Self.canary))
        }
        #expect(!lines.isEmpty && lines.allSatisfy { !$0.contains(Self.canary) }, "\(lines)")
        await service.close()
        #expect(try archiveOccurrences(of: Self.canary, in: directory.appendingPathComponent("memory.sqlite")).isEmpty)
    }

    @Test("a content result's key keeps its place in the transcript, inside lists of objects too")
    func structureKept() async throws {
        let tools = AutomationTools(session: RecordedSession(directory: try W.directory()),
                                    adapters: AppAdapters([MailAdapter(transport: CanaryMail())]))
        var lines = [String]()
        tools.record = { lines.append($0) }
        _ = try await tools.call("app_call", .object([
            "app": .string("mail"), "verb": .string("find_messages"),
            "arguments": .object(["query": .string(Self.canary)]),
        ]))
        let answer = try #require(lines.last)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(answer.dropFirst("← app_call ".count).utf8))
        let message = try #require(json["result"]["messages"].array?.first)
        #expect(message["subject"].string == "[withheld]" && message["sender"].string == "[withheld]")
        #expect(message["id"].string == "<m1@x>" && message["read"] == .bool(false), "ids and states stay")
        #expect(lines.first?.contains(#""query":"[withheld]""#) == true, "\(lines)")
    }
}

/// Allowing answers yes to every irreversible call.
private struct Allowing: AdapterApproving {
    func approve(_ consent: AdapterConsent) async -> Bool { true }
}

private let canary = AdapterContentRecordingTests.canary

/// CanaryMail is a Mail with one message in the inbox and a sent mailbox that files every send.
private actor CanaryMail: MailTransporting {
    var inbox = [MailMessage(id: "<m1@x>", subject: "\(canary) subject", sender: "\(canary) <\(canary)@example.com>",
                             date: Date(timeIntervalSince1970: 1_000), isRead: false,
                             recipients: ["\(canary).me@example.com"], content: "\(canary) body")]
    var sentBox: [MailMessage] = []

    func availability() async -> AdapterAvailability { .ready }
    func messages(matching query: String?, unreadOnly: Bool, limit: Int) async throws -> [MailMessage] { inbox }
    func message(id: String) async throws -> MailMessage? { (inbox + sentBox).first { $0.id == id } }
    func send(to address: String, subject: String, body: String, from sender: String?) async throws {
        sentBox.append(MailMessage(id: "<s\(sentBox.count)@x>", subject: subject, sender: sender ?? "", date: Date(),
                                   recipients: [address], content: body))
    }
    func saveDraft(to address: String?, subject: String, body: String, from sender: String?) async throws {}
    func drafts(subject: String) async throws -> [MailMessage] { [] }
    func sent(subject: String, since: Date) async throws -> [MailMessage] { sentBox.filter { $0.subject == subject } }
}

/// CanaryMessages is a Messages whose history records every send.
private actor CanaryMessages: MessagesTransporting {
    var log: [SentMessage] = []

    func availability() async -> AdapterAvailability { .ready }
    func send(_ text: String, to handle: String) async throws {
        log.append(SentMessage(id: "row-\(log.count)", handle: handle, text: text, date: Date()))
    }
    func sent(since: Date) async throws -> [SentMessage]? { log }
}

/// CanaryNotes is a Notes with one note, turning the adapter's HTML into plain text as Notes does.
private actor CanaryNotes: NotesTransporting {
    var notes = [StoreNote(id: "n-1", title: "\(canary) title", folder: "Notes", modified: Date(),
                           text: "\(canary) title\n\(canary) line", folderID: "f-1", account: "iCloud")]

    func availability() async -> AdapterAvailability { .ready }
    func folders() async throws -> [NotesFolder] {
        [NotesFolder(id: "f-1", name: "Notes", account: "iCloud", count: 1)]
    }
    func notes(matching query: String?, folderID: String?, limit: Int) async throws -> [StoreNote] { notes }
    func note(id: String) async throws -> StoreNote? { notes.first { $0.id == id } }
    func content(id: String) async throws -> (body: String, attachments: Int)? {
        notes.contains { $0.id == id } ? ("<div>text</div>", 0) : nil
    }
    func create(html: String, folderID: String?) async throws -> String {
        let text = Self.plain(html)
        let id   = "n-\(notes.count + 1)"
        notes.append(StoreNote(id: id, title: String(text.prefix { $0 != "\n" }), folder: "Notes", modified: Date(),
                               text: text, folderID: "f-1", account: "iCloud"))
        return id
    }
    func append(html: String, to id: String) async throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[index]
        notes[index] = StoreNote(id: note.id, title: note.title, folder: note.folder, modified: Date(),
                                 text: (note.text ?? "") + "\n" + Self.plain(html), folderID: note.folderID,
                                 account: note.account)
    }

    private static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }
}

/// CanaryContacts is an address book of one person, every field of whom carries the canary.
private struct CanaryContacts: ContactsStoring {
    let person = StoreContact(id: "p-1", name: "\(canary) Rossi", organization: "\(canary) Org",
                              phones: [.init("mobile", "+39 333 \(canary)")],
                              emails: [.init("work", "\(canary)@x.com")],
                              addresses: [.init("home", "Via \(canary) 1")], birthday: "1931-07-14")

    func access() -> ContactsAccess { .granted }
    func contacts(matching name: String) async throws -> [StoreContact] { [person] }
    func contact(id: String) async throws -> StoreContact? { id == person.id ? person : nil }
}

/// CanaryEvents is a store of one calendar and one list, which keeps every event and reminder made in it.
private actor CanaryEvents: EventStoring {
    var events   : [StoreEvent] = []
    var reminders: [StoreReminder] = []
    let calendar = StoreCalendar(id: "c-1", title: "Home", account: "iCloud", isWritable: true, isDefault: true)

    nonisolated func access(to kind: EventStoreKind) -> EventStoreAccess { .granted }
    func calendars(of kind: EventStoreKind) async throws -> [StoreCalendar] { [calendar] }
    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [StoreEvent] { events }
    func event(id: String) async throws -> StoreEvent? { events.first { $0.id == id } }
    func createEvent(_ draft: StoreEventDraft) async throws -> String {
        let id = "e-\(events.count + 1)"
        events.append(StoreEvent(id: id, title: draft.title, start: draft.start, end: draft.end,
                                 isAllDay: draft.isAllDay, calendarID: calendar.id, location: draft.location,
                                 notes: draft.notes))
        return id
    }
    func updateEvent(id: String, _ changes: StoreEventChanges) async throws {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        if let title = changes.title { events[index].title = title }
    }
    func deleteEvent(id: String) async throws { events.removeAll { $0.id == id } }
    func reminders(listIDs: [String]?, includeCompleted: Bool) async throws -> [StoreReminder] { reminders }
    func reminder(id: String) async throws -> StoreReminder? { reminders.first { $0.id == id } }
    func createReminder(_ draft: StoreReminderDraft) async throws -> String {
        let id = "r-\(reminders.count + 1)"
        reminders.append(StoreReminder(id: id, title: draft.title, listID: calendar.id, due: draft.due,
                                       notes: draft.notes))
        return id
    }
    func completeReminder(id: String) async throws {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isCompleted = true
    }
}
