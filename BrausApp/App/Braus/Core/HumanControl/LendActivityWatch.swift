//
//  LendActivityWatch.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import AppKit
import ApplicationServices
import OSLog
import SeatBroker

/// LendActivityWatch runs the activity policy (`LendActivity`) while an application is lent: the passive
/// listener's events reach it through the human control, the lent windows and menus through the
/// companion, and the screen's lock, the Mac's sleep and the application's quit from the workspace.
/// Per event it only updates the model; one task wakes at the model's deadline, so a still Mac costs no
/// wakeups. While a question is open it also watches key presses: the listener reports typing only once
/// it pauses, and a person typing into the application must not lose it to the countdown. Decisions go
/// to `decided`, with the reason. Times come from `now`, a clock that keeps counting while the Mac sleeps.
@MainActor
final class LendActivityWatch {

    private var model    : LendActivity
    private let processID: pid_t
    private let now      : () -> Double
    private let decided  : (LendActivity.Decision, String) -> Void

    /// The task that wakes at the model's deadline, and that deadline.
    private var timer: Task<Void, Never>?
    private var armed: Double?

    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var keys     : Any?
    private var census   : Task<Void, Never>?
    private var logged   : LendActivity.State
    private var isStopped = false

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    /// Watches the lent application of `processID`, held until `landed()`.
    init(
        processID: pid_t,
        now      : (() -> Double)? = nil,
        decided  : @escaping (LendActivity.Decision, String) -> Void
    ) {
        let origin = ContinuousClock.now
        let now    = now ?? { (ContinuousClock.now - origin) / .seconds(1) }
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        self.processID = processID
        self.now       = now
        self.decided   = decided
        model  = LendActivity(
            at         : now(),
            lentInFront: inFront
        )
        logged = model.state
        observe()
        Self.log.notice("take-back: watching the lent application \(processID, privacy: .public), \(self.logged.rawValue, privacy: .public)")
    }

    /// The lend landed: questions may come from now on.
    func landed() {
        guard !isStopped else { return }
        apply(model.release(at: now()))
    }

    /// Evidence that ended `age` seconds ago.
    func receive(
        _ evidence: LendActivity.Evidence,
        age       : Double = 0
    ) {
        guard !isStopped else { return }
        apply(model.receive(
            evidence,
            at: now() - age
        ))
    }

    /// How the question ended.
    func answered(_ answer: TakeBackAnswer) {
        unwatchKeys()
        guard !isStopped else { return }
        let mapped: LendActivity.Answer = switch answer {
        case .yes    : .yes
        case .no     : .no
        case .timeout: .timeout
        }
        let decision = model.answered(
            mapped,
            at: now()
        )
        Self.log.notice("take-back: answered \(String(describing: answer), privacy: .public); next question after \(LendActivity.spoken(self.model.delay(of: .elsewhere)), privacy: .public) elsewhere, \(LendActivity.spoken(self.model.delay(of: .away)), privacy: .public) away")
        apply(decision)
    }

    /// A window of the lent application opened, closed, was minimized or restored, or the application
    /// was hidden or shown: what remains is read off the main thread.
    func windowsChanged() {
        guard !isStopped else { return }
        census?.cancel()
        let processID = processID
        let hidden    = NSRunningApplication(processIdentifier: processID)?.isHidden == true
        census = Task { [weak self] in
            var presence = LendActivity.Presence.tucked
            if !hidden {
                guard let read = await Self.presence(of: processID) else { return }
                presence = read
            }
            guard !Task.isCancelled, let self else { return }
            receive(.windows(presence))
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        timer?.cancel()
        census?.cancel()
        unwatchKeys()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        Self.log.notice("take-back: stopped, \(self.logged.rawValue, privacy: .public)")
    }

    // MARK: Model

    private func apply(_ decision: LendActivity.Decision?) {
        if model.state != logged {
            Self.log.notice("take-back: \(self.logged.rawValue, privacy: .public) to \(self.model.state.rawValue, privacy: .public)")
            logged = model.state
        }
        if let decision {
            switch decision {
            case .ask(let trigger):
                Self.log.notice("take-back: asking Are you done? (\(trigger.rawValue, privacy: .public)): \(self.model.reason, privacy: .public)")
                watchKeys()
            case .withdraw:
                Self.log.notice("take-back: input reached the lent application; the question closes as No")
            case .takeBack(let trigger):
                Self.log.notice("take-back: taking the application back (\(trigger.rawValue, privacy: .public)): \(self.model.reason, privacy: .public)")
            }
            decided(
                decision,
                model.reason
            )
        }
        arm()
    }

    /// Wakes once at the model's deadline. A deadline that moved later keeps the earlier wake, which
    /// finds nothing due and wakes again at the new one.
    private func arm() {
        guard !isStopped, let deadline = model.deadline else {
            timer?.cancel()
            timer = nil
            armed = nil
            return
        }
        if let armed, armed <= deadline { return }
        timer?.cancel()
        armed = deadline
        let delay = max(
            0,
            deadline - now()
        )
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            timer = nil
            armed = nil
            apply(model.tick(at: now()))
        }
    }

    // MARK: Sources

    private func observe() {
        let workspace   = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let processID   = processID
        add(
            workspace,
            NSWorkspace.didTerminateApplicationNotification
        ) { [weak self] note in
            let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if quit == processID { self?.receive(.quit) }
            }
        }
        let evidence: [(NotificationCenter, Notification.Name, LendActivity.Evidence)] = [
            (workspace, NSWorkspace.willSleepNotification, .asleep(true)),
            (workspace, NSWorkspace.didWakeNotification, .asleep(false)),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked(true)),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked(false)),
        ]
        for (center, name, said) in evidence {
            add(
                center,
                name
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(said) }
            }
        }
    }

    private func add(
        _ center: NotificationCenter,
        _ name  : Notification.Name,
        _ block : @escaping @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(
            forName: name,
            object : nil,
            queue  : .main,
            using  : block
        )
        observers.append((center, token))
    }

    /// Key presses while a question is open: those reaching the lent application in front withdraw it.
    private func watchKeys() {
        guard keys == nil else { return }
        let processID = processID
        keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
                self?.receive(.input(.lent))
            }
        }
    }

    private func unwatchKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    /// The longest one accessibility read of the census waits for a busy application, in seconds.
    nonisolated private static let censusReadLimit: Float = 0.25

    /// What remains of the application's windows: none, all minimized, or some shown. Nil when they cannot
    /// be read, which is no evidence. Accessibility lists only the current Space's windows.
    @concurrent nonisolated private static func presence(of processID: pid_t) async -> LendActivity.Presence? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(
            application,
            censusReadLimit
        )
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let windows = value as? [AXUIElement] else { return nil }
        if windows.isEmpty { return .closed }
        let minimized = windows.allSatisfy { window in
            var flag: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &flag
            ) == .success && flag as? Bool == true
        }
        return minimized ? .tucked : .shown
    }
}
