import EngineCore
import Foundation
import LocalMCP

/// RemindersAdapter is Reminders' lists and reminders through the Mac's store (EventKit), with
/// Reminders closed. Each change is read back from the store by the reminder's identifier.
public struct RemindersAdapter: AppAdapting {

    public let name       = "reminders"
    public let appNames   = ["Reminders", "Promemoria"]
    public let bundleIDs: Set<String> = ["com.apple.reminders"]

    /// The most reminders one answer lists.
    static let maximumReminders = 100
    /// A reminder's words; its id, list, due date and state stay recorded.
    static let contentResults = ["title", "notes"]

    private let store: any EventStoring

    public init(store: any EventStoring) {
        self.store = store
    }

    public var verbs: [AdapterVerb] {
        [
            AdapterVerb("list_lists", "List the reminder lists, with account.",
                        safety: .read, readBack: "the store's lists", results: .identifiersAndDates),
            AdapterVerb("find_reminders", "Find reminders, optionally in one list or matching a text.",
                        parameters: [
                            AdapterParameter("list", .string, "a list's title or id", required: false),
                            AdapterParameter("query", .string, "words the title or notes contain", required: false,
                                             confidential: .sensitiveMetadata),
                            AdapterParameter("include_completed", .boolean, "default false", required: false),
                        ],
                        safety: .read, readBack: "the store's reminders", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("create_reminder", "Create a reminder.",
                        parameters: [
                            AdapterParameter("title", .string, "what to remember", confidential: .content),
                            AdapterParameter("list", .string, "a list's title or id; default: the default list",
                                             required: false),
                            AdapterParameter("due", .string, "ISO 8601 date or instant", required: false),
                            AdapterParameter("notes", .string, "notes", required: false, confidential: .content),
                        ],
                        safety: .write, readBack: "the new reminder read from the store by its id",
                        contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("complete_reminder", "Mark a reminder as done.",
                        parameters: [AdapterParameter("id", .string, "the reminder's id from find_reminders")],
                        safety: .write, readBack: "the reminder read again, completed", contentResults: Self.contentResults, results: .identifiersAndDates),
        ]
    }

    public func availability() async -> AdapterAvailability {
        CalendarAdapter.availability(store.access(to: .reminders), of: "Reminders")
    }

    public func requestPermission() async -> AdapterAvailability {
        CalendarAdapter.availability(await store.requestAccess(to: .reminders), of: "Reminders")
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        switch verb {
            case "list_lists":
                let lists = try await store.calendars(of: .reminders)
                return .confirmed("\(lists.count) lists.", .object(["lists": .array(lists.map(CalendarAdapter.json))]))
            case "find_reminders":
                return try await find(arguments)
            case "create_reminder":
                return try await create(arguments)
            case "complete_reminder":
                return try await complete(id: try arguments.required("id"))
            default:
                throw AdapterFailure("reminders has no verb \(verb).")
        }
    }

    private func find(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        var listIDs: [String]?
        if let wanted = arguments.string("list") {
            switch CalendarAdapter.pick(wanted, in: try await store.calendars(of: .reminders), kind: "list") {
                case .found(let list): listIDs = [list.id]
                case .outcome(let outcome): return outcome
            }
        }
        var reminders = try await store.reminders(listIDs: listIDs,
                                                  includeCompleted: arguments.bool("include_completed") ?? false)
        if let query = arguments.string("query")?.lowercased() {
            let words = query.split(whereSeparator: \.isWhitespace)
            reminders = reminders.filter { reminder in
                let text = "\(reminder.title) \(reminder.notes ?? "")".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        let shown = reminders.prefix(Self.maximumReminders)
        var result: [String: JSONValue] = ["reminders": .array(shown.map(Self.json))]
        if reminders.count > shown.count { result["more"] = .number(Double(reminders.count - shown.count)) }
        return .confirmed("\(reminders.count) reminders.", .object(result))
    }

    private func create(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        var listID: String?
        if let wanted = arguments.string("list") {
            switch CalendarAdapter.pick(wanted, in: try await store.calendars(of: .reminders), kind: "list") {
                case .found(let list):
                    guard list.isWritable else { return .refused("The list \(list.title) cannot be changed.") }
                    listID = list.id
                case .outcome(let outcome):
                    return outcome
            }
        }
        let draft = StoreReminderDraft(title: try arguments.required("title"), listID: listID,
                                       due: try arguments.date("due"), notes: arguments.string("notes"))
        let id: String
        do {
            id = try await store.createReminder(draft)
        } catch {
            return .mayHaveHappened("The store was asked to create \(draft.title)", because: error,
                                    look: "Find the reminder", result: .object(["title": .string(draft.title)]))
        }
        let created: JSONValue = .object(["id": .string(id)])
        return await .afterChange("The store took the reminder", look: "Read the reminder by its id", result: created) {
            guard let saved = try await store.reminder(id: id) else {
                return AdapterOutcome(.actedUnverified, "The store took the reminder, but it does not read back.",
                                      result: created)
            }
            // The reminder as asked for: its fields, and the list asked for, which fixes its account (A07).
            var other: [String] = []
            if saved.title != draft.title { other.append("title") }
            if let due = draft.due, saved.due.map({ abs($0.timeIntervalSince(due)) < 1 }) != true {
                other.append("due date")
            }
            if let notes = draft.notes, saved.notes != notes { other.append("notes") }
            if let listID, saved.listID != listID {
                let lists = try await store.calendars(of: .reminders)
                let landed = lists.first { $0.id == saved.listID }
                other.append("list: it is in \(landed.map { "\($0.title) (\($0.account))" } ?? saved.listID), "
                             + "not the one asked for")
            }
            guard other.isEmpty else {
                return AdapterOutcome(.actedUnverified, "The store took the reminder, but it reads back with another "
                                      + other.joined(separator: ", ") + ". Find it before creating it again.",
                                      result: Self.json(saved))
            }
            return .confirmed("Created \(saved.title).", Self.json(saved))
        }
    }

    private func complete(id: String) async throws -> AdapterOutcome {
        guard let before = try await store.reminder(id: id) else { return .missing("No reminder \(id).") }
        if before.isCompleted {
            return AdapterOutcome(.actedNoop, "\(before.title) was already done.", result: Self.json(before))
        }
        let noted = Self.json(before)
        do {
            try await store.completeReminder(id: id)
        } catch {
            return .mayHaveHappened("The store was asked to complete \(before.title)", because: error,
                                    look: "Read the reminder by its id", result: noted)
        }
        return await .afterChange("The store took the completion", look: "Read the reminder by its id", result: noted) {
            guard let after = try await store.reminder(id: id), after.isCompleted else {
                return AdapterOutcome(.actedUnverified, "The reminder did not read back as done.", result: noted)
            }
            return .confirmed("Done: \(after.title).", Self.json(after))
        }
    }

    static func json(_ reminder: StoreReminder) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(reminder.id), "title": .string(reminder.title), "list": .string(reminder.listID),
            "completed": .bool(reminder.isCompleted),
        ]
        if let due = reminder.due { object["due"] = .string(AdapterArguments.text(due)) }
        if let notes = reminder.notes, !notes.isEmpty { object["notes"] = .string(notes) }
        return .object(object)
    }
}
