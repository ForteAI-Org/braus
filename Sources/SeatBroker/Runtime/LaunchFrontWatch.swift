import AppKit
import CoreGraphics

/// LaunchFrontWatch watches who holds the front while the broker starts an application, or asks a
/// running one for a window, and asks for the person's window back each time that application
/// takes it.
///
/// Read once per 300 ms reading of a launch, an application that activated itself showed on the
/// person's screen for up to that long; read every 5 ms, the flash measured 15 to 42 ms (Phone from
/// 858 to 20 ms, calibre from 179 to 25 ms, 15/10/2026). Two readings say who holds the front: the
/// owner of the frontmost ordinary window, for an application that puts a window above the
/// person's without activating (Figma), and the active application, for one that activates before
/// its window exists (Phone, 0.8 s early). A window above the person's counts only while the active
/// application is the launched one or the person's: an application the person chose meanwhile is
/// left in front.
///
/// The readings run off the main actor and the restore on it, where the front is read again first:
/// the main actor can be busy long enough for the front to change. Each restore is awaited, so a
/// burst of readings never queues a second one. One taking of the front is given back once: the
/// next restore waits until a reading shows the front released, or until `settle` has passed with
/// the application still holding it. The watch ends after `limit` restores, or once its task is
/// cancelled, and a cancelled watch restores nothing more.
enum LaunchFrontWatch {

    /// Who holds the front at one instant.
    struct Reading: Sendable, Equatable {

        /// The owner of the frontmost ordinary on-screen window: layer 0, not transparent.
        let windowOwner: pid_t?

        /// The active application.
        let activeApplication: pid_t?
    }

    /// The reading that showed the application holding the front.
    enum Signal: String, Sendable {
        case window
        case activation
    }

    /// One time the application was seen holding the front, and how long after the watch began.
    struct Taking: Sendable, Equatable {
        let processID: pid_t
        let signal   : Signal
        let elapsed  : Duration
    }

    static let interval: Duration = .milliseconds(5)

    /// How long a restore that did not release the front waits before it is asked again. The flash
    /// with a 5 ms watch measured 42 ms at most, so a front still held after this was taken again.
    static let settle: Duration = .milliseconds(100)

    /// Reads with `read` every `interval` until cancelled or `limit` restores were asked, and calls
    /// `restore` on the main actor when `isLaunched` names who holds the front and the reading taken
    /// there agrees. `person` is the process of the person's window. `isLaunched` is asked once per
    /// process off the main actor, and again on it for the confirming reading.
    @concurrent
    static func run(
        person    : pid_t,
        limit     : Int      = LaunchFocusComeback.restoreLimit,
        interval  : Duration = LaunchFrontWatch.interval,
        settle    : Duration = LaunchFrontWatch.settle,
        read      : @Sendable () -> Reading,
        isLaunched: @Sendable (pid_t) -> Bool,
        restore   : @MainActor @Sendable (Taking) -> Void
    ) async {
        let clock   = ContinuousClock()
        let started = clock.now
        var known   : [pid_t: Bool] = [:]
        var restores = 0
        var lastRestore: ContinuousClock.Instant?
        while restores < limit, !Task.isCancelled {
            let seen = taking(in: read(), person: person) { pid in
                if let answer = known[pid] { return answer }
                let answer = isLaunched(pid)
                known[pid] = answer
                return answer
            }
            if seen == nil {
                lastRestore = nil
            } else if lastRestore.map({ clock.now - $0 >= settle }) ?? true {
                let restored = await MainActor.run { () -> Bool in
                    guard !Task.isCancelled,
                          let still = taking(in: read(), person: person, isLaunched: isLaunched)
                    else { return false }
                    restore(Taking(processID: still.processID, signal: still.signal, elapsed: clock.now - started))
                    return true
                }
                if restored {
                    restores += 1
                    lastRestore = clock.now
                }
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// The process `reading` shows holding the front and the signal that shows it, or nil when no
    /// process `isLaunched` names holds it. Its window counts while the active application is it
    /// or `person`'s, its activation always.
    static func taking(
        in reading: Reading,
        person    : pid_t,
        isLaunched: (pid_t) -> Bool
    ) -> (processID: pid_t, signal: Signal)? {
        let active = reading.activeApplication
        let activeIsLaunched = active.map(isLaunched) ?? false
        if let owner = reading.windowOwner, isLaunched(owner), activeIsLaunched || active == person {
            return (owner, .window)
        }
        guard activeIsLaunched, let active else { return nil }
        return (active, .activation)
    }

    /// The front as the window server and the workspace report it now. Callable off the main actor:
    /// the active application is the workspace's last report of it.
    static func liveReading() -> Reading {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Reading(
            windowOwner      : frontWindowOwner(in: list),
            activeApplication: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    /// The owner of the first window of `list`, front to back, at layer 0 and not transparent.
    static func frontWindowOwner(in list: [[String: Any]]) -> pid_t? {
        let front = list.first { info in
            info[kCGWindowLayer as String] as? Int == 0 && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        return front?[kCGWindowOwnerPID as String] as? pid_t
    }
}
