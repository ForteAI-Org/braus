import Foundation

/// EventStoring is the Mac's calendar and reminder store as the Calendar and Reminders adapters reach
/// it. The live one is `EventKitStore`; tests use an in-memory fake. Every record is a copy: a later
/// change to the store does not change a record already returned.
extension EventStoring {
    public func requestAccess(to kind: EventStoreKind) async -> EventStoreAccess { access(to: kind) }
}

public protocol EventStoring: Sendable {
    func access(to kind: EventStoreKind) -> EventStoreAccess
    /// Asks for full access, prompting when the person has not answered yet.
    func requestAccess(to kind: EventStoreKind) async -> EventStoreAccess
    func calendars(of kind: EventStoreKind) async throws -> [StoreCalendar]

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [StoreEvent]
    func event(id: String) async throws -> StoreEvent?
    /// Saves a new event and answers its identifier.
    func createEvent(_ draft: StoreEventDraft) async throws -> String
    func updateEvent(id: String, _ changes: StoreEventChanges) async throws
    func deleteEvent(id: String) async throws

    func reminders(listIDs: [String]?, includeCompleted: Bool) async throws -> [StoreReminder]
    func reminder(id: String) async throws -> StoreReminder?
    func createReminder(_ draft: StoreReminderDraft) async throws -> String
    func completeReminder(id: String) async throws
}

public enum EventStoreKind: String, Sendable, Equatable {
    case events, reminders
}

public enum EventStoreAccess: Sendable, Equatable {
    case granted, notDetermined, denied
}

/// StoreCalendar is one calendar or one reminder list.
public struct StoreCalendar: Sendable, Equatable {
    public let id        : String
    public let title     : String
    public let account   : String
    public let isWritable: Bool
    public let isDefault : Bool

    public init(id: String, title: String, account: String, isWritable: Bool, isDefault: Bool) {
        self.id         = id
        self.title      = title
        self.account    = account
        self.isWritable = isWritable
        self.isDefault  = isDefault
    }
}

public struct StoreEvent: Sendable, Equatable {
    public var id          : String
    public var title       : String
    public var start       : Date
    public var end         : Date
    public var isAllDay    : Bool
    public var calendarID  : String
    public var location    : String?
    public var notes       : String?
    public var isRecurring : Bool

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String,
                location: String? = nil, notes: String? = nil, isRecurring: Bool = false) {
        self.id          = id
        self.title       = title
        self.start       = start
        self.end         = end
        self.isAllDay    = isAllDay
        self.calendarID  = calendarID
        self.location    = location
        self.notes       = notes
        self.isRecurring = isRecurring
    }
}

/// StoreEventDraft is a new event; a nil calendar is the store's default calendar for new events.
public struct StoreEventDraft: Sendable, Equatable {
    public let title     : String
    public let start     : Date
    public let end       : Date
    public let isAllDay  : Bool
    public let calendarID: String?
    public let location  : String?
    public let notes     : String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String?,
                location: String?, notes: String?) {
        self.title      = title
        self.start      = start
        self.end        = end
        self.isAllDay   = isAllDay
        self.calendarID = calendarID
        self.location   = location
        self.notes      = notes
    }
}

/// StoreEventChanges lists only what changes; a nil field keeps its value.
public struct StoreEventChanges: Sendable, Equatable {
    public var title   : String?
    public var start   : Date?
    public var end     : Date?
    public var location: String?
    public var notes   : String?

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, location: String? = nil,
                notes: String? = nil) {
        self.title    = title
        self.start    = start
        self.end      = end
        self.location = location
        self.notes    = notes
    }

    public var isEmpty: Bool { self == StoreEventChanges() }
}

public struct StoreReminder: Sendable, Equatable {
    public var id         : String
    public var title      : String
    public var listID     : String
    public var due        : Date?
    public var isCompleted: Bool
    public var notes      : String?

    public init(id: String, title: String, listID: String, due: Date? = nil, isCompleted: Bool = false,
                notes: String? = nil) {
        self.id          = id
        self.title       = title
        self.listID      = listID
        self.due         = due
        self.isCompleted = isCompleted
        self.notes       = notes
    }
}

/// StoreReminderDraft is a new reminder; a nil list is the store's default list.
public struct StoreReminderDraft: Sendable, Equatable {
    public let title : String
    public let listID: String?
    public let due   : Date?
    public let notes : String?

    public init(title: String, listID: String?, due: Date?, notes: String?) {
        self.title  = title
        self.listID = listID
        self.due    = due
        self.notes  = notes
    }
}
