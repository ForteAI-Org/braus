import CoreGraphics
import SeatCore
@testable import SeatInput
import Testing

@Suite("Progressive human pointer input")
struct HumanPointerGestureTests {
    private let point = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)

    @Test("down reaches the consumer before the producer supplies up")
    @MainActor func progressiveDelivery() async throws {
        let gesture = HumanPointerGesture(at: point)
        var phases: [HumanPointerGesture.Phase] = []
        try await gesture.consume { phase, _, _, cleanup in
            #expect(!cleanup)
            phases.append(phase)
            if phase == .down {
                try gesture.move(to: point)
                try gesture.release(at: point)
            }
        }
        #expect(phases == [.down, .dragged, .up])
    }

    @Test("an unfinished stream releases exactly the press it delivered")
    @MainActor func interruptedRelease() async throws {
        let gesture = HumanPointerGesture(at: point)
        var phases: [HumanPointerGesture.Phase] = []
        do {
            try await gesture.consume { phase, _, _, cleanup in
                phases.append(phase)
                if phase == .down { gesture.cancel() }
                if phase == .up { #expect(cleanup) }
            }
            Issue.record("unfinished gesture succeeded")
        } catch let failure as HumanPointerFailure {
            #expect(failure.postedEventCount == 2)
            #expect(failure.releaseFailure == nil)
        }
        #expect(phases == [.down, .up])
    }

    @Test("a refused down produces no cleanup input")
    @MainActor func refusedDown() async throws {
        let gesture = HumanPointerGesture(at: point)
        var posts = 0
        do {
            try await gesture.consume { _, _, _, _ in
                posts += 1
                throw CancellationError()
            }
            Issue.record("refusal succeeded")
        } catch let failure as HumanPointerFailure {
            #expect(failure.postedEventCount == 0)
        }
        #expect(posts == 1)
    }

    @Test("overflow refuses without silently dropping a movement")
    @MainActor func overflow() async throws {
        let gesture = HumanPointerGesture(at: point, capacity: 1)
        try gesture.move(to: point)
        #expect(throws: HumanPointerGesture.Refusal.overflow) { try gesture.move(to: point) }
        await #expect(throws: HumanPointerFailure.self) {
            try await gesture.consume { _, _, _, _ in }
        }
    }

    @Test("a gesture cannot be replayed by a second consumer")
    @MainActor func singleConsumer() async throws {
        let gesture = HumanPointerGesture(at: point)
        try gesture.release(at: point)
        try await gesture.consume { _, _, _, _ in }
        await #expect(throws: HumanPointerGesture.Refusal.closed) {
            try await gesture.consume { _, _, _, _ in Issue.record("replayed") }
        }
    }

    @Test("each fragment builds one native mouse event without posting")
    func eventConstruction() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        for (phase, type) in [(HumanPointerGesture.Phase.down, CGEventType.leftMouseDown),
                              (.dragged, .leftMouseDragged), (.up, .leftMouseUp)] {
            var events: [PreparedEvent] = []
            try InputEvents.appendHumanPointer(phase, at: point, modifiers: [.shift],
                source: source, correlationID: 91, into: &events)
            #expect(events.count == 1)
            #expect(events[0].event.type == type)
            #expect(events[0].event.flags.contains(.maskShift))
            #expect(events[0].event.getIntegerValueField(.eventSourceUserData) == 91)
            #expect(events[0].delayAfterPostingMicroseconds == 0)
        }
    }
    @Test("an idle producer expires and releases its press")
    @MainActor func deadlineCleanup() async throws {
        let gesture = HumanPointerGesture(at: point)
        var phases: [HumanPointerGesture.Phase] = []
        do {
            try await gesture.consume(within: .milliseconds(10)) { phase, _, _, _ in phases.append(phase) }
            Issue.record("expired gesture succeeded")
        } catch let failure as HumanPointerFailure {
            #expect(failure.cause as? HumanPointerGesture.Refusal == .expired)
            #expect(failure.releaseFailure == nil)
        }
        #expect(phases == [.down, .up])
    }

    @Test("cleanup refusal preserves partial delivery and the cleanup failure")
    @MainActor func cleanupRefusal() async throws {
        let gesture = HumanPointerGesture(at: point)
        do {
            try await gesture.consume { phase, _, _, cleanup in
                if phase == .down { gesture.cancel() }
                if cleanup { throw HumanPointerGesture.Refusal.unsupported }
            }
            Issue.record("cleanup refusal succeeded")
        } catch let failure as HumanPointerFailure {
            #expect(failure.postedEventCount == 1)
            #expect(failure.releaseFailure as? HumanPointerGesture.Refusal == .unsupported)
        }
    }

    @Test("native multi-click count survives every fragment", arguments: [1, 2, 3])
    func clickCount(_ count: Int) throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        let gesture = HumanPointerGesture(at: point, clickCount: count)
        #expect(gesture.clickCount == count)
        for phase in [HumanPointerGesture.Phase.down, .dragged, .up] {
            var events: [PreparedEvent] = []
            try InputEvents.appendHumanPointer(phase, at: point, modifiers: [],
                source: source, correlationID: 1, clickCount: gesture.clickCount, into: &events)
            #expect(events[0].event.getIntegerValueField(.mouseEventClickState) == Int64(count))
            #expect(events.count == 1)
        }
    }

}
