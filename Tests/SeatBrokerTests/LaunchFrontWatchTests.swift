import CoreGraphics
@testable import SeatBroker
import Synchronization
import Testing

/// The front watch of a launch over scripted readings: what it gives back, how often, and what it
/// leaves alone. Controlled readings only; no application is launched and nothing is restored.
@Suite("Watching the front while an application starts")
struct LaunchFrontWatchTests {

    typealias Reading = LaunchFrontWatch.Reading

    static let person  : pid_t = 100
    static let launched: pid_t = 7
    static let other   : pid_t = 200

    static let personsFront = Reading(windowOwner: person, activeApplication: person)
    static let activated    = Reading(windowOwner: person, activeApplication: launched)
    static let windowAbove  = Reading(windowOwner: launched, activeApplication: person)

    /// Readings handed out one per read, in order. The read numbered `cancelsAt`, the last one by
    /// default, cancels the watch's task; once all are read, the person's application holds the front.
    final class Script: Sendable {
        private let readings : Mutex<[Reading]>
        private let reads    = Mutex(0)
        private let cancelsAt: Int
        let takings = Mutex<[LaunchFrontWatch.Taking]>([])

        init(_ readings: [Reading], cancelsAt: Int? = nil) {
            self.readings  = Mutex(readings)
            self.cancelsAt = cancelsAt ?? readings.count
        }

        var unread: Int { readings.withLock { $0.count } }

        func read() -> Reading {
            let count = reads.withLock { reads in
                reads += 1
                return reads
            }
            if count >= cancelsAt { withUnsafeCurrentTask { $0?.cancel() } }
            return readings.withLock { $0.isEmpty ? LaunchFrontWatchTests.personsFront : $0.removeFirst() }
        }
    }

    /// Runs the watch on its own task over `script` and answers what it asked to restore.
    static func watch(_ script: Script, settle: Duration = .seconds(3600)) async -> [LaunchFrontWatch.Taking] {
        await Task {
            await LaunchFrontWatch.run(
                person    : person,
                interval  : .milliseconds(1),
                settle    : settle,
                read      : { script.read() },
                isLaunched: { $0 == launched },
                restore   : { taking in script.takings.withLock { $0.append(taking) } }
            )
        }.value
        return script.takings.withLock { $0 }
    }

    @Test("an activation is given back once per taking of the front, read again on the main actor")
    func oneRestorePerTaking() async {
        // Each restore reads twice, off the main actor and on it.
        let script = Script([Self.personsFront, Self.activated, Self.activated, Self.activated, Self.activated,
                             Self.personsFront, Self.activated, Self.activated, Self.personsFront])
        let takings = await Self.watch(script)
        #expect(takings.map(\.signal) == [.activation, .activation])
        #expect(takings.map(\.processID) == [Self.launched, Self.launched])
        #expect(takings[0].elapsed <= takings[1].elapsed)
    }

    @Test("a front still held after the settle time is asked again, and the limit ends the watch")
    func theLimitEndsTheWatch() async {
        let script = Script(Array(repeating: Self.activated, count: 20))
        let takings = await Self.watch(script, settle: .zero)
        #expect(takings.count == LaunchFocusComeback.restoreLimit)
        // It ended by itself, with readings left unread.
        #expect(script.unread == 20 - 2 * LaunchFocusComeback.restoreLimit)
    }

    @Test("a window put above the person's without activating is given back")
    func aWindowAboveThePersonsIsGivenBack() async {
        let takings = await Self.watch(Script([Self.windowAbove, Self.windowAbove, Self.personsFront]))
        #expect(takings.map(\.signal) == [.window])
        #expect(takings.map(\.processID) == [Self.launched])
    }

    @Test("an application the person chose is left in front, under the launched window or not")
    func thePersonsChoiceIsLeftAlone() async {
        let script = Script([
            Reading(windowOwner: Self.launched, activeApplication: Self.other),
            Reading(windowOwner: Self.other, activeApplication: Self.other),
            Reading(windowOwner: nil, activeApplication: nil),
            Self.personsFront,
        ])
        #expect(await Self.watch(script).isEmpty)
    }

    @Test("a taking over by the time the main actor reads again is not given back")
    func aTakingAlreadyOverIsNotGivenBack() async {
        #expect(await Self.watch(Script([Self.activated, Self.personsFront, Self.personsFront])).isEmpty)
    }

    @Test("a watch cancelled between its reading and the restore restores nothing")
    func aCancelledWatchRestoresNothing() async {
        let script = Script([Self.activated, Self.activated, Self.activated], cancelsAt: 1)
        #expect(await Self.watch(script).isEmpty)
        // Not even read again on the main actor.
        #expect(script.unread == 2)
    }

    @Test("the front window is the first ordinary one: layer 0 and not transparent")
    func theFrontWindowIsTheFirstOrdinaryOne() {
        func window(_ pid: pid_t, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha]
        }
        let list = [window(1, layer: 25), window(2, alpha: 0), window(Self.launched), window(Self.person)]
        #expect(LaunchFrontWatch.frontWindowOwner(in: list) == Self.launched)
        #expect(LaunchFrontWatch.frontWindowOwner(in: []) == nil)
    }
}
