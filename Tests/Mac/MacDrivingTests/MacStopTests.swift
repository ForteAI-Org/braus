import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
@testable import MacDriver
@testable import MacDriving
import Synchronization
import Testing

/// The call's stop on the Mac route (defect B of the closure audit, N16): a call whose task is cancelled after the
/// scene was read sends no new accessibility request or event. Before anything went out the gesture is refused as
/// `stopped`, a `GestureNotSent`; once an effect went out it stands, the answer stays uncertain and nothing is sent
/// again. No app and no accessibility: fake hands keep the live reader's contract, and the live focus sequence and
/// selection run with scripted writes.
@Suite("The Mac route stops between the read and the delivery")
struct MacStopTests {

    /// Log keeps what a task records, for the test to read after the task ended.
    final class Log: Sendable {
        private let entries = Mutex<[String]>([])
        func add(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
        func clear() { entries.withLock { $0.removeAll() } }
    }

    /// StoppingHands are accessibility hands that keep the live contract: the reads first (`beforeWrite`, which may
    /// suspend or stop the call), then the call's stop checked right before the write, then the write, recorded, and
    /// `afterWrite`. Focus runs the live two-write sequence (`LiveMacTreeReader.focus`), with `afterMain` between the
    /// writes. `listsNoAction` answers every press `actionNotListed`, read before any write.
    final class StoppingHands: MacAccessibilityActing {

        let writes = Mutex<[String]>([])
        private let listsNoAction: Bool
        private let beforeWrite  : @Sendable () async -> Void
        private let afterWrite   : @Sendable () -> Void
        private let afterMain    : @Sendable () -> Void

        init(
            listsNoAction: Bool = false,
            beforeWrite  : @escaping @Sendable () async -> Void = {},
            afterWrite   : @escaping @Sendable () -> Void = {},
            afterMain    : @escaping @Sendable () -> Void = {}
        ) {
            self.listsNoAction = listsNoAction
            self.beforeWrite   = beforeWrite
            self.afterWrite    = afterWrite
            self.afterMain     = afterMain
        }

        func perform(_ action: String, on element: MacElementAddress) async throws {
            await beforeWrite()
            if listsNoAction { throw MacTreeFailure.actionNotListed(action) }
            try write("\(action) \(element.path)")
        }

        func select(_ element: MacElementAddress) async throws {
            await beforeWrite()
            try write("select \(element.path)")
        }

        func focus(_ element: MacElementAddress) async throws {
            await beforeWrite()
            try LiveMacTreeReader.focus(
                settingMain: {
                    self.writes.withLock { $0.append(kAXMainAttribute) }
                    self.afterMain()
                    return .success
                },
                thenFocused: {
                    self.writes.withLock { $0.append("\(kAXFocusedAttribute) \(element.path)") }
                    return .success
                }
            )
        }

        func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) async throws -> String {
            await beforeWrite()
            try write("scroll \(direction.rawValue) \(area.path)")
            return "scroll bar AXValue"
        }

        func readBack(_ element: MacElementAddress) async -> MacTreeNode? { nil }

        private func write(_ request: String) throws {
            try Task.checkCancellation()
            writes.withLock { $0.append(request) }
            afterWrite()
        }
    }

