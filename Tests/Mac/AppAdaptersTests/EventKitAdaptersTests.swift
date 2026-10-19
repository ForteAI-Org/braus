import AppAdapters
import EngineCore
import Foundation
import LocalMCP
import Testing

/// The Calendar and Reminders adapters on an in-memory store: each change read back by identifier,
/// calendars picked by title or id, recurring events left to the interface.
@Suite("Calendar and Reminders adapters")
struct EventKitAdaptersTests {

    static let day = "2026-10-15"

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date.distantPast
    }

    /// The ids of the events a find answered, in order.
    static func ids(_ outcome: AdapterOutcome) -> [String] {
        outcome.result["events"].array?.compactMap { $0["id"].string } ?? []
    }

    @Test("create_event defaults to one hour, saves in the named calendar and reads the event back")
    func createEvent() async throws {
        let store = FakeEventStore()
        let outcome = try await CalendarAdapter(store: store).call("create_event", .object([
            "title": .string("Braus test"), "start": .string("2026-10-15T09:00:00Z"), "calendar": .string("work"),
        ]))
        #expect(outcome.kind == .foundActed)
        let saved = try #require(await store.events.first)
        #expect(saved.calendarID == "work")
        #expect(saved.end.timeIntervalSince(saved.start) == 3600)
        #expect(outcome.result["id"] == .string(saved.id))
    }

    @Test("A day alone makes an all-day event, confirmed on its day")
    func allDay() async throws {
        let store = FakeEventStore()
        let outcome = try await CalendarAdapter(store: store).call("create_event", .object([
            "title": .string("Braus test"), "start": .string(Self.day),
        ]))
        #expect(await store.events.first?.isAllDay == true)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
    }

    @Test("A07: an event saved timed when asked all-day, or all-day when asked timed, is unverified, and says its kind",
          arguments: [true, false])
    func allDayFlag(askedAllDay: Bool) async throws {
        let store = FakeEventStore()
        await store.flipAllDay()
        let outcome = try await CalendarAdapter(store: store).call("create_event", .object([
            "title": .string("Braus test"), "start": .string(askedAllDay ? Self.day : "2026-10-15T09:00:00Z"),
        ]))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("kind"), Comment(rawValue: outcome.message))
    }

    @Test("A07: an all-day event saved on another day, or a timed one at another time, is unverified",
          arguments: [true, false])
    func shiftedEvent(askedAllDay: Bool) async throws {
        let store = FakeEventStore()
        await store.shiftDays(by: 1)
        let outcome = try await CalendarAdapter(store: store).call("create_event", .object([
            "title": .string("Braus test"), "start": .string(askedAllDay ? Self.day : "2026-10-15T09:00:00Z"),
        ]))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains(askedAllDay ? "first day" : "start"), Comment(rawValue: outcome.message))
    }

    @Test("A store that drops the write leaves the outcome unverified")
    func createUnverified() async throws {
        let store = FakeEventStore()
        await store.dropWrites()
        let outcome = try await CalendarAdapter(store: store).call("create_event", .object([
            "title": .string("Braus test"), "start": .string("2026-10-15T09:00:00Z"),
        ]))
        #expect(outcome.kind == .actedUnverified)
    }

    @Test("A calendar is picked by id or title; unknown is a miss, two titles are ambiguous, read-only is refused")
    func pickCalendar() async throws {
        let store = FakeEventStore()
        await store.addCalendar(StoreCalendar(id: "work2", title: "Work", account: "Exchange", isWritable: true,
                                              isDefault: false))
        let adapter = CalendarAdapter(store: store)
        func create(in calendar: String) async throws -> AdapterOutcome {
            try await adapter.call("create_event", .object([
                "title": .string("Braus test"), "start": .string("2026-10-15T09:00:00Z"), "calendar": .string(calendar),
            ]))
        }
        #expect(try await create(in: "Gym").kind == .honestMiss)
        #expect(try await create(in: "WORK").kind == .ambiguous)
        #expect(try await create(in: "work").kind == .foundActed)
        #expect(try await create(in: "holidays").kind == .refused)
        #expect(try await create(in: "work2").kind == .foundActed)
    }

    @Test("find_events reads the window, filters by words, sorts by start; a day as `to` includes that day")
    func findEvents() async throws {
        let store = FakeEventStore()
        await store.add(StoreEvent(id: "b", title: "Dentist", start: Self.date("2026-10-15T15:00:00Z"),
                                   end: Self.date("2026-10-15T16:00:00Z"), isAllDay: false, calendarID: "home"))
        await store.add(StoreEvent(id: "a", title: "Standup", start: Self.date("2026-10-15T08:00:00Z"),
                                   end: Self.date("2026-10-15T08:15:00Z"), isAllDay: false, calendarID: "work",
                                   location: "Room 2"))
        await store.add(StoreEvent(id: "c", title: "Later", start: Self.date("2026-11-20T08:00:00Z"),
                                   end: Self.date("2026-11-20T09:00:00Z"), isAllDay: false, calendarID: "work"))
        let adapter = CalendarAdapter(store: store)
        let all = try await adapter.call("find_events", .object(["from": .string("2026-10-15T00:00:00Z"),
                                                                 "to": .string("2026-10-16T00:00:00Z")]))
        #expect(Self.ids(all) == ["a", "b"])
        let room = try await adapter.call("find_events", .object(["from": .string("2026-10-15T00:00:00Z"),
                                                                  "to": .string("2026-10-16T00:00:00Z"),
                                                                  "query": .string("room 2")]))
        #expect(Self.ids(room) == ["a"])
        let tooWide = try await adapter.call("find_events", .object(["from": .string("2026-01-01"),
                                                                     "to": .string("2027-06-01")]))
        #expect(tooWide.kind == .refused)
        let badDate = await #expect(throws: AdapterFailure.self) {
            try await adapter.call("find_events", .object(["from": .string("tomorrow"), "to": .string("2026-10-16")]))
        }
        #expect(badDate?.description.contains("ISO 8601") == true)
    }

    @Test("update_event changes only what it names, answers the previous event, refuses a recurring one")
    func updateEvent() async throws {
        let store = FakeEventStore()
        let start = Self.date("2026-10-15T09:00:00Z")
        await store.add(StoreEvent(id: "e1", title: "Braus test", start: start, end: start.addingTimeInterval(3600),
                                   isAllDay: false, calendarID: "home", location: "Here"))
        await store.add(StoreEvent(id: "r1", title: "Weekly", start: start, end: start.addingTimeInterval(3600),
                                   isAllDay: false, calendarID: "home", isRecurring: true))
        let adapter = CalendarAdapter(store: store)
        let outcome = try await adapter.call("update_event", .object(["id": .string("e1"), "title": .string("Renamed")]))
        #expect(outcome.kind == .foundActed)
        #expect(outcome.result["previous"]["title"] == .string("Braus test"))
        #expect(await store.events.first?.location == "Here")
        #expect(try await adapter.call("update_event", .object(["id": .string("r1"), "title": .string("x")])).kind == .refused)
        #expect(try await adapter.call("update_event", .object(["id": .string("e1")])).kind == .refused)
        #expect(try await adapter.call("update_event", .object(["id": .string("nope"), "title": .string("x")])).kind
                == .honestMiss)
    }

    static let workEvent: JSONValue = .object([
        "title": .string("Braus test"), "start": .string("2026-10-15T09:00:00Z"), "calendar": .string("work"),
        "location": .string("Room 4"), "notes": .string("Bring the slides"),
    ])

    @Test("A07: an event the store files in another calendar than the one asked for is unverified, and names where it is and its account")
    func misfiledEvent() async throws {
        let store = FakeEventStore()
        await store.misfile(into: "home")
        let outcome = try await CalendarAdapter(store: store).call("create_event", Self.workEvent)
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("Home (iCloud)") && outcome.message.contains("not the one asked for"),
                Comment(rawValue: outcome.message))
    }

    @Test("A07: a calendar of the same title in another account is not the one asked for")
    func sameTitleOtherAccount() async throws {
        let store = FakeEventStore()
        await store.addCalendar(StoreCalendar(id: "work-x", title: "Work", account: "Exchange", isWritable: true,
                                              isDefault: false))
        await store.misfile(into: "work-x")
        let outcome = try await CalendarAdapter(store: store).call("create_event", Self.workEvent)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("Work (Exchange)"),
                Comment(rawValue: outcome.message))
    }

    @Test("A07: an event that reads back without the notes it was given is unverified")
    func eventWithoutItsNotes() async throws {
        let store = FakeEventStore()
        await store.dropNotes()
        let outcome = try await CalendarAdapter(store: store).call("create_event", Self.workEvent)
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("notes"), Comment(rawValue: outcome.message))
    }

    @Test("A07: a reminder the store files in another list than the one asked for is unverified")
    func misfiledReminder() async throws {
        let store = FakeEventStore()
        await store.misfile(into: "inbox")
        let outcome = try await RemindersAdapter(store: store).call("create_reminder", .object([
            "title": .string("Braus test milk"), "list": .string("shopping"),
        ]))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("Reminders (iCloud)"),
                Comment(rawValue: outcome.message))
    }

    @Test("A08: the store failing to read after the save, or failing the save after applying it: unverified, it may have happened, saved once",
          arguments: ["read", "write"])
    func failureAfterSave(failure: String) async throws {
        for verb in ["create_event", "create_reminder"] {
            let store = FakeEventStore()
            if failure == "read" {
                await store.failReads(afterWrite: AdapterFailure("the store did not answer"))
            } else {
                await store.failWrites(with: AdapterFailure("the store did not answer"))
            }
            let outcome = verb == "create_event"
                ? try await CalendarAdapter(store: store).call(verb, Self.workEvent)
                : try await RemindersAdapter(store: store).call(verb, .object(["title": .string("Braus test milk")]))
            #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                    "\(verb): \(outcome.message)")
            #expect(await store.writes == 1, "\(verb)")
        }
    }

    @Test("A08: a change, a completion and a deletion whose read-back fails are unverified, it may have happened, never thrown",
          arguments: ["update_event", "delete_event", "complete_reminder"])
    func otherChangesAfterFailure(verb: String) async throws {
        let store = FakeEventStore()
        await store.add(StoreEvent(id: "e-1", title: "Standup", start: Self.date("2026-10-15T09:00:00Z"),
                                   end: Self.date("2026-10-15T09:15:00Z"), isAllDay: false, calendarID: "work"))
        await store.add(StoreReminder(id: "r-1", title: "Milk", listID: "shop"))
        await store.failReads(afterWrite: AutomationPermissionNeeded("Allow Calendars."))
        let outcome: AdapterOutcome = switch verb {
            case "update_event":
                try await CalendarAdapter(store: store).call(verb, .object(["id": .string("e-1"), "title": .string("Sync")]))
            case "delete_event":
                try await CalendarAdapter(store: store).call(verb, .object(["id": .string("e-1")]))
            default:
                try await RemindersAdapter(store: store).call(verb, .object(["id": .string("r-1")]))
        }
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("may have happened"),
                Comment(rawValue: outcome.message))
        #expect(await store.writes == 1)
    }

    @Test("A08: a call cancelled while it reads the new event back keeps the receipt: unverified, it may have happened")
    func cancelledReadBack() async throws {
        let store = FakeEventStore()
        await store.slowReads(.seconds(5))
        let adapter = CalendarAdapter(store: store)
        let call = Task { try await adapter.call("create_event", Self.workEvent) }
        try await Task.sleep(for: .milliseconds(150))
        call.cancel()
        let outcome = try await call.value
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("cancelled"), Comment(rawValue: outcome.message))
        #expect(await store.writes == 1)
    }

    @Test("Reminders: create in a list by title, find by words, complete once, then a no-op")
    func reminders() async throws {
        let store = FakeEventStore()
        let adapter = RemindersAdapter(store: store)
        let created = try await adapter.call("create_reminder", .object(["title": .string("Braus test milk"),
                                                                         "list": .string("shopping")]))
        #expect(created.kind == .foundActed)
        let id = try #require(created.result["id"].string)
        #expect(await store.reminders.first?.listID == "shop")
        let found = try await adapter.call("find_reminders", .object(["query": .string("milk")]))
        #expect(found.result["reminders"].array?.count == 1)
        #expect(try await adapter.call("complete_reminder", .object(["id": .string(id)])).kind == .foundActed)
        #expect(try await adapter.call("complete_reminder", .object(["id": .string(id)])).kind == .actedNoop)
        let open = try await adapter.call("find_reminders", .object([:]))
        #expect(open.result["reminders"].array?.isEmpty == true)
    }
}
