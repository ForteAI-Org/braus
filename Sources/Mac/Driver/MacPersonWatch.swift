import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// MacPersonWatching tells when the person last clicked, typed or scrolled in a process (spec section
/// 3, rule 6: the person comes first). Events Braus posts to a process do not pass a session tap, and
/// accessibility actions are no events, so only the person's own input is seen.
public protocol MacPersonWatching: Sendable {

    /// Whether the watch is running; false without the Input Monitoring permission (never prompted).
    var isWatching: Bool { get }

    /// The moment the person last clicked, typed or scrolled in the process, nil if never seen.
    func lastTouch(of processID: pid_t) -> ContinuousClock.Instant?
}

/// LiveMacPersonWatch is a listen-only event tap on the annotated session stream, on its own run loop
/// thread: mouse downs, key downs and scroll wheels, each noted under the process the window server
/// routed it to (measured 15 Oct: the person's clicks in System Settings noted under its pid). It never
/// posts, never suppresses and holds nothing but the last moment per process.
public final class LiveMacPersonWatch: MacPersonWatching {

    final class Ledger: Sendable {
        let touches = Mutex<[pid_t: ContinuousClock.Instant]>([:])
    }

    private let ledger = Ledger()
    public let isWatching: Bool

    public init() {
        guard CGPreflightListenEventAccess() else {
            isWatching = false
            return
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passRetained(ledger).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let ledger = Unmanaged<Ledger>.fromOpaque(context).takeUnretainedValue()
            // The tap is listen-only: a timeout disables it, and nothing else is to be done here.
            if type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
                let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
                ledger.touches.withLock { $0[target] = ContinuousClock.now }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: context
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            Unmanaged<Ledger>.fromOpaque(context).release()
            isWatching = false
            return
        }
        Self.loop.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        isWatching = true
    }

    public func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? {
        ledger.touches.withLock { $0[processID] }
    }

    /// Every process touched so far with its last moment, for diagnosis.
    public var touches: [pid_t: ContinuousClock.Instant] { ledger.touches.withLock { $0 } }

    /// One listening thread for every watch in the process.
    private static let loop = RunLoopThread(name: "braus.mac.person")
}
