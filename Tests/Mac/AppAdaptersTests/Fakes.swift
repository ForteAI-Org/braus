import AppAdapters
import Foundation

/// FakeApprover answers every consent as the person would: allowing it, refusing it, or leaving it until the waiting
/// task is cancelled, which answers no as the app's approvals do. It keeps what it was asked.
actor FakeApprover: AdapterApproving {

    enum Answer {
        case allow, refuse, waitUntilCancelled
    }

    private let answer: Answer
    private(set) var asked: [AdapterConsent] = []

    init(_ answer: Answer) {
        self.answer = answer
    }

    func approve(_ consent: AdapterConsent) async -> Bool {
        asked.append(consent)
        switch answer {
            case .allow:
                return true
            case .refuse:
                return false
            case .waitUntilCancelled:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return false
        }
    }
}

/// FakeSystemTransport keeps the settings in memory; `ignoresWrites` plays a Mac that accepts a change
/// and does not apply it, and `permissionNeeded` one that would prompt.
actor FakeSystemTransport: SystemTransporting {

    var current         = SystemAppearance.light
    var level           = 40
    var muted: Bool?    = false
    var wifi: Bool?     = true
    var ignoresWrites   = false
    var permissionNeeded = false
    private(set) var writes = 0
    /// How many times the person was asked for System Events, and what they answer.
    private(set) var accessRequests = 0
    var grantsWhenAsked = true

    init(ignoresWrites: Bool = false, permissionNeeded: Bool = false, muted: Bool? = false, wifi: Bool? = true) {
        self.ignoresWrites    = ignoresWrites
        self.permissionNeeded = permissionNeeded
        self.muted            = muted
        self.wifi             = wifi
    }

    func appearance() async throws -> SystemAppearance { current }

    func setAppearance(dark: Bool) async throws {
        if permissionNeeded { throw SystemPermissionNeeded("Allow Automation.") }
        writes += 1
        if !ignoresWrites { current = dark ? .dark : .light }
    }

    func volume() async throws -> SystemVolume { SystemVolume(level: level, isMuted: muted) }

    func setVolume(level: Int?, muted: Bool?) async throws {
        writes += 1
        guard !ignoresWrites else { return }
        if let level { self.level = level }
        if let muted { self.muted = muted }
    }

    func wifiPower() async throws -> Bool? { wifi }

    func setWifiPower(_ isOn: Bool) async throws {
        writes += 1
        if !ignoresWrites { wifi = isOn }
    }

    /// Whether System Events runs: the grant reads as unknown until it does, as on the Mac.
    var systemEventsRuns = true
    private(set) var starts = 0

    func appearanceAccess() async -> AdapterAvailability {
        guard systemEventsRuns else { return .unknown("System Events is not running.") }
        return permissionNeeded ? .needsPermission("Allow Automation.") : .ready
    }

    func startSystemEvents() async throws {
        starts += 1
        systemEventsRuns = true
    }

    func stopSystemEvents() { systemEventsRuns = false }

    func requestAppearanceAccess() async -> AdapterAvailability {
        accessRequests += 1
        if grantsWhenAsked { permissionNeeded = false }
        return await appearanceAccess()
    }
}

