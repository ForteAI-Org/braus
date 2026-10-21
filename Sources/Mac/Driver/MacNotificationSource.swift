import ApplicationServices
import Foundation
import Synchronization

/// MacNotificationSource tells when a process last posted an accessibility notification that says its
/// window changed: a value, the focus, a selection, an element or a window created or destroyed, a
/// sheet, a menu, the layout. Notifications end a wait; they never decide an outcome.
public protocol MacNotificationSource: Sendable {

    /// Starts listening to the process, if it is not listened to already. Never prompts.
    func watch(_ processID: pid_t)

    /// The moment of the last notification from the process, nil before the first.
    func lastNotification(of processID: pid_t) -> ContinuousClock.Instant?
}

/// LiveMacNotificationSource keeps one `AXObserver` per process on its own thread's run loop, so a
/// notification is noted while the caller waits, and nothing runs on the main thread.
///
/// `@unchecked Sendable`: the observers are CF objects; they are only stored and read under `lock`,
/// and only the listening thread's run loop calls them back.
public final class LiveMacNotificationSource: MacNotificationSource, @unchecked Sendable {

    static let notifications: [String] = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification, kAXSelectedTextChangedNotification, kAXCreatedNotification,
        kAXUIElementDestroyedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXLayoutChangedNotification, kAXTitleChangedNotification,
        kAXRowCountChangedNotification, kAXRowExpandedNotification, kAXRowCollapsedNotification,
    ]

    /// Last notification per process; the observer callback writes it from the listening thread.
    final class Ledger: Sendable {
        let instants = Mutex<[pid_t: ContinuousClock.Instant]>([:])
    }

    private let ledger = Ledger()
    private let lock = NSLock()
    private var observers: [pid_t: AXObserver] = [:]
    private let loop: RunLoopThread

    public init() {
        loop = RunLoopThread(name: "braus.mac.notifications")
    }

    public func watch(_ processID: pid_t) {
        guard lock.withLock({ observers[processID] }) == nil, AXIsProcessTrusted() else { return }
        var created: AXObserver?
        let callback: AXObserverCallbackWithInfo = { _, _, _, _, context in
            guard let context else { return }
            let box = Unmanaged<ProcessBox>.fromOpaque(context).takeUnretainedValue()
            box.ledger.instants.withLock { $0[box.processID] = ContinuousClock.now }
        }
        guard AXObserverCreateWithInfoCallback(processID, callback, &created) == .success, let observer = created else { return }
        let box = Unmanaged.passRetained(ProcessBox(processID: processID, ledger: ledger))
        let application = AXUIElementCreateApplication(processID)
        for name in Self.notifications {
            _ = AXObserverAddNotification(observer, application, name as CFString, box.toOpaque())
        }
        lock.withLock { observers[processID] = observer }
        loop.add(AXObserverGetRunLoopSource(observer))
    }

    public func lastNotification(of processID: pid_t) -> ContinuousClock.Instant? {
        ledger.instants.withLock { $0[processID] }
    }

    /// The callback's context: which process, and where to note it. Retained for the observer's life,
    /// which is the source's.
    final class ProcessBox: Sendable {
        let processID: pid_t
        let ledger: Ledger

        init(processID: pid_t, ledger: Ledger) {
            self.processID = processID
            self.ledger    = ledger
        }
    }
}

/// RunLoopThread is a thread that only runs its run loop, for sources added from other threads.
///
/// `@unchecked Sendable`: the run loop is written once, before `init` returns, and CF run loops accept
/// sources from any thread.
final class RunLoopThread: @unchecked Sendable {

    private var runLoop: CFRunLoop?

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            // A run loop with no source returns at once; this port keeps it alive.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = name
        thread.start()
        ready.wait()
    }

    func add(_ source: CFRunLoopSource) {
        guard let loop = runLoop else { return }
        CFRunLoopAddSource(loop, source, .defaultMode)
        CFRunLoopWakeUp(loop)
    }
}
