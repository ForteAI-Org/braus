import EventKit
import Foundation

/// EventKitStore is `EventStoring` on the Mac's EventKit store: the calendars and reminder lists of
/// every account the Mac syncs, with Calendar and Reminders closed. Only `requestAccess(to:)`, on the
/// person's request, asks for access; otherwise a missing grant is reported by `access(to:)` and the
/// adapters refuse with how to give it.
///
/// The actor owns the `EKEventStore`, which is not sendable; records leave it as copies.
public actor EventKitStore: EventStoring {

    private let store = EKEventStore()

    public init() {}

    public nonisolated func access(to kind: EventStoreKind) -> EventStoreAccess {
        switch EKEventStore.authorizationStatus(for: kind == .events ? .event : .reminder) {
            case .fullAccess   : .granted
            case .notDetermined: .notDetermined
            default            : .denied
        }
    }

    public func requestAccess(to kind: EventStoreKind) async -> EventStoreAccess {
        guard access(to: kind) == .notDetermined else { return access(to: kind) }
        _ = try? await (kind == .events ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
        return access(to: kind)
    }

    public func calendars(of kind: EventStoreKind) async throws -> [StoreCalendar] {
        let type: EKEntityType = kind == .events ? .event : .reminder
        let fallback = kind == .events ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        return store.calendars(for: type).map { calendar in
            StoreCalendar(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                          isWritable: calendar.allowsContentModifications,
                          isDefault: calendar.calendarIdentifier == fallback?.calendarIdentifier)
        }
    }

    // MARK: Events

    public func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [StoreEvent] {
        let calendars = calendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.record)
    }

    public func event(id: String) async throws -> StoreEvent? {
        store.event(withIdentifier: id).map(Self.record)
    }

    public func createEvent(_ draft: StoreEventDraft) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title     = draft.title
        event.startDate = draft.start
        event.endDate   = draft.end
        event.isAllDay  = draft.isAllDay
        event.location  = draft.location
        event.notes     = draft.notes
        event.calendar  = try draft.calendarID.map { try calendar($0, .event) } ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw AdapterFailure("The event was saved without an identifier.") }
        return id
    }

    public func updateEvent(id: String, _ changes: StoreEventChanges) async throws {
        guard let event = store.event(withIdentifier: id) else { throw AdapterFailure("No event \(id).") }
        if let title = changes.title { event.title = title }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        if let location = changes.location { event.location = location }
        if let notes = changes.notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
    }

    public func deleteEvent(id: String) async throws {
        guard let event = store.event(withIdentifier: id) else { throw AdapterFailure("No event \(id).") }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: Reminders

    public func reminders(listIDs: [String]?, includeCompleted: Bool) async throws -> [StoreReminder] {
        let lists = listIDs.map { ids in store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) } }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.record))
            }
        }
    }

    public func reminder(id: String) async throws -> StoreReminder? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.record)
    }

    public func createReminder(_ draft: StoreReminderDraft) async throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = try draft.listID.map { try calendar($0, .reminder) } ?? store.defaultCalendarForNewReminders()
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .timeZone], from: due)
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    public func completeReminder(id: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AdapterFailure("No reminder \(id).")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    // MARK: Records

    private func calendar(_ id: String, _ type: EKEntityType) throws -> EKCalendar {
        guard let calendar = store.calendars(for: type).first(where: { $0.calendarIdentifier == id }) else {
            throw AdapterFailure("No calendar \(id).")
        }
        return calendar
    }

    private static func record(_ event: EKEvent) -> StoreEvent {
        StoreEvent(id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate, end: event.endDate,
                   isAllDay: event.isAllDay, calendarID: event.calendar?.calendarIdentifier ?? "",
                   location: event.location, notes: event.notes, isRecurring: event.hasRecurrenceRules)
    }

    private static func record(_ reminder: EKReminder) -> StoreReminder {
        StoreReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                      listID: reminder.calendar?.calendarIdentifier ?? "",
                      due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                      isCompleted: reminder.isCompleted, notes: reminder.notes)
    }
}
