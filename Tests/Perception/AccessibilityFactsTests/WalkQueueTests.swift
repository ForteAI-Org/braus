//
//  WalkQueueTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/10/2026.
//

import Dispatch
@testable import AccessibilityFacts
import Foundation
import Testing
import Synchronization

/// The accessibility walk blocks its thread on every message, so it runs on its own serial queue and
/// never on the main thread, even when the harvest is awaited from the main actor.
@Suite("Where the accessibility walk runs")
struct WalkQueueTests {

    @Test func cancelledWalkDoesNotWaitForAX() async throws {
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ended = Mutex(false)
        let read = Task {
            defer { ended.withLock { $0 = true } }
            return try await AccessibilityAugmenter.onWalkQueue {
                began.signal()
                _ = release.wait(timeout: .now() + 5)
                return 1
            }
        }
        @Sendable func waitForStart() -> Bool { began.wait(timeout: .now() + 5) == .success }
        #expect(await Task.detached { waitForStart() }.value)
        read.cancel()
        let deadline = ContinuousClock.now + .milliseconds(300)
        while !ended.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ended.withLock { $0 }, "cancellation must not wait for a blocked AX message")
        release.signal()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test("a walk awaited from the main actor runs off the main thread, on the accessibility queue")
    @MainActor
    func offMain() async throws {
        #expect(pthread_main_np() != 0)
        let place = try await AccessibilityAugmenter.onWalkQueue {
            (isMain: pthread_main_np() != 0, label: String(cString: __dispatch_queue_get_label(nil)))
        }
        #expect(!place.isMain)
        #expect(place.label == "dev.forte.perception.accessibility")
    }
}