    /// Stops the task running it, as the router's pause cancels the active call.
    static let stopNow: @Sendable () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }

    static let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A button, a field and a pop-up.
    static let window: MacTreeNode = Trees.window("Prova", frame, children: [
        MacTreeNode(role: "AXButton", title: "OK", frame: CGRect(x: 10, y: 10, width: 60, height: 20),
                    actions: ["AXPress"]),
        MacTreeNode(role: "AXTextField", descriptionText: "Nome", frame: CGRect(x: 10, y: 40, width: 200, height: 20)),
        MacTreeNode(role: "AXPopUpButton", value: "medio", frame: CGRect(x: 10, y: 70, width: 80, height: 20),
                    actions: ["AXPress"]),
    ])

    static let button = CGPoint(x: 20, y: 20)
    static let field  = CGPoint(x: 50, y: 50)
    static let popUp  = CGPoint(x: 30, y: 80)

    private static func cache() -> MacSceneCache {
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: window, windowIndex: 0, windowNumber: 77), for: 9)
        return cache
    }

    private static func actuator(
        _ hands   : any MacAccessibilityActing,
        _ delivery: FakeDelivery,
        focus     : (any MacWorkspace)? = nil
    ) -> MacActuator {
        MacActuator(cache: cache(), actor: hands, delivery: delivery, person: nil, focus: focus)
    }

    /// Runs `body` in a task of its own, which the body may stop, and answers its error, nil when it threw none.
    private static func run(_ body: @escaping @Sendable () async throws -> Void) async -> (any Error)? {
        await Task { () async -> (any Error)? in
            do { try await body(); return nil } catch { return error }
        }.value
    }

    // MARK: Before anything went out

    @Test("a call already stopped sends no request, even through hands that check nothing, and nothing to rung 2")
    func alreadyStoppedClick() async throws {
        let hands    = FakeTreeReader(windows: [9: [(MacWindowSummary(index: 0, role: "AXWindow"), Self.window)]])
        let delivery = FakeDelivery()
        let actuator = Self.actuator(hands, delivery)
        let error = await Self.run { Self.stopNow(); try await actuator.perform(.click(at: Self.button), in: 9) }
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(hands.steps.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty)
        #expect(actuator.lastDelivery(in: 9) == nil)
    }

    @Test("keys of a call already stopped are not posted")
    func alreadyStoppedKeys() async throws {
        let delivery = FakeDelivery()
        let actuator = Self.actuator(StoppingHands(), delivery)
        let error = await Self.run { Self.stopNow(); try await actuator.perform(.type("ciao"), in: 9) }
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("a stop while the hands still read the target, suspended, sends nothing: refused as stopped")
    func stopDuringResolve() async throws {
        let (entered, inside) = AsyncStream<Void>.makeStream()
        let (release, open)   = AsyncStream<Void>.makeStream()
        let hands = StoppingHands(beforeWrite: {
            inside.yield()
            for await _ in release { break }
        })
        let delivery = FakeDelivery()
        let actuator = Self.actuator(hands, delivery)
        let call = Task { try await actuator.perform(.click(at: Self.button), in: 9) }
        for await _ in entered { break }
        call.cancel()
        open.yield()
        let error: (any Error)?
        do { try await call.value; error = nil } catch let thrown { error = thrown }
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(hands.writes.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("rung 1 refused before any request, then a stop: rung 2 is not tried, and the gesture was not sent")
    func stopBetweenNotListedAndRungTwo() async throws {
        let unstopped = FakeDelivery()
        let fallen = await Self.run {
            try await Self.actuator(StoppingHands(listsNoAction: true), unstopped)
                .perform(.click(at: Self.button), in: 9)
        }
        #expect(fallen == nil && unstopped.sent.withLock { $0.count } == 1, "without a stop it falls to rung 2")

        let delivery = FakeDelivery()
        let hands    = StoppingHands(listsNoAction: true, beforeWrite: { Self.stopNow() })
        let error = await Self.run { try await Self.actuator(hands, delivery).perform(.click(at: Self.button), in: 9) }
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(delivery.sent.withLock { $0 }.isEmpty && hands.writes.withLock { $0 }.isEmpty)
    }

    @Test("a stop before the first request settles the front app's guard all the same")
    func guardSettledOnStop() async throws {
        let person    = MacRunningApp(processID: 99, bundleID: "com.example.person", name: "Person")
        let workspace = FakeWorkspace(apps: [], front: person, running: [person])
        let actuator  = Self.actuator(StoppingHands(beforeWrite: { Self.stopNow() }), FakeDelivery(), focus: workspace)
        let error = await Self.run { try await actuator.perform(.click(at: Self.button), in: 9) }
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(actuator.takeFocus(in: 9) != nil, "the guard begun before the stop was settled")
    }

    @Test("a stop reaching a control press answers not pressed, and the click the engine tries next is refused")
    func controlPressThenClick() async throws {
        let hands    = StoppingHands()
        let delivery = FakeDelivery()
        let cache    = Self.cache()
        let controls = MacControls(cache: cache, reader: FakeTreeReader(windows: [:]), actor: hands, menus: NoMenus())
        let actuator = MacActuator(cache: cache, actor: hands, delivery: delivery, person: nil)
        let log      = Log()
        let error = await Self.run {
            Self.stopNow()
            let press = await controls.pressControl(labelled: "medio", in: 9)
            log.add("pressed \(press)")
            if !press { try await actuator.perform(.click(at: Self.popUp), in: 9) }
        }
        #expect(log.all == ["pressed false"])
        #expect(error as? GestureNotSent == MacActuator.stopped)
        #expect(hands.writes.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty, "no gesture started")
    }

    // MARK: After an effect went out

    @Test("a stop after the press went out leaves it standing, and the call's next gesture is not sent")
    func effectThenStop() async throws {
        let hands    = StoppingHands(afterWrite: { Self.stopNow() })
        let delivery = FakeDelivery()
        let actuator = Self.actuator(hands, delivery)
        let log      = Log()
        _ = await Self.run {
            for _ in 0..<2 {
                do { try await actuator.perform(.click(at: Self.button), in: 9); log.add("sent") }
                catch { log.add("\(error)") }
            }
        }
        #expect(log.all == ["sent", MacActuator.stopped.sentence], "the press stands, never replayed")
        #expect(hands.writes.withLock { $0 } == ["AXPress [0]"] && delivery.sent.withLock { $0 }.isEmpty)
        #expect(actuator.lastDelivery(in: 9)?.rung == .accessibility)
    }

    @Test("a stop between focus's two writes leaves AXFocused unwritten and answers uncertain, never not sent")
    func stopBetweenFocusWrites() async throws {
        let hands    = StoppingHands(afterMain: { Self.stopNow() })
        let delivery = FakeDelivery()
        let actuator = Self.actuator(hands, delivery)
        let error = await Self.run { try await actuator.perform(.click(at: Self.field), in: 9) }
        guard case .uncertain(let reason)? = error as? MacActuationFailure else {
            Issue.record("not uncertain: \(String(describing: error))")
            return
        }
        #expect(reason.contains(kAXMainAttribute) && reason.contains("stopped"), "\(reason)")
        #expect(!(error is GestureNotSent))
        #expect(hands.writes.withLock { $0 } == [kAXMainAttribute], "AXFocused is a new effect the stop refuses")
        #expect(delivery.sent.withLock { $0 }.isEmpty, "nothing replayed on rung 2")
        #expect(actuator.lastDelivery(in: 9)?.how.contains("uncertain") == true)
    }

    // MARK: The live sequences

    @Test("focus: a stop before AXMain writes nothing; after it, AXFocused is not written and the answer is uncertain")
    func liveFocusSequence() async throws {
        let writes = Log()
        let main   : @Sendable () -> AXError = { writes.add("main"); return .success }
        let focused: @Sendable () -> AXError = { writes.add("focused"); return .success }

        let before = await Self.run {
            Self.stopNow()
            try LiveMacTreeReader.focus(settingMain: main, thenFocused: focused)
        }
        #expect(before is CancellationError && writes.all.isEmpty)

        let between = await Self.run {
            try LiveMacTreeReader.focus(settingMain: { let answer = main(); Self.stopNow(); return answer },
                                        thenFocused: focused)
        }
        guard case .uncertain? = between as? MacTreeFailure else {
            Issue.record("not uncertain: \(String(describing: between))")
            return
        }
        #expect(writes.all == ["main"])

        writes.clear()
        #expect(await Self.run { try LiveMacTreeReader.focus(settingMain: main, thenFocused: focused) } == nil)
        #expect(writes.all == ["main", "focused"])
    }

    @Test("select: a stop before the write writes nothing, whichever way was chosen")
    func liveSelectStops() async throws {
        for settable in [["row": Set([kAXSelectedAttribute])], ["table": Set([kAXSelectedRowsAttribute])]] {
            let (error, writes) = await Task { () async -> ((any Error)?, [String]) in
                let tree = MacRungTests.FakeSelection()
                tree.settable = settable
                Self.stopNow()
                do {
                    try LiveMacTreeReader.select("row", in: "table", containerRole: kAXTableRole, through: tree)
                    return (nil, tree.writes)
                } catch {
                    return (error, tree.writes)
                }
            }.value
            #expect(error is CancellationError && writes.isEmpty, "\(settable)")
        }
    }
}
