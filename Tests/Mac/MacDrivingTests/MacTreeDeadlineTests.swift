import Foundation
@testable import MacDriver
@testable import MacDriving
import Testing

/// The read's budget on the monotonic clock (defect C of the closure audit, N02): it counts the lookup before the
/// walk, stops a slow walk between two nodes with stable paths and says so, and comes from the clock the walk is
/// given, never from the civil one. A fake clock advances by each element's cost: no sleep, no change to the system
/// clock, no app.
@Suite("The Mac walk's budget on the monotonic clock")
struct MacTreeDeadlineTests {

    /// SteppingClock is a monotonic clock that moves only when told: `advance` adds to its reading.
    final class SteppingClock {
        let base = ContinuousClock.now
        private(set) var elapsed = Duration.zero
        func advance(_ step: Duration) { elapsed += step }
        func now() -> ContinuousClock.Instant { base + elapsed }
    }

    /// SlowElements answers `reads` and advances `clock` by `cost` for each element it reads, as a slow app does.
    struct SlowElements: MacElementSource {
        let reads: [Int: MacElementRead<Int>]
        let clock: SteppingClock
        let cost : Duration

        func read(_ element: Int, timeout: Float) -> Result<MacElementRead<Int>, MacReadFailure> {
            clock.advance(cost)
            return reads[element].map { .success($0) } ?? .failure(.timedOut)
        }
        func actions(_ element: Int) -> Result<[String], MacReadFailure> { .success([]) }
        func header(_ element: Int) -> Result<Int?, MacReadFailure> { .success(nil) }
    }

    /// A window with three buttons.
    static var reads: [Int: MacElementRead<Int>] {
        [
            0: MacElementRead(node: MacTreeNode(role: "AXWindow", title: "Prova"), children: .success([1, 2, 3])),
            1: MacElementRead(node: MacTreeNode(role: "AXButton", title: "Uno")),
            2: MacElementRead(node: MacTreeNode(role: "AXButton", title: "Due")),
            3: MacElementRead(node: MacTreeNode(role: "AXButton", title: "Tre")),
        ]
    }

    static let limits = MacTreeLimits(deadline: 3)

    /// A walk whose read began at the clock's base, after `lookup` already passed, each element costing `cost`.
    private static func walk(lookup: Duration = .zero, cost: Duration, limits: MacTreeLimits = limits) throws
        -> MacTreeRead {
        let clock = SteppingClock()
        clock.advance(lookup)
        return try MacTreeWalk.read(window: 0, index: 0, source: SlowElements(reads: reads, clock: clock, cost: cost),
                                    limits: limits, started: clock.base, now: clock.now)
    }

    @Test("a walk that runs out stops between two nodes: the paths read so far, deadline as the reason")
    func stopsBetweenNodes() throws {
        let read = try Self.walk(cost: .seconds(1))
        #expect(read.stoppedBy == .deadline)
        #expect(read.window.children.map(\.path) == [[0], [1]], "the same paths a whole read gives them")
        #expect(read.window.children.map(\.title) == ["Uno", "Due"])
        #expect(read.duration == 3, "the window and two buttons, a second each")
    }

    @Test("the lookup before the walk counts against the budget")
    func lookupCounts() throws {
        let whole = try Self.walk(cost: .milliseconds(300))
        #expect(whole.stoppedBy == nil && whole.window.children.count == 3, "with no lookup cost the read is whole")

        let late = try Self.walk(lookup: .milliseconds(2_500), cost: .milliseconds(300))
        #expect(late.stoppedBy == .deadline)
        #expect(late.window.children.map(\.title) == ["Uno"], "2.5 s of lookup leave the window and one button")
        #expect(abs(late.duration - 3.1) < 1e-9, "the duration counts the lookup too: \(late.duration)")
    }

    @Test("a walk within its budget completes, with its duration from the clock it was given")
    func ordinaryCompletion() throws {
        let read = try Self.walk(cost: .milliseconds(10))
        #expect(read.stoppedBy == nil && read.window.children.map(\.title) == ["Uno", "Due", "Tre"])
        #expect(abs(read.duration - 0.04) < 1e-9 && read.duration >= 0, "\(read.duration)")
    }

    @Test("only the walk's monotonic clock counts: one that does not move spends nothing, however long the test takes")
    func onlyTheGivenClock() throws {
        let read = try Self.walk(cost: .zero)
        #expect(read.stoppedBy == nil && read.window.children.count == 3)
        #expect(read.duration == 0)
    }

    @Test("by default the walk reads the system's monotonic clock: a whole read, a duration never negative")
    func defaultClock() throws {
        let clock = SteppingClock()
        let read = try MacTreeWalk.read(window: 0, index: 0,
                                        source: SlowElements(reads: Self.reads, clock: clock, cost: .zero),
                                        limits: Self.limits)
        #expect(read.stoppedBy == nil && read.window.children.count == 3)
        #expect(read.duration >= 0)
    }

    // MARK: When nothing of the window was read

    @Test("a budget spent by the lookup before the window is read: the window is unreadable for lack of time, not gone")
    func budgetSpentBeforeTheWindow() throws {
        #expect(throws: MacTreeFailure.windowUnreadable(index: 0, cause: .timedOut)) {
            try Self.walk(lookup: .seconds(3), cost: .milliseconds(10))
        }
    }

    @Test("a budget that runs out right after the window keeps the window read: a partial tree, no error")
    func budgetSpentAfterTheWindow() throws {
        let read = try Self.walk(lookup: .milliseconds(2_500), cost: .seconds(1))
        #expect(read.stoppedBy == .deadline && read.window.role == "AXWindow" && read.window.children.isEmpty)
    }

    @Test("an element limit that reads nothing stays windowNotFound; a depth limit keeps the window: neither is time")
    func otherLimitsAreNotTime() throws {
        #expect(throws: MacTreeFailure.windowNotFound(index: 0)) {
            try Self.walk(cost: .milliseconds(10), limits: MacTreeLimits(elementLimit: 0, deadline: 3))
        }
        let shallow = try Self.walk(cost: .milliseconds(10), limits: MacTreeLimits(depthLimit: 0, deadline: 3))
        #expect(shallow.stoppedBy == .depthLimit && shallow.window.role == "AXWindow")
        #expect(shallow.window.children.isEmpty)
    }

    @Test("an app that lists no window is a window not found, not a timeout")
    func noWindowIsNotFound() async throws {
        let scenes = MacScenes(reader: FakeTreeReader(windows: [9: []]), serverWindows: { _ in [] })
        await #expect(throws: MacTreeFailure.windowNotFound(index: 0)) { try await scenes.scene(of: 9) }
    }
}
