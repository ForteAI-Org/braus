import Foundation
import Testing
@testable import Braus

extension RoomLightTests {

    @Test("Rooms created together submit in one tick without waiting for another room's readback")
    func newRoomsSubmitTogether() {
        let clock = QueueClock()
        let queue = RoomRenderQueue(
            now     : { clock.now },
            schedule: clock.schedule
        )
        let rooms = (0..<8).map { _ in QueueRoom() }
        for room in rooms {
            queue.enqueue(room)
        }

        clock.tick()

        // No completion has arrived: a slow pulse readback must not hold the other seven rooms.
        #expect(rooms.map(\.submissions) == Array(repeating: 1, count: 8))
        #expect(clock.waiters.isEmpty)

        // A room still owns its in-flight guard even though other rooms may submit.
        for room in rooms {
            queue.enqueue(room)
        }
        clock.tick()
        #expect(rooms.map(\.submissions) == Array(repeating: 1, count: 8))
        #expect(clock.waiters.isEmpty)
    }

    @Test("Precomputed rooms bypass a busy ray tracer and cannot release its refinement slot")
    func precomputedRoomsDoNotOwnTheRefinementSlot() {
        let clock = QueueClock()
        let queue = RoomRenderQueue(
            now     : { clock.now },
            schedule: clock.schedule
        )
        let first = QueueRoom()
        first.path = .rayTraced
        queue.enqueue(first)
        clock.tick()
        #expect(first.submissions == 1)

        let second = QueueRoom()
        second.path = .rayTraced
        queue.enqueue(second)
        let rooms = (0..<8).map { _ in QueueRoom() }
        for room in rooms {
            queue.enqueue(room)
        }
        clock.tick()
        #expect(rooms.map(\.submissions) == Array(repeating: 1, count: 8))
        #expect(second.submissions == 0)

        for room in rooms {
            queue.didFinishRender(for: room.path)
        }
        clock.tick()
        #expect(second.submissions == 0)
        #expect(clock.waiters.isEmpty)

        queue.didFinishRender(for: first.path)
        clock.tick()
        #expect(second.submissions == 1)
        queue.didFinishRender(for: second.path)
        #expect(clock.waiters.isEmpty)
    }

    @Test("Ray-traced refinements still wait a frame even when completion arrives immediately")
    func refinementStartsStaySpaced() throws {
        let clock = QueueClock()
        let queue = RoomRenderQueue(
            now     : { clock.now },
            schedule: clock.schedule
        )
        let rooms = (0..<2).map { _ in QueueRoom() }
        for room in rooms {
            room.path = .rayTraced
            queue.enqueue(room)
        }
        clock.tick()
        #expect(rooms.map(\.submissions).reduce(0, +) == 1)
        queue.didFinishRender(for: .rayTraced)
        let wake = try #require(clock.waiters.first)
        #expect(wake.deadline - clock.now >= .milliseconds(17))
        clock.tick()
        #expect(rooms.map(\.submissions) == [1, 1])
        queue.didFinishRender(for: .rayTraced)
        #expect(clock.waiters.isEmpty)
    }

    @Test("Removed, released, settling and unavailable rooms cannot strand a ready batch")
    func batchRechecksRoomReadiness() {
        let clock = QueueClock()
        let queue = RoomRenderQueue(
            now     : { clock.now },
            schedule: clock.schedule
        )
        let removed = QueueRoom()
        queue.enqueue(removed)
        queue.remove(removed)
        var released: QueueRoom? = QueueRoom()
        weak let borrowed = released
        if let released { queue.enqueue(released) }
        released = nil
        #expect(borrowed == nil)

        let settling = QueueRoom()
        queue.enqueue(settling)
        settling.canRenderQueuedFrame = false
        let unavailable = QueueRoom()
        unavailable.acceptsSubmission = false
        queue.enqueue(unavailable)
        let ready = QueueRoom()
        queue.enqueue(ready)
        queue.enqueue(ready)

        clock.tick()
        #expect(removed.submissions == 0)
        #expect(settling.submissions == 0)
        #expect(unavailable.submissions == 0)
        #expect(ready.submissions == 1)
        #expect(clock.waiters.isEmpty)

        settling.canRenderQueuedFrame = true
        queue.enqueue(settling)
        clock.tick()
        #expect(settling.submissions == 1)
        #expect(clock.waiters.isEmpty)
    }

    @Test("A batch keeps visible and changed rooms ahead of settled geometry")
    func batchPreservesPriority() {
        let clock = QueueClock()
        let queue = RoomRenderQueue(
            now     : { clock.now },
            schedule: clock.schedule
        )
        var order: [Int] = []
        let rooms = (0..<4).map { index in
            let room = QueueRoom()
            room.onSubmit = { order.append(index) }
            return room
        }
        rooms[0].renderPriority = (false, true, 400)
        rooms[1].renderPriority = (true, false, 100)
        rooms[2].renderPriority = (true, false, 200)
        rooms[3].renderPriority = (true, true, 0)
        for room in rooms {
            queue.enqueue(room)
        }
        clock.tick()
        #expect(order == [3, 2, 1, 0])
        #expect(clock.waiters.isEmpty)
    }

    /// QueueRoom records real queue admissions while holding GPU completion and image readback.
    @MainActor
    private final class QueueRoom: RoomRenderTarget {
        var canRenderQueuedFrame = true
        var path: LightingPath? = .precomputed
        var renderPriority = (visible: true, uniforms: false, top: CGFloat.zero)
        var submissions = 0
        var acceptsSubmission = true
        var onSubmit: () -> Void = {}

        func renderQueuedFrame() -> Bool {
            guard canRenderQueuedFrame, acceptsSubmission else { return false }
            canRenderQueuedFrame = false
            submissions += 1
            onSubmit()
            return true
        }
    }

    /// QueueClock advances scheduled work one 60 Hz tick at a time without sleeping or using a GPU.
    @MainActor
    private final class QueueClock {
        var now = ContinuousClock.now
        var waiters: [(deadline: ContinuousClock.Instant, action: @MainActor () -> Void)] = []

        func schedule(
            after delay: Duration,
            action     : @escaping @MainActor () -> Void
        ) {
            waiters.append((now + delay, action))
        }

        func tick() {
            now += .milliseconds(17)
            let ready = waiters.filter { $0.deadline <= now }
            waiters.removeAll { $0.deadline <= now }
            for waiter in ready {
                waiter.action()
            }
        }
    }
}
