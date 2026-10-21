import Foundation

/// MacFocusGuard keeps the person's front app in front across a background operation: it notes the
/// front app before, and afterwards, when the operation's app took the front by itself and the person
/// has not used the keyboard or mouse since, it brings their app back.
///
/// Begin it right before the operation and settle it once the operation's window is there; it holds
/// no resource in between.
public struct MacFocusGuard: Sendable {

    /// What happened to the front app.
    public struct Outcome: Sendable, Equatable {
        /// The operation's app came to the front although it was opened without activation.
        public var selfActivated: Bool
        /// The person's app is in front again.
        public var focusRestored: Bool
        /// The person typed or clicked meanwhile, so their focus was left as they set it.
        public var personActed: Bool
        /// Seconds since `begin`.
        public var elapsed: Double

        /// The window came in front of the person's and could not be sent back, with no input from the
        /// person to explain it: the current Driver adopts it on the seat (mode 1).
        public var leftInFront: Bool {
            MacFocusGuard.leavesInFront(selfActivated: selfActivated, focusRestored: focusRestored, personActed: personActed)
        }
    }

    /// Whether an operation left its app in front of the person's: it activated itself, the person's
    /// app did not come back, and the person did not act meanwhile (then the front is theirs).
    public static func leavesInFront(selfActivated: Bool, focusRestored: Bool, personActed: Bool) -> Bool {
        selfActivated && !focusRestored && !personActed
    }

    let workspace: any MacWorkspace
    let front: MacRunningApp?
    let started: ContinuousClock.Instant

    public static func begin(_ workspace: any MacWorkspace) async -> MacFocusGuard {
        MacFocusGuard(workspace: workspace, front: await workspace.frontmost(), started: ContinuousClock.now)
    }

    /// Seconds since `begin`.
    public var elapsed: Double {
        let duration = ContinuousClock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Activation takes effect a moment after the call: the front is read again every 50 ms for up to
    /// `restoreWait` (GridCraft read as "could not be sent back" while it was coming back, 15 Oct).
    public static let restoreWait = Duration.milliseconds(500)

    private func cameBack(_ processID: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.restoreWait)
        while true {
            if await workspace.frontmost()?.processID == processID { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Checks the front app against `processID`, the operation's app, and restores the person's unless
    /// `restoring` is false (a dialog the app came forward to show). An app that was already in front
    /// before `begin` never counts as self-activated.
    public func settle(after processID: pid_t, restoring: Bool = true) async -> Outcome {
        let elapsed = self.elapsed
        let nowFront = await workspace.frontmost()
        let selfActivated = nowFront?.processID == processID && front.map { $0.processID != processID } ?? false
        let personActed = workspace.secondsSincePersonInput() < elapsed
        var restored = false
        if restoring, selfActivated, !personActed, let front {
            await workspace.activate(front.processID)
            restored = await cameBack(front.processID)
        }
        return Outcome(selfActivated: selfActivated, focusRestored: restored, personActed: personActed, elapsed: elapsed)
    }
}
