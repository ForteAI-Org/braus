import Foundation
import EngineCore
import MacDriver
import Synchronization

/// MacSettler fills `Settling` with the app's own accessibility notifications (spec section 4): after a
/// gesture it returns 150 ms after the last notification, or at the cap (2 s by the spec, the engine's
/// cap when it is shorter). Nothing within the first 150 ms means "no change", which the engine then
/// confirms by reading. The notifications end the wait; the read-back decides the outcome.
public final class MacSettler: Settling {

    public static let quiet: Duration = .milliseconds(150)
    public static let cap: Duration = .seconds(2)

    public let source: any MacNotificationSource
    public let pollInterval: Duration
    private let starts = Mutex<[pid_t: ContinuousClock.Instant]>([:])

    public init(source: any MacNotificationSource, pollInterval: Duration = .milliseconds(10)) {
        self.source       = source
        self.pollInterval = pollInterval
    }

    public func prepare(in processID: pid_t) async {
        source.watch(processID)
        starts.withLock { $0[processID] = ContinuousClock.now }
    }

    @discardableResult
    public func settle(in processID: pid_t, cap: Duration) async -> SettleResult {
        source.watch(processID)
        let started = starts.withLock { $0.removeValue(forKey: processID) } ?? ContinuousClock.now
        let limit = min(cap, Self.cap)
        while true {
            let now = ContinuousClock.now
            let last = source.lastNotification(of: processID)
            if Self.isSettled(started: started, last: last, now: now, cap: limit) {
                return Self.result(started: started, last: last, now: now, cap: limit)
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// How a settled wait ended: capped when it reached the cap with a notification since `started` less than
    /// `quiet` old, the app still announcing changes; settled otherwise.
    static func result(
        started: ContinuousClock.Instant, last: ContinuousClock.Instant?, now: ContinuousClock.Instant, cap: Duration
    ) -> SettleResult {
        guard now - started >= cap, let last, last >= started, now - last < quiet else { return .settled }
        return .capped
    }

    /// The rule, apart from the clock: settled at the cap; settled when the last notification since
    /// `started` is `quiet` old; settled when none came within `quiet` of `started`.
    static func isSettled(
        started: ContinuousClock.Instant, last: ContinuousClock.Instant?, now: ContinuousClock.Instant, cap: Duration
    ) -> Bool {
        if now - started >= cap { return true }
        guard let last, last >= started else { return now - started >= quiet }
        return now - last >= quiet
    }
}