/// FakeEventStore is an in-memory calendar and reminder store with two calendars and two lists. A test can
/// make it file a new record elsewhere than asked (`misfile`), drop the notes it is given, fail its reads once
/// something was written (`failReads`), fail a write after applying it (`failWrites`), or take its time to
/// read once something was written (`slowReads`).
actor FakeEventStore: EventStoring {

    nonisolated let grants: [EventStoreKind: EventStoreAccess]
    var calendars: [StoreCalendar] = [
        StoreCalendar(id: "home", title: "Home", account: "iCloud", isWritable: true, isDefault: true),
        StoreCalendar(id: "work", title: "Work", account: "Google", isWritable: true, isDefault: false),
        StoreCalendar(id: "holidays", title: "Holidays", account: "Subscribed", isWritable: false, isDefault: false),
    ]
    var lists: [StoreCalendar] = [
        StoreCalendar(id: "inbox", title: "Reminders", account: "iCloud", isWritable: true, isDefault: true),
        StoreCalendar(id: "shop", title: "Shopping", account: "iCloud", isWritable: true, isDefault: false),
    ]
    var events: [StoreEvent] = []
    var reminders: [StoreReminder] = []
    /// When set, deletes and saves are accepted and not applied.
    var dropsWrites = false
    private var next = 0
    private(set) var writes = 0
    private var misfiledInto: String?
    private var dropsNotes = false
    private var readFailure: (any Error & Sendable)?
    private var writeFailure: (any Error & Sendable)?
    private var readDelay: Duration?
    private var flipsAllDay = false
    private var shiftedDays = 0

    /// New events are saved timed when asked all-day, and all-day when asked timed.
    func flipAllDay() { flipsAllDay = true }
    /// New events are saved `days` later than asked.
    func shiftDays(by days: Int) { shiftedDays = days }

    /// New events and reminders go to calendar or list `id`, whatever they asked for.
    func misfile(into id: String) { misfiledInto = id }
    func dropNotes() { dropsNotes = true }
    func failReads(afterWrite error: any Error & Sendable) { readFailure = error }
    func failWrites(with error: any Error & Sendable) { writeFailure = error }
    func slowReads(_ delay: Duration) { readDelay = delay }

    /// What a read does once something was written: wait, then fail, as the test asked.
    private func afterWrite() async throws {
        guard writes > 0 else { return }
        if let readDelay { try await Task.sleep(for: readDelay) }
        if let readFailure { throw readFailure }
    }

    /// What a write does once applied: fail, as the test asked.
    private func written() throws {
        writes += 1
        if let writeFailure { throw writeFailure }
    }

    init(grants: [EventStoreKind: EventStoreAccess] = [.events: .granted, .reminders: .granted]) {
        self.grants = grants
    }

    func add(_ event: StoreEvent) { events.append(event) }
    func add(_ reminder: StoreReminder) { reminders.append(reminder) }
    func addCalendar(_ calendar: StoreCalendar) { calendars.append(calendar) }
    func dropWrites() { dropsWrites = true }

    nonisolated func access(to kind: EventStoreKind) -> EventStoreAccess { grants[kind] ?? .denied }

    func calendars(of kind: EventStoreKind) async throws -> [StoreCalendar] {
        try await afterWrite()
        return kind == .events ? calendars : lists
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) async throws -> [StoreEvent] {
        events.filter { $0.start < end && $0.end > start && (calendarIDs?.contains($0.calendarID) ?? true) }
    }

    func event(id: String) async throws -> StoreEvent? {
        try await afterWrite()
        return events.first { $0.id == id }
    }

    func createEvent(_ draft: StoreEventDraft) async throws -> String {
        next += 1
        let id = "event-\(next)"
        guard !dropsWrites else { return id }
        let shift = TimeInterval(shiftedDays * 24 * 3600)
        events.append(StoreEvent(id: id, title: draft.title, start: draft.start + shift, end: draft.end + shift,
                                 isAllDay: flipsAllDay ? !draft.isAllDay : draft.isAllDay,
                                 calendarID: misfiledInto ?? draft.calendarID ?? "home", location: draft.location,
                                 notes: dropsNotes ? nil : draft.notes))
        try written()
        return id
    }

    func updateEvent(id: String, _ changes: StoreEventChanges) async throws {
        guard !dropsWrites, let index = events.firstIndex(where: { $0.id == id }) else { return }
        if let title = changes.title { events[index].title = title }
        if let start = changes.start { events[index].start = start }
        if let end = changes.end { events[index].end = end }
        if let location = changes.location { events[index].location = location }
        if let notes = changes.notes { events[index].notes = notes }
        try written()
    }

    func deleteEvent(id: String) async throws {
        guard !dropsWrites else { return }
        events.removeAll { $0.id == id }
        try written()
    }

    func reminders(listIDs: [String]?, includeCompleted: Bool) async throws -> [StoreReminder] {
        reminders.filter { (listIDs?.contains($0.listID) ?? true) && (includeCompleted || !$0.isCompleted) }
    }

    func reminder(id: String) async throws -> StoreReminder? {
        try await afterWrite()
        return reminders.first { $0.id == id }
    }

    func createReminder(_ draft: StoreReminderDraft) async throws -> String {
        next += 1
        let id = "reminder-\(next)"
        guard !dropsWrites else { return id }
        reminders.append(StoreReminder(id: id, title: draft.title, listID: misfiledInto ?? draft.listID ?? "inbox",
                                       due: draft.due, notes: dropsNotes ? nil : draft.notes))
        try written()
        return id
    }

    func completeReminder(id: String) async throws {
        guard !dropsWrites, let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isCompleted = true
        try written()
    }
}
