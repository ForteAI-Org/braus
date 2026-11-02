//
//  AccessibilityAugmenter.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore
import Synchronization

/// AccessibilityAugmenter fills `SceneAugmenting` with the live accessibility tree: it finds the
/// window matching the capture, and runs the core's generic walk under a budget measured on the
/// monotonic clock, which a change of the system time does not move.
///
/// The reads run on one serial background queue per process. Every message blocks its thread until the
/// application answers, so the main thread stays free during a walk; the queue is serial, so two harvests
/// never walk at the same time, and it is not the cooperative pool, which a blocked walk would starve.
///
/// The budget is the guard against a pathological tree: a file browser exposing hundreds of rows
/// measured nine seconds per window unbounded. Running out returns the rows read so far, fewer labels
/// rather than wrong ones, and the quality says the walk stopped at its deadline. Reading needs the
/// Accessibility grant; without it every tree is empty, the answer is an empty list, not an error,
/// and the quality says the grant was absent. A capture whose frame matches no window of the tree
/// answers an empty list with `windowFound` false: that is not a denied grant, and the grant is
/// reported on its own.
public struct AccessibilityAugmenter: SceneAugmenting {

    private let valueGuard: (@Sendable (String) -> Bool)?
    private let budgetSeconds: TimeInterval
    private let messagingTimeoutSeconds: Float
    private let windowNumberResolver: (@Sendable (AXUIElement) -> Int?)?

    /// Creates an augmenter. `budgetSeconds` bounds one walk; `messagingTimeoutSeconds` bounds one
    /// message to the app, set on the application and on every element the walk lists. The walk checks
    /// its deadline between nodes; an in-flight message and its one transient retry can exceed the walk
    /// budget.
    /// `windowNumberResolver` binds identified captures to a native AX window. An absent or failed
    /// resolver yields no native facts for such a capture; it never falls back to geometry or focus.
    /// `valueGuard` opts this walk into secure and reserved value filtering; nil preserves ordinary reads.
    public init(
        budgetSeconds: TimeInterval = 1.5,
        messagingTimeoutSeconds: Float = 2,
        windowNumberResolver: (@Sendable (AXUIElement) -> Int?)? = nil,
        valueGuard: (@Sendable (String) -> Bool)? = nil
    ) {
        self.valueGuard = valueGuard
        self.budgetSeconds           = budgetSeconds
        self.messagingTimeoutSeconds = messagingTimeoutSeconds
        self.windowNumberResolver    = windowNumberResolver
    }

    public func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
        try await read(processID: processID, windowNumber: nil, windowFrame: windowFrame)
    }

    public func augmentation(
        for processID: pid_t, windowNumber: Int, windowFrame: CGRect
    ) async throws -> AccessibilityHarvest {
        try await read(processID: processID, windowNumber: windowNumber, windowFrame: windowFrame)
    }

    /// An identified capture without a resolver is not looked up at all, so its window stays unknown
    /// rather than missing; a capture no window of the tree matches is `windowFound` false.
    private func read(
        processID: pid_t, windowNumber: Int?, windowFrame: CGRect
    ) async throws -> AccessibilityHarvest {
        let budget = budgetSeconds, timeout = messagingTimeoutSeconds, resolve = windowNumberResolver
        let stop = Stop()
        return try await Self.onWalkQueue(stop: stop.set) {
            let trusted = AXIsProcessTrusted()
            guard windowNumber == nil || resolve != nil else {
                return AccessibilityHarvest(elements: [], quality: CaptureQuality(isGrantAvailable: trusted))
            }
            // A node's common attributes in one message: the walk costs this process and the application
            // a third of the messages, with the same answers.
            let reader = LiveAccessibilityReader(
                applicationBundleID  : NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
                elementTimeoutSeconds: timeout,
                valueGuard: valueGuard,
                batchesAttributes: true
            )
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: timeout)
            guard let window = reader.window(
                of: application, matching: windowFrame,
                isCapturedWindow: { node in
                    guard let windowNumber else { return true }
                    return resolve?(node) == windowNumber
                }
            ) else {
                return AccessibilityHarvest(
                    elements: [],
                    quality : CaptureQuality(windowFound: false, isGrantAvailable: trusted)
                )
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(budget))
            var harvest = AccessibilityAugmentation.harvest(
                under      : window,
                windowFrame: windowFrame,
                reader     : reader,
                limits     : AccessibilityAugmentation.Limits(isPastDeadline: { clock.now >= deadline || stop.isSet })
            )
            harvest.quality.isGrantAvailable = trusted
            return harvest
        }
    }

    static let walkQueue = DispatchQueue(label: "dev.forte.perception.accessibility", qos: .userInitiated)

    /// Runs `body` on `walkQueue` and resumes the caller with its value. The AX handles live only inside
    /// `body`; what crosses back is the Sendable value. Cancellation abandons the result and calls `stop`,
    /// while the serial queue still owns an AX message already running.
    static func onWalkQueue<Value: Sendable>(
        stop: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable () -> Value
    ) async throws -> Value {
        try await AbandonableRead.run(body, queue: walkQueue, stop: stop)
    }

    /// Set when the caller is cancelled: the walk stops at its next node instead of spending its budget
    /// on the queue the next walk waits on (a scene read a person's take-over interrupted).
    private final class Stop: Sendable {
        private let flag = Atomic<Bool>(false)

        @Sendable func set() { flag.store(true, ordering: .relaxed) }

        var isSet: Bool { flag.load(ordering: .relaxed) }
    }
}
