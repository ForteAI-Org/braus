import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os
import Synchronization

/// PassiveInteractionListener owns a listen-only tap on a dedicated run-loop thread, the only producer
/// of a preallocated record queue. It never posts or suppresses input. The callback reads event fields,
/// hit-tests an in-memory window snapshot and writes a fixed-width record; it lists no windows, resolves
/// no titles and takes no lock another thread holds for more than a copy or a swap. A consumer thread
/// drains the queue, resolves titles and yields `events`; a refresher thread lists windows only when the
/// pointer enters another surface, after clicks, a drag's end, focus changes and stale attributions. Pressure degrades into
/// counted coalescing and gap events instead of failing the stream; tap loss still fails it explicitly.
/// Call stop() and await it before releasing the owner; cancellation uses the same joined teardown.
/// No perception runs inside a callback.
@MainActor
public final class PassiveInteractionListener {
    public let events: AsyncThrowingStream<InteractionEvent, any Error>
    package nonisolated let buttons: InteractionButtonState
    private let context: TapContext
    private var activation: (any NSObjectProtocol)?
    private var isStopped = false

    public init(hover: Bool = true) throws {
        guard CGPreflightListenEventAccess() else { throw ListenerFailure.inputMonitoringDenied }
        // ponytail: an unbounded hop, so a stalled stream reader grows this buffer instead of degrading
        // the queue; bound it if a slow reader must shed input rather than memory.
        let pair = AsyncThrowingStream<InteractionEvent, any Error>.makeStream(bufferingPolicy: .unbounded)
        events = pair.stream
        let buttons = InteractionButtonState { CGEventSource.buttonState(.combinedSessionState, button: .left) }
        self.buttons = buttons
        context = TapContext(buttons: buttons, continuation: pair.continuation, hover: hover, excludedPID: getpid())
        let owner = context
        pair.continuation.onTermination = { _ in owner.requestStop() }
        let refresher = Thread { owner.refresh() }
        refresher.qualityOfService = .utility
        refresher.start()
        Thread { owner.consume() }.start()
        Thread { owner.run() }.start()
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            owner.focus(processID: app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { owner.focus(processID: app.processIdentifier) }
    }

    isolated deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        context.requestStop()
    }

    /// A monotonic token that advances on input, including events outside the app filter or lost in a gap.
    /// Tokens support ordering and equality, but their differences never count keystrokes.
    public var revision: UInt64 { context.revision }

    /// Coalescing and loss since start; losses also arrive in `events` as gap events.
    public var queueCounters: InputQueueCounters { context.queue.counters }

    /// The last sequence the tap thread assigned, delivered or inside a gap.
    public var observedSequence: UInt64 { context.queue.observed }

    /// Returns the latest OS-routed pointer surface, once pointer input has been observed.
    /// A moved pointer or a vanished recipient stays unresolved until fresh routing arrives.
    public func windowUnderPointer() -> InteractionWindow? { context.windowUnderPointer() }

    /// Hands `deliver` the tap thread's latency histograms since the last call and resets them, on the tap
    /// thread so they keep one writer. After stop() they are read directly; before start they are empty.
    package nonisolated func takeCallbackLatency(_ deliver: @escaping @Sendable (CallbackLatency) -> Void) {
        context.takeLatency(deliver)
    }

    /// Stops callbacks, flushes pending scroll and typing, finishes the stream and joins the listener's threads.
    public func stop() async {
        if !isStopped {
            isStopped = true
            if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
            activation = nil
            context.requestStop()
        }
        await context.waitUntilFinished()
        buttons.finishListening()
    }
}

