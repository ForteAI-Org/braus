import ChatCore
import Foundation
import Turn

/// CodexRollout adapts the shared reader to the application's existing internal interface.
nonisolated enum CodexRollout {
    struct Reading: Sendable, Hashable {
        let contextTokens: Int?
        let contextWindow: Int?
        let rateLimits: [ProviderUsage.RateLimit]

        init(_ shared: Turn.CodexRollout.Reading) {
            contextTokens = shared.contextTokens
            contextWindow = shared.contextWindow
            rateLimits = shared.rateLimits
        }
    }

    static func sessions(environment: [String: String]) -> URL {
        Turn.CodexRollout.sessions(environment: environment)
    }

    static func file(of thread: String, in sessions: URL, now: Date = Date(), calendar: Calendar = .current) -> URL? {
        Turn.CodexRollout.file(of: thread, in: sessions, now: now, calendar: calendar)
    }

    static func reading(of file: URL) -> Reading? {
        Turn.CodexRollout.reading(of: file).map(Reading.init)
    }

    static func reading(from lines: Data) -> Reading? {
        Turn.CodexRollout.reading(from: lines).map(Reading.init)
    }

    static func tail(of file: URL) -> Data? { Turn.CodexRollout.tail(of: file) }

    static func compacts(in lines: Data, since start: Date) -> Bool {
        Turn.CodexRollout.compacts(in: lines, since: start)
    }
}
