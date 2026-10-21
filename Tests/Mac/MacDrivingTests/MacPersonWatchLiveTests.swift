import CoreGraphics
import Foundation
import MacDriver
import Testing

/// The person watch on the real event stream. BRAUS_MAC_LIVE_TESTS=1: it posts three scroll-wheel
/// events of zero pixels through the HID stream, which move nothing, and expects the watch to note them
/// under some process. Needs Input Monitoring for the test process.
@Suite("MacDriver person watch, live")
struct MacPersonWatchLiveTests {

    @Test("A listen-only tap notes input from the HID stream under its target process",
          .enabled(if: ProcessInfo.processInfo.environment["BRAUS_MAC_LIVE_TESTS"] == "1"))
    func notesInput() async throws {
        let watch = LiveMacPersonWatch()
        try #require(watch.isWatching)
        for _ in 0..<3 {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!watch.touches.isEmpty)
        #expect(watch.touches.keys.contains { $0 > 0 })
    }
}