/// TapContext confines gesture state to the tap thread, the queue's single producer; focus notifications
/// reach it as run-loop blocks. The gate crosses threads for lifecycle and the ambient route, the refresher
/// holds the snapshot mutex only to swap it, and revision is atomic. The consumer thread owns the
/// continuation. This is the only unchecked crossing of the C callback context.
final class TapContext: @unchecked Sendable {
    // CFRunLoop scheduling/stop/wakeup are thread safe; gesture state never enters this shared gate.
    private struct Gate: @unchecked Sendable {
        var loop: CFRunLoop?
        var stopped = false
        var running = 3
        var failure: ListenerFailure?
        var pointerRoute: PointerRoute?
        var pendingFocus: Int32?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    // 1024 records of 104 bytes is 104 KiB preallocated; a quarter is reserved for critical records.
    let queue = InputQueue(capacity: 1024, reserved: 256)
    let snapshot = Mutex(AttributionSnapshot())
    private let gate = Mutex(Gate())
    private let revisionCounter = Atomic<UInt64>(0)
    private let refreshWanted = Atomic<Bool>(false)
    private let refreshSignal = DispatchSemaphore(value: 0)
    private let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
    private let buttons: InteractionButtonState
    private let hoverEnabled: Bool
    private let excludedPID: Int32
    // Tap thread only.
    private var scroll = ScrollGesture()
    private var typing = TypingGesture()
    private var leftPress: InputRecord?
    private var dragExceededThreshold = false
    private var dwell = HoverDwell()
    private var lastPointer: PointerRoute?
    private var wasDragging = false
    private var focusedProcessID: Int32?
    private var wake: CFRunLoopTimer?
    private var wakeAt: Double?
    private(set) var latency = CallbackLatency()
    // Instruments intervals, begun only while signposts are enabled: no allocation or formatting otherwise.
    private static let signposter = OSSignposter(subsystem: "com.forte.braus", category: "InteractionTap")

    init(
        buttons: InteractionButtonState = InteractionButtonState(),
        continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation,
        hover: Bool,
        excludedPID: Int32
    ) {
        self.buttons = buttons
        self.continuation = continuation
        hoverEnabled = hover
        self.excludedPID = excludedPID
    }

    var revision: UInt64 { revisionCounter.load(ordering: .acquiring) }

    func windowUnderPointer() -> InteractionWindow? {
        guard let point = CGEvent(source: nil)?.location,
              let route = gate.withLock({ $0.pointerRoute }) else { return nil }
        return route.window(at: point, in: InteractionWindowReader.windows(excluding: excludedPID))
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let finished = gate.withLock { state in
                if state.running == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }

    func requestStop() {
        gate.withLock {
            $0.stopped = true
            if let loop = $0.loop {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
                CFRunLoopWakeUp(loop)
            }
        }
        refreshSignal.signal()
    }

    func focus(processID: Int32) {
        let loop = gate.withLock { state in
            if state.loop == nil { state.pendingFocus = processID }
            return state.loop
        }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            let signpost = Self.signposter.isEnabled ? Self.signposter.beginInterval("focus") : nil
            defer { if let signpost { Self.signposter.endInterval("focus", signpost) } }
            guard focusedProcessID != processID else { return }
            focusedProcessID = processID
            if let pending = scroll.take() { queue.push(pending) }
            if let pending = typing.take() { queue.push(pending) }
            let now = Self.uptime()
            if hoverEnabled { dwell.restart(at: Self.seconds(now)) }
            let revisions = advance()
            var record = InputRecord(kind: .focus, timestamp: now,
                                     precedingRevision: revisions.0, revision: revisions.1)
            record.targetPID = processID
            queue.push(record)
            requestRefresh()
            armWake(at: now)
        }
        CFRunLoopWakeUp(loop)
    }

    // MARK: Tap thread

