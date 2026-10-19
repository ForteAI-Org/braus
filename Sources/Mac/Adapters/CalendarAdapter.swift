import EngineCore
import Foundation
import LocalMCP

/// CalendarAdapter is Calendar's events through the Mac's store (EventKit): every account the Mac
/// syncs, with Calendar closed. Each change is read back from the store by the event's identifier.
///
/// Recurring events are refused for change and deletion: the store's identifier names the whole
/// series, and one occurrence is not addressable yet.
public struct CalendarAdapter: AppAdapting {

    public let name       = "calendar"
    public let appNames   = ["Calendar", "Calendario", "iCal"]
    public let bundleIDs: Set<String> = ["com.apple.iCal"]

    /// The widest window `find_events` reads at once.
    static let maximumDays = 366.0
    /// The most events one answer lists.
    static let maximumEvents = 50
    /// An event's words; its id, calendar and times stay recorded.
    static let contentResults = ["title", "location", "notes"]

    private let store: any EventStoring

    public init(store: any EventStoring) {
        self.store = store
    }

    public var verbs: [AdapterVerb] {
        let id = AdapterParameter("id", .string, "the event's id from find_events")
        let calendar = AdapterParameter("calendar", .string, "a calendar's title or id; default: the default calendar",
                                        required: false)
        return [
            AdapterVerb("list_calendars", "List the calendars, with account and whether they can be changed.",
                        safety: .read, readBack: "the store's calendars"),
            AdapterVerb("find_events", "Find events between two dates, optionally in one calendar or matching a text.",
                        parameters: [
                            AdapterParameter("from", .string, "ISO 8601 date or instant"),
                            AdapterParameter("to", .string, "ISO 8601 date or instant, at most 366 days after from"),
                            AdapterParameter("query", .string, "words the title, location or notes contain",
                                             required: false, content: true),
                            AdapterParameter("calendar", .string, "a calendar's title or id", required: false),
                        ],
                        safety: .read, readBack: "the store's events", contentResults: Self.contentResults),
            AdapterVerb("create_event", "Create an event.",
                        parameters: [
                            AdapterParameter("title", .string, "the event's title", content: true),
                            AdapterParameter("start", .string, "ISO 8601 instant, or a date for an all-day event"),
                            AdapterParameter("end", .string, "ISO 8601; default: one hour after start, or the same day",
                                             required: false),
                            AdapterParameter("all_day", .boolean, "true for an all-day event", required: false),
                            calendar,
                            AdapterParameter("location", .string, "where", required: false, content: true),
                            AdapterParameter("notes", .string, "notes", required: false, content: true),
                        ],
                        safety: .write, readBack: "the new event read from the store by its id",
                        contentResults: Self.contentResults),
            AdapterVerb("update_event", "Change an event's title, times, location or notes.",
                        parameters: [
                            id,
                            AdapterParameter("title", .string, "new title", required: false, content: true),
                            AdapterParameter("start", .string, "new ISO 8601 start", required: false),
                            AdapterParameter("end", .string, "new ISO 8601 end", required: false),
                            AdapterParameter("location", .string, "new location", required: false, content: true),
                            AdapterParameter("notes", .string, "new notes", required: false, content: true),
                        ],
                        safety: .write, readBack: "the event read again by its id", contentResults: Self.contentResults),
            AdapterVerb("delete_event", "Delete an event.", parameters: [id],
                        safety: .irreversible, readBack: "the event no longer in the store", confirms: .readBack,
                        contentResults: Self.contentResults),
        ]
    }

    public func availability() async -> AdapterAvailability {
        Self.availability(store.access(to: .events), of: "Calendars")
    }

    public func requestPermission() async -> AdapterAvailability {
        Self.availability(await store.requestAccess(to: .events), of: "Calendars")
    }

    static func availability(_ access: EventStoreAccess, of section: String) -> AdapterAvailability {
        switch access {
            case .granted: .ready
            case .notDetermined, .denied:
                .needsPermission("Braus has no full access to \(section). The person grants it in System Settings > "
                                 + "Privacy & Security > \(section), for the app Braus runs in.")
        }
    }

    /// An event to delete is named by its id, which says nothing to the person: they read its title and when it
    /// starts. One that cannot be read is shown by its id, and the call answers whether it exists.
    public func consentArguments(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async -> [String: JSONValue] {
        guard verb == "delete_event", let id = arguments["id"].string,
              let event = try? await store.event(id: id) else { return AdapterConsent.arguments(arguments) }
        return [
            "title": .string(AdapterConsent.excerpt(event.title)),
            "date" : .string(event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)),
        ]
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        switch verb {
            case "list_calendars":
                let calendars = try await store.calendars(of: .events)
                return .confirmed("\(calendars.count) calendars.", .object(["calendars": .array(calendars.map(Self.json))]))
            case "find_events":  return try await find(arguments)
            case "create_event": return try await create(arguments)
            case "update_event": return try await update(arguments)
            case "delete_event": return try await delete(id: try arguments.required("id"))
            default:             throw AdapterFailure("calendar has no verb \(verb).")
        }
    }

