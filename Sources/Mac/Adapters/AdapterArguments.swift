import Foundation
import LocalMCP

/// AdapterArguments reads a verb's arguments after `AppAdapters` checked them against the verb's
/// schema, so a type is already right; it still refuses a date it cannot read.
struct AdapterArguments {

    let values: [String: JSONValue]

    init(_ arguments: JSONValue) {
        values = arguments.object ?? [:]
    }

    func string(_ name: String) -> String? {
        values[name]?.string
    }

    func required(_ name: String) throws -> String {
        guard let value = string(name) else { throw AdapterFailure("\(name) is missing.") }
        return value
    }

    func number(_ name: String) -> Double? {
        if case .number(let value)? = values[name] { return value }
        return nil
    }

    func bool(_ name: String) -> Bool? {
        values[name]?.bool
    }

    /// A date in ISO 8601: a full instant with its offset (`2026-10-15T09:30:00+02:00`), or a day
    /// alone (`2026-10-15`), which is that day's start in the Mac's time zone.
    func date(_ name: String) throws -> Date? {
        guard let text = string(name) else { return nil }
        guard let date = Self.date(from: text) else {
            throw AdapterFailure("\(name) is not an ISO 8601 date such as 2026-10-15T09:30:00+02:00 or 2026-10-15.")
        }
        return date
    }

    func requiredDate(_ name: String) throws -> Date {
        guard let date = try date(name) else { throw AdapterFailure("\(name) is missing.") }
        return date
    }

    static func date(from text: String) -> Date? {
        let instant = ISO8601DateFormatter()
        if let date = instant.date(from: text) { return date }
        instant.formatOptions.insert(.withFractionalSeconds)
        if let date = instant.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: text)
    }

    /// A date as the adapters answer it: ISO 8601 with the Mac's offset.
    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