    func run() {
        defer {
            gate.withLock { $0.loop = nil }
            if let pending = scroll.take() { queue.push(pending) }
            if let pending = typing.take() { queue.push(pending) }
            queue.close()
            requestStop()
            leave()
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown,
                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: Self.callback, userInfo: pointer
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            fail(.tapUnavailable)
            return
        }
        let loop: CFRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        let timer = addWakeTimer(to: loop)
        defer {
            CFRunLoopTimerInvalidate(timer)
            wake = nil
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        let start = gate.withLock { state in
            guard !state.stopped else { return false }
            state.loop = loop
            return true
        }
        if start {
            if let initial = gate.withLock({ $0.pendingFocus }) { focus(processID: initial) }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            if !gate.withLock({ $0.stopped }) { fail(.tapDisabled) }
        }
    }

    /// One reusable timer for scroll/typing settle and hover dwell, armed only from their deadlines, so a still
    /// pointer and idle input cost no wakeups. Its interval never elapses in practice.
    func addWakeTimer(to loop: CFRunLoop) -> CFRunLoopTimer? {
        let never = Date.distantFuture.timeIntervalSinceReferenceDate
        let timer = CFRunLoopTimerCreateWithHandler(nil, never, never, 0, 0) { [self] _ in wakeFired() }
        wake = timer
        CFRunLoopAddTimer(loop, timer, .commonModes)
        return timer
    }

    /// The tap callback's body, on the tap thread. Tests drive it with synthetic events.
    func receive(type: CGEventType, event: CGEvent) {
        let signpost = type != .keyDown && Self.signposter.isEnabled ? Self.signposter.beginInterval("receive") : nil
        let begin = Self.uptime()
        defer {
            // Per-key histogram counts would reveal typing length in watch diagnostics.
            if type != .keyDown { latency.record(type, Self.uptime() &- begin) }
            if let signpost { Self.signposter.endInterval("receive", signpost) }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fail(.tapDisabled)
            requestStop()
            return
        }
        // Events posted by this process are never described as manual user input.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(excludedPID) else { return }
        if type == .leftMouseUp { buttons.release() }
        // A plain release preserves the click's revision and dwell deadline.
        if type == .leftMouseUp, leftPress == nil || !dragExceededThreshold {
            leftPress = nil
            dragExceededThreshold = false
            if wasDragging { requestRefresh() }
            wasDragging = false
            return
        }
        let now = Self.uptime()
        let seconds = Self.seconds(now)
        let route = PointerRoute(
            point: event.location,
            recipientWindowNumber: Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)),
            targetProcessID: Int32(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        )
        if type != .keyDown, let finished = typing.take() { queue.push(finished) }
        if type != .keyDown {
            gate.withLock { $0.pointerRoute = route }
            let entered = lastPointer?.recipientWindowNumber != route.recipientWindowNumber
            let dragging = type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
            // Clicks, entering another surface and a drag's end can change which windows matter; other
            // moves, drags and scroll ticks leave the refresher asleep.
            if entered || type == .leftMouseDown || type == .rightMouseDown || (wasDragging && !dragging) {
                requestRefresh()
            }
            wasDragging = dragging
            lastPointer = route
            if hoverEnabled { dwell.moved(to: route.point, surface: route.recipientWindowNumber, at: seconds) }
        }
        // Pointer movement warms ambient routing and dwell without invalidating a pre-click scene.
        if type == .mouseMoved {
            armWake(at: now)
            return
        }
        let revisions = advance()
        if hoverEnabled { dwell.restart(at: seconds) }
        if type == .keyDown {
            if let finished = scroll.take() { queue.push(finished) }
            let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = Self.modifiers(event.flags)
            let isShortcut = modifiers.contains(.command) || modifiers.contains(.control) || Self.isNonText(code)
            if isShortcut, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                armWake(at: now)
                return
            }
            var record = InputRecord(kind: isShortcut ? .shortcut : .typing, timestamp: now,
                                     precedingRevision: revisions.0, revision: revisions.1)
            record.sourcePID = Int32(clamping: event.getIntegerValueField(.eventSourceUnixProcessID))
            record.set(.hasSourceProcess)
            snapshot.withLock { $0.attributeKeyboard(&record, targetProcessID: route.targetProcessID) }
            if isShortcut {
                if let finished = typing.take() { queue.push(finished) }
                record.lostCritical = UInt32(code)
                record.lostCoalescible = modifiers.rawValue
                queue.push(record)
            } else if let finished = typing.append(record) {
                queue.push(finished)
            }
            armWake(at: now)
            return
        }
        if type != .scrollWheel, let finished = scroll.take() { queue.push(finished) }
        if type == .leftMouseDragged, let press = leftPress {
            if hypot(route.point.x - Double(press.x), route.point.y - Double(press.y)) > 3 {
                dragExceededThreshold = true
            }
        }
        if type == .leftMouseUp {
            if var press = leftPress, dragExceededThreshold {
                press.type = InputRecord.Kind.drag.rawValue
                press.lostCritical = 0
                press.valueA = Float32(route.point.x)
                press.valueB = Float32(route.point.y)
                press.timestamp = now
                press.revision = revisions.1
                queue.push(press)
            }
            leftPress = nil
            dragExceededThreshold = false
        }
        guard type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel else {
            armWake(at: now)
            return
        }
        let kind: InputRecord.Kind = type == .scrollWheel ? .scrollDelta
            : type == .rightMouseDown ? .rightClick : .click
        var record = InputRecord(kind: kind, timestamp: now, precedingRevision: revisions.0, revision: revisions.1)
        record.x = Float32(route.point.x)
        record.y = Float32(route.point.y)
        record.sourcePID = Int32(clamping: event.getIntegerValueField(.eventSourceUnixProcessID))
        record.set(.hasSourceProcess)
        if kind == .scrollDelta {
            record.valueA = Float32(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            record.valueB = Float32(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        }
        if kind == .click || kind == .rightClick {
            record.lostCritical = UInt32(clamping: event.getIntegerValueField(.mouseEventClickState))
        }
        attribute(&record, route: route)
        if type == .leftMouseDown {
            buttons.press(processID: record.targetPID)
            leftPress = record
            dragExceededThreshold = false
        }
        if kind == .scrollDelta {
            if let finished = scroll.append(record) { queue.push(finished) }
        } else {
            if let finished = scroll.take() { queue.push(finished) }
            queue.push(record)
        }
        armWake(at: now)
    }

    private func wakeFired() {
        let signpost = Self.signposter.isEnabled ? Self.signposter.beginInterval("wakeFired") : nil
        let begin = Self.uptime()
        defer {
            latency.timer.record(Self.uptime() &- begin)
            if let signpost { Self.signposter.endInterval("wakeFired", signpost) }
        }
        wakeAt = nil
        let now = Self.uptime()
        let seconds = Self.seconds(now)
        if let settled = scroll.settled(at: seconds) { queue.push(settled) }
        if let settled = typing.settled(at: seconds) { queue.push(settled) }
        if hoverEnabled, dwell.fire(at: seconds), let pointer = lastPointer {
            let revision = revisionCounter.load(ordering: .relaxed)
            var record = InputRecord(kind: .hover, timestamp: now, precedingRevision: revision, revision: revision)
            record.x = Float32(pointer.point.x)
            record.y = Float32(pointer.point.y)
            attribute(&record, route: pointer)
            // A hover describes a confirmed surface or nothing, as before.
            if record.has(.windowResolved) { queue.push(record) }
        }
        armWake(at: now)
    }

    /// Moves the one timer earlier when a deadline requires it. Later deadlines wait for the timer to
    /// fire and re-arm it, so continuous movement costs one wakeup per dwell period, not one per event.
    private func armWake(at now: UInt64) {
        let next = min(scroll.deadline ?? .infinity, typing.deadline ?? .infinity, dwell.deadline ?? .infinity)
        guard let wake, next.isFinite, wakeAt.map({ next < $0 }) ?? true else { return }
        wakeAt = next
        CFRunLoopTimerSetNextFireDate(wake, CFAbsoluteTimeGetCurrent() + max(0, next - Self.seconds(now)))
    }

    private func attribute(_ record: inout InputRecord, route: PointerRoute) {
        snapshot.withLock {
            $0.attribute(&record, at: route.point, recipientWindowNumber: route.recipientWindowNumber,
                         targetProcessID: route.targetProcessID)
        }
        if record.has(.staleAttribution) { requestRefresh() }
    }

    private func advance() -> (UInt64, UInt64) {
        let before = revisionCounter.load(ordering: .relaxed)
        // Equality still invalidates every input, but subtraction cannot reveal a typing burst's length.
        let after = max(before &+ 1, Self.uptime())
        revisionCounter.store(after, ordering: .releasing)
        return (before, after)
    }

    private static func modifiers(_ flags: CGEventFlags) -> InteractionEvent.Modifiers {
        var modifiers: InteractionEvent.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// Classifies physical command keys without reading or translating the event's Unicode payload.
    private static func isNonText(_ code: UInt16) -> Bool {
        switch Int(code) {
        case kVK_Return, kVK_Escape, kVK_Tab,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help,
             kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadClear,
             kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            true
        default:
            false
        }
    }

    /// Takes the histograms on the tap thread and delivers them off it. Once its loop has ended the tap
    /// thread writes no more, so they are taken here; a request racing the stop may go unanswered.
    func takeLatency(_ deliver: @escaping @Sendable (CallbackLatency) -> Void) {
        var taken: CallbackLatency?
        let loop = gate.withLock { state in
            if state.loop == nil { taken = state.stopped ? latency.take() : CallbackLatency() }
            return state.loop
        }
        if let taken { return deliver(taken) }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            let taken = latency.take()
            DispatchQueue.global(qos: .utility).async { deliver(taken) }
        }
        CFRunLoopWakeUp(loop)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        if let pointer {
            Unmanaged<TapContext>.fromOpaque(pointer).takeUnretainedValue().receive(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Consumer thread

    func consume() {
        let deliver = { (record: InputRecord) in
            if let event = InteractionWindowReader.event(for: record, excluding: self.excludedPID) {
                self.continuation.yield(event)
            }
        }
        while true {
            queue.waitForRecords(onSpace: retryOnTapThread)
            while let record = queue.pop() { deliver(record) }
            if queue.isClosed {
                queue.drainAfterClose(deliver)
                break
            }
        }
        if let failure = gate.withLock({ $0.failure }) {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
        leave()
    }

    /// Keeps the queue single-producer: its retry runs on the tap thread, never here.
    private func retryOnTapThread() {
        guard let loop = gate.withLock({ $0.loop }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in queue.retry() }
        CFRunLoopWakeUp(loop)
    }

    // MARK: Refresher thread

    /// Lists windows at start, then once per burst of requests, 100 ms after the first of them.
    /// Idle input leaves this thread blocked; the previous snapshot is released outside the mutex.
    func refresh() {
        var generation: UInt32 = 0
        while true {
            refreshWanted.store(false, ordering: .releasing)
            generation &+= 1
            var fresh = AttributionSnapshot(generation: generation,
                                            windows: InteractionWindowReader.windows(excluding: excludedPID))
            snapshot.withLock { swap(&$0, &fresh) }
            refreshSignal.wait()
            if gate.withLock({ $0.stopped }) { break }
            // Requests arriving during the debounce join this refresh; a stop cuts it short.
            _ = refreshSignal.wait(timeout: .now() + .milliseconds(100))
            if gate.withLock({ $0.stopped }) { break }
        }
        leave()
    }

    private func requestRefresh() {
        if !refreshWanted.load(ordering: .relaxed), !refreshWanted.exchange(true, ordering: .acquiringAndReleasing) {
            refreshSignal.signal()
        }
    }

    // MARK: Lifecycle

    private func fail(_ failure: ListenerFailure) {
        gate.withLock { if $0.failure == nil { $0.failure = failure } }
    }

    private func leave() {
        let waiters = gate.withLock { state in
            state.running -= 1
            guard state.running == 0 else { return [CheckedContinuation<Void, Never>]() }
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    private static func seconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e9 }
}