    // MARK: Verbs

    private func find(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        let from = try arguments.requiredDate("from")
        var to   = try arguments.requiredDate("to")
        // A day alone as the end means the whole of that day.
        if let text = arguments.string("to"), !text.contains("T") { to = to.addingTimeInterval(24 * 3600) }
        guard to > from else { return .refused("to must come after from.") }
        guard to.timeIntervalSince(from) <= Self.maximumDays * 24 * 3600 else {
            return .refused("find_events reads at most \(Int(Self.maximumDays)) days at once.")
        }
        var calendarIDs: [String]?
        if let wanted = arguments.string("calendar") {
            switch Self.pick(wanted, in: try await store.calendars(of: .events), kind: "calendar") {
                case .found(let calendar): calendarIDs = [calendar.id]
                case .outcome(let outcome): return outcome
            }
        }
        var events = try await store.events(from: from, to: to, calendarIDs: calendarIDs)
        if let query = arguments.string("query")?.lowercased() {
            let words = query.split(whereSeparator: \.isWhitespace)
            events = events.filter { event in
                let text = [event.title, event.location ?? "", event.notes ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        events.sort { $0.start < $1.start }
        let shown = events.prefix(Self.maximumEvents)
        var result: [String: JSONValue] = ["events": .array(shown.map(Self.json))]
        if events.count > shown.count { result["more"] = .number(Double(events.count - shown.count)) }
        let more = events.count > shown.count ? ", first \(shown.count) shown" : ""
        return .confirmed("\(events.count) events\(more).", .object(result))
    }

    private func create(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        let start    = try arguments.requiredDate("start")
        let startDay = !(arguments.string("start")?.contains("T") ?? true)
        let allDay   = arguments.bool("all_day") ?? startDay
        let end      = try arguments.date("end") ?? start.addingTimeInterval(allDay ? 24 * 3600 : 3600)
        guard end >= start else { return .refused("end must not come before start.") }
        var calendarID: String?
        if let wanted = arguments.string("calendar") {
            switch Self.pick(wanted, in: try await store.calendars(of: .events), kind: "calendar") {
                case .found(let calendar):
                    guard calendar.isWritable else { return .refused("The calendar \(calendar.title) cannot be changed.") }
                    calendarID = calendar.id
                case .outcome(let outcome):
                    return outcome
            }
        }
        let draft = StoreEventDraft(title: try arguments.required("title"), start: start, end: end, isAllDay: allDay,
                                    calendarID: calendarID, location: arguments.string("location"),
                                    notes: arguments.string("notes"))
        let id: String
        do {
            id = try await store.createEvent(draft)
        } catch {
            return .mayHaveHappened("The store was asked to create \(draft.title)", because: error,
                                    look: "Find the event", result: .object(["title": .string(draft.title)]))
        }
        let created: JSONValue = .object(["id": .string(id)])
        return await .afterChange("The store took the event", look: "Read the event by its id", result: created) {
            guard let saved = try await store.event(id: id) else {
                return AdapterOutcome(.actedUnverified, "The store took the event, but it does not read back.",
                                      result: created)
            }
            // The event as asked for: its fields, and the calendar asked for, which fixes its account (A07).
            var other: [String] = []
            if saved.title != draft.title { other.append("title") }
            if saved.isAllDay != allDay {
                other.append(allDay ? "kind: it is timed, not all-day" : "kind: it is all-day")
            }
            if allDay {
                // An all-day event by its days, in the Mac's time zone, the one a day alone is read in: its first day,
                // and its last, which an end at the next midnight or just before it both name.
                if !Self.sameDay(saved.start, start) { other.append("first day") }
                if !Self.sameDay(saved.end.addingTimeInterval(-1), end.addingTimeInterval(-1)) {
                    other.append("last day")
                }
            } else {
                if abs(saved.start.timeIntervalSince(start)) >= 1 { other.append("start") }
                if abs(saved.end.timeIntervalSince(end)) >= 1 { other.append("end") }
            }
            if let location = draft.location, saved.location != location { other.append("location") }
            if let notes = draft.notes, saved.notes != notes { other.append("notes") }
            if let calendarID, saved.calendarID != calendarID {
                let calendars = try await store.calendars(of: .events)
                let landed = calendars.first { $0.id == saved.calendarID }
                other.append("calendar: it is in \(landed.map { "\($0.title) (\($0.account))" } ?? saved.calendarID), "
                             + "not the one asked for")
            }
            guard other.isEmpty else {
                return AdapterOutcome(.actedUnverified, "The store took the event, but it reads back with another "
                                      + other.joined(separator: ", ") + ". Find it before creating it again.",
                                      result: Self.json(saved))
            }
            return .confirmed("Created \(saved.title).", Self.json(saved))
        }
    }

    private func update(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        let id = try arguments.required("id")
        let changes = StoreEventChanges(title: arguments.string("title"), start: try arguments.date("start"),
                                        end: try arguments.date("end"), location: arguments.string("location"),
                                        notes: arguments.string("notes"))
        guard !changes.isEmpty else { return .refused("update_event needs at least one field to change.") }
        guard let before = try await store.event(id: id) else { return .missing("No event \(id).") }
        if before.isRecurring { return .refused(Self.recurring) }
        let start = changes.start ?? before.start, end = changes.end ?? before.end
        guard end >= start else { return .refused("end must not come before start.") }
        let previous: JSONValue = .object(["previous": Self.json(before)])
        do {
            try await store.updateEvent(id: id, changes)
        } catch {
            return .mayHaveHappened("The store was asked to change \(before.title)", because: error,
                                    look: "Read the event by its id", result: previous)
        }
        return await .afterChange("The store took the change", look: "Read the event by its id", result: previous) {
            guard let after = try await store.event(id: id) else {
                return AdapterOutcome(.actedUnverified, "The event did not read back after the change.",
                                      result: previous)
            }
            // What was changed holds, and the event stayed in its calendar (A07).
            let holds = (changes.title.map { $0 == after.title } ?? true)
                && (changes.start.map { abs($0.timeIntervalSince(after.start)) < 1 } ?? true)
                && (changes.end.map { abs($0.timeIntervalSince(after.end)) < 1 } ?? true)
                && (changes.location.map { $0 == after.location } ?? true)
                && (changes.notes.map { $0 == after.notes } ?? true)
                && after.calendarID == before.calendarID
            let result = JSONValue.object(["event": Self.json(after), "previous": Self.json(before)])
            guard holds else {
                return AdapterOutcome(.actedUnverified, "The event did not read back as changed.", result: result)
            }
            return .confirmed("Changed \(after.title).", result)
        }
    }

    private func delete(id: String) async throws -> AdapterOutcome {
        guard let event = try await store.event(id: id) else { return .missing("No event \(id).") }
        if event.isRecurring { return .refused(Self.recurring) }
        let deleted: JSONValue = .object(["deleted": Self.json(event)])
        do {
            try await store.deleteEvent(id: id)
        } catch {
            return .mayHaveHappened("The store was asked to delete \(event.title)", because: error,
                                    look: "Read the event by its id", result: deleted)
        }
        return await .afterChange("The store took the deletion", look: "Read the event by its id", result: deleted) {
            guard try await store.event(id: id) == nil else {
                return AdapterOutcome(.actedUnverified, "The event is still in the store.", result: deleted)
            }
            return .confirmed("Deleted \(event.title).", deleted)
        }
    }

    /// Whether two instants fall on one day of the Mac's calendar, in its time zone.
    static func sameDay(_ first: Date, _ second: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.isDate(first, inSameDayAs: second)
    }

    private static let recurring = "This event repeats; changing one occurrence through the adapter is not supported yet. "
        + "Use open_session on Calendar."

    // MARK: Shared with Reminders

    enum Pick {
        case found(StoreCalendar)
        case outcome(AdapterOutcome)
    }

    /// The calendar or list a person named, by id or by title without case.
    static func pick(_ wanted: String, in calendars: [StoreCalendar], kind: String) -> Pick {
        if let exact = calendars.first(where: { $0.id == wanted }) { return .found(exact) }
        let titled = calendars.filter { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }
        switch titled.count {
            case 1:
                return .found(titled[0])
            case 0:
                let names = calendars.map(\.title).joined(separator: ", ")
                return .outcome(.missing("No \(kind) \(wanted). There are: \(names)."))
            default:
                let accounts = titled.map { "\($0.title) (\($0.account), id \($0.id))" }.joined(separator: "; ")
                return .outcome(AdapterOutcome(.ambiguous, "Several \(kind)s are called \(wanted): \(accounts). Pass the id."))
        }
    }

    static func json(_ calendar: StoreCalendar) -> JSONValue {
        .object(["id": .string(calendar.id), "title": .string(calendar.title), "account": .string(calendar.account),
                 "writable": .bool(calendar.isWritable), "default": .bool(calendar.isDefault)])
    }

    static func json(_ event: StoreEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(event.id), "title": .string(event.title), "calendar": .string(event.calendarID),
            "start": .string(AdapterArguments.text(event.start)), "end": .string(AdapterArguments.text(event.end)),
            "all_day": .bool(event.isAllDay),
        ]
        if let location = event.location, !location.isEmpty { object["location"] = .string(location) }
        if let notes = event.notes, !notes.isEmpty { object["notes"] = .string(notes) }
        if event.isRecurring { object["recurring"] = .bool(true) }
        return .object(object)
    }
}
