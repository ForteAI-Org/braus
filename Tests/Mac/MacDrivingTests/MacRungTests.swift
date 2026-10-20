import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
@testable import MacDriver
@testable import MacDriving
import Synchronization
import Testing

/// FakeDelivery records rung 2's gestures, or refuses them as a build the ledger does not list.
final class FakeDelivery: MacEventDelivering {

    let refuses: Bool
    /// Whether the key-window records stay applied after the events went out.
    let leavesPreparation: Bool
    /// What delivering does besides, such as the app activating itself.
    let onDeliver: (@Sendable () -> Void)?
    let sent = Mutex<[(gesture: Gesture, window: Int, keyWindow: Bool)]>([])

    init(refuses: Bool = false, leavesPreparation: Bool = false, onDeliver: (@Sendable () -> Void)? = nil) {
        self.refuses           = refuses
        self.leavesPreparation = leavesPreparation
        self.onDeliver         = onDeliver
    }

    func deliver(
        _ gesture     : Gesture,
        toWindow windowNumber: Int,
        of processID  : pid_t,
        needsKeyWindow: Bool
    ) async throws -> MacEventReceipt {
        onDeliver?()
        if refuses { throw MacActuationFailure.refused("mode 2 refused on this build") }
        sent.withLock { $0.append((gesture, windowNumber, needsKeyWindow)) }
        return MacEventReceipt(preparationNotRestored: leavesPreparation && needsKeyWindow)
    }
}

/// The ladder on a small built window: which rung each gesture takes and why, the fallbacks, the
/// stale and uncertain cases, and the settler's rule.
@Suite("MacDriver rungs 1 and 2")
struct MacRungTests {

    static let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A window with a button, a disabled menu item, a field, a check box without AXPress, a row inside
    /// an outline in a scroll area, a group holding one button, and a text.
    static let window: MacTreeNode = Trees.window("Prova", frame, children: [
        MacTreeNode(role: "AXButton", title: "OK", frame: CGRect(x: 10, y: 10, width: 60, height: 20), actions: ["AXPress"]),
        MacTreeNode(role: "AXMenuItem", title: "Nuova cartella", isEnabled: false, frame: CGRect(x: 80, y: 10, width: 60, height: 20),
                    actions: ["AXPress"]),
        MacTreeNode(role: "AXTextField", descriptionText: "Nome", frame: CGRect(x: 10, y: 40, width: 200, height: 20)),
        MacTreeNode(role: "AXCheckBox", title: "Muto", frame: CGRect(x: 220, y: 40, width: 60, height: 20)),
        MacTreeNode(role: "AXScrollArea", frame: CGRect(x: 10, y: 70, width: 200, height: 100), actions: ["AXScrollDownByPage"],
                    children: [MacTreeNode(role: "AXOutline", frame: CGRect(x: 10, y: 70, width: 200, height: 100), children: [
                        MacTreeNode(role: "AXRow", isSelected: false, frame: CGRect(x: 10, y: 70, width: 200, height: 20), children: [
                            MacTreeNode(role: "AXCell", frame: CGRect(x: 10, y: 70, width: 200, height: 20), children: [
                                MacTreeNode(role: "AXStaticText", value: "Suono", frame: CGRect(x: 15, y: 72, width: 60, height: 16)),
                            ]),
                        ]),
                    ])]),
        MacTreeNode(role: "AXGroup", frame: CGRect(x: 220, y: 70, width: 150, height: 60), children: [
            MacTreeNode(role: "AXStaticText", value: "Volume", frame: CGRect(x: 225, y: 75, width: 60, height: 16)),
            MacTreeNode(role: "AXButton", title: "Alza", frame: CGRect(x: 300, y: 100, width: 60, height: 20), actions: ["AXPress"]),
        ]),
        MacTreeNode(role: "AXStaticText", value: "Fine", frame: CGRect(x: 10, y: 200, width: 60, height: 16)),
    ])

    private func plan(_ gesture: Gesture) -> MacRungPlan {
        MacRungPlanner.plan(gesture, at: MacActuator.point(of: gesture), in: Self.window)
    }

    // MARK: Planner

    @Test("A button is pressed; a field is focused; a row is selected from its text")
    func rungOne() {
        #expect(plan(.click(at: CGPoint(x: 20, y: 20))) == .accessibility(.perform("AXPress", on: Self.window.children[0])))
        #expect(plan(.click(at: CGPoint(x: 50, y: 50))) == .accessibility(.focus(Self.window.children[2])))
        let row = Self.window.children[4].children[0].children[0]
        #expect(plan(.click(at: CGPoint(x: 20, y: 78))) == .accessibility(.select(row)))
    }

    @Test("A click on a group or its text goes to the group's one actionable element")
    func passThrough() {
        let button = Self.window.children[5].children[1]
        #expect(plan(.click(at: CGPoint(x: 230, y: 80))) == .accessibility(.perform("AXPress", on: button)))
    }

    @Test("Rung 2 with its reason: a disabled menu item needs the key window, an unlisted press does not")
    func rungTwo() {
        #expect(plan(.click(at: CGPoint(x: 90, y: 20))) == .events(reason: "menu item disabled", needsKeyWindow: true))
        #expect(plan(.click(at: CGPoint(x: 230, y: 50))) == .events(reason: "AXCheckBox lists no AXPress", needsKeyWindow: false))
        #expect(plan(.click(at: CGPoint(x: 20, y: 205))) == .events(reason: "AXStaticText lists no AXPress", needsKeyWindow: false))
    }

    @Test("Right and double clicks, keys and text go to rung 2; a drag is refused")
    func notOnRungOne() {
        #expect(plan(.click(at: CGPoint(x: 20, y: 20), button: .right)) == .events(reason: "right click: AXShowMenu brings the app to the front", needsKeyWindow: false))
        #expect(plan(.click(at: CGPoint(x: 20, y: 20), count: 2)) == .events(reason: "a 2-click has no accessibility action", needsKeyWindow: false))
        #expect(plan(.type("ciao")) == .events(reason: "keys have no accessibility action: posted to the process", needsKeyWindow: true))
        #expect(plan(.drag(from: .zero, to: CGPoint(x: 5, y: 5))) == .refused("a drag needs the seat (mode 1)"))
    }

    @Test("A scroll pages the scroll area under the point, in the gesture's direction")
    func scroll() {
        let area = Self.window.children[4]
        #expect(plan(.scroll(at: CGPoint(x: 20, y: 78), deltaY: -3)) == .accessibility(.scroll(area, .down)))
        #expect(plan(.scroll(at: CGPoint(x: 20, y: 78), deltaY: 3)) == .accessibility(.scroll(area, .up)))
        #expect(plan(.scroll(at: CGPoint(x: 20, y: 20), deltaY: 3)) == .events(reason: "no scroll area under the point", needsKeyWindow: false))
    }

    // MARK: Actuator

    private func actuator(reader: FakeTreeReader, delivery: FakeDelivery, number: Int = 77) -> MacActuator {
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: Self.window, windowIndex: 0, windowNumber: number), for: 9)
        return MacActuator(cache: cache, actor: reader, delivery: delivery, person: nil)
    }

    private func reader(_ failure: MacTreeFailure? = nil, tree: MacTreeNode = window) -> FakeTreeReader {
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: Self.frame, isFocused: true)
        return FakeTreeReader(windows: [9: [(summary, tree)]], performFailure: failure)
    }

    @Test("Rung 1 runs and is noted; nothing goes to rung 2")
    func actuatorRungOne() async throws {
        let reader = reader()
        let delivery = FakeDelivery()
        let actuator = actuator(reader: reader, delivery: delivery)
        try await actuator.perform(.click(at: CGPoint(x: 20, y: 78)), in: 9)
        #expect(reader.steps.withLock { $0 } == ["select [4, 0, 0]"])
        #expect(actuator.lastDelivery(in: 9) == MacDeliveryNote(rung: .accessibility, how: "selected AXRow", skipped: []))
        #expect(delivery.sent.withLock { $0 }.isEmpty)
        await actuator.confirm(.observed, in: 9)
        #expect(actuator.lastDelivery(in: 9)?.effect == .observed)
    }

    @Test("A field clicked on rung 1 is only focused, so the engine is told posted and still moves to its end")
    func focusedFieldKeepsTheEndOfFieldKey() async throws {
        let reader = reader()
        let actuator = actuator(reader: reader, delivery: FakeDelivery())
        try await actuator.perform(.click(at: CGPoint(x: 50, y: 50)), in: 9)
        #expect(actuator.lastDelivery(in: 9)?.rung == .accessibility)
        #expect(actuator.lastDelivery(in: 9)?.how == "focused AXTextField")
        #expect(await actuator.lastDeliveryRoute(in: 9) == .posted,
                "an accessibility route would make the engine skip Command-Down after a focus that placed no caret")
    }

    @Test("Rung 1 refused before acting falls to rung 2 with the reason")
    func fallsToRungTwo() async throws {
        let delivery = FakeDelivery()
        let actuator = actuator(reader: reader(.actionNotListed("AXPress")), delivery: delivery)
        try await actuator.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        #expect(delivery.sent.withLock { $0.map(\.window) } == [77])
        #expect(actuator.lastDelivery(in: 9) == MacDeliveryNote(rung: .inPlace, how: "events to the process", skipped: ["element has no AXPress"]))
    }

    @Test("An uncertain rung 1 is never replayed on rung 2")
    func uncertainNotReplayed() async throws {
        let delivery = FakeDelivery()
        let actuator = actuator(reader: reader(.uncertain("AXPress: the app did not answer in time")), delivery: delivery)
        await #expect(throws: MacActuationFailure.uncertain("AXPress: the app did not answer in time")) {
            try await actuator.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
        #expect(delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("Rung 1's accessibility calls leave the main actor when the caller is on it", arguments: [
        Gesture.click(at: CGPoint(x: 20, y: 20)),
        .click(at: CGPoint(x: 50, y: 50)),
        .click(at: CGPoint(x: 20, y: 78)),
        .scroll(at: CGPoint(x: 20, y: 78), deltaY: -3),
    ])
    @MainActor
    func offMainActor(_ gesture: Gesture) async throws {
        let reader = reader()
        let actuator = actuator(reader: reader, delivery: FakeDelivery())
        try await actuator.perform(gesture, in: 9)
        #expect(reader.onMainThread.withLock { $0 } == [false])
        #expect(actuator.lastDelivery(in: 9)?.rung == .accessibility)
    }

    @Test("An app that does not answer in time is uncertain on the main actor too, and never replayed")
    @MainActor
    func uncertainOffMainActor() async throws {
        let reader = reader(.uncertain("AXPress: the app did not answer in time"))
        let delivery = FakeDelivery()
        let actuator = actuator(reader: reader, delivery: delivery)
        await #expect(throws: MacActuationFailure.uncertain("AXPress: the app did not answer in time")) {
            try await actuator.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
        #expect(reader.onMainThread.withLock { $0 } == [false])
        #expect(delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("A target whose live element changed is stale: nothing is sent")
    func stale() async throws {
        let live = Trees.window("Prova", Self.frame, children: [
            MacTreeNode(role: "AXButton", title: "Annulla", frame: CGRect(x: 10, y: 10, width: 60, height: 20), actions: ["AXPress"]),
        ])
        let reader = reader(tree: live)
        let delivery = FakeDelivery()
        await #expect(throws: try #require(MacActuationFailure.staleTarget([0]).notSent)) {
            try await actuator(reader: reader, delivery: delivery).perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
        #expect(reader.steps.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("Keys go to rung 2 with the key-window records; a refused build throws")
    func keys() async throws {
        let delivery = FakeDelivery()
        let actuator = actuator(reader: reader(), delivery: delivery)
        try await actuator.perform(.type("ciao"), in: 9)
        #expect(delivery.sent.withLock { $0.map(\.keyWindow) } == [true])
        await #expect(throws: try #require(MacActuationFailure.refused("mode 2 refused on this build").notSent)) {
            try await self.actuator(reader: reader(), delivery: FakeDelivery(refuses: true)).perform(.type("x"), in: 9)
        }
    }

    @Test("R06: an error the app answered to rung 1's request is uncertain and never replayed on rung 2")
    func failedRequestIsUncertain() async throws {
        let delivery = FakeDelivery()
        let failed = actuator(reader: reader(.actionFailed("AXPress answered -25205")), delivery: delivery)
        await #expect(throws: MacActuationFailure.uncertain("AXPress answered -25205")) {
            try await failed.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
        #expect(delivery.sent.withLock { $0 }.isEmpty, "no events on rung 2")
        let unlisted = actuator(reader: reader(.actionNotListed("AXPress")), delivery: FakeDelivery(), number: 0)
        await #expect(throws: MacActuationFailure.uncertain("element has no AXPress, then rung 2 refused: "
                                                            + "rung 2 needs the window's server number; none matched its frame")) {
            try await unlisted.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
    }

    @Test("R06: an app that acts on rung 1's request and still answers an error gets no events on rung 2")
    func actedThenFailedIsNotReplayed() async throws {
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: Self.frame, isFocused: true)
        let failure = LiveMacTreeReader.failure(after: .attributeUnsupported, doing: "AXPress")
        let reader = FakeTreeReader(windows: [9: [(summary, Self.window)]], failureAfterActing: failure)
        let delivery = FakeDelivery()
        let acted = actuator(reader: reader, delivery: delivery)
        await #expect(throws: MacActuationFailure.self) {
            try await acted.perform(.click(at: CGPoint(x: 20, y: 20)), in: 9)
        }
        #expect(reader.steps.withLock { $0 }.count == 1, "the request went out once and took effect")
        #expect(delivery.sent.withLock { $0 }.isEmpty, "zero events on rung 2")
        #expect(acted.lastDelivery(in: 9)?.how.contains("uncertain") == true)
    }

    @Test("R06: every error the app answers once a request reached it is uncertain; success is nothing")
    func errorsAfterTheRequest() {
        #expect(LiveMacTreeReader.failure(after: .success, doing: "AXPress") == nil)
        for error in [AXError.attributeUnsupported, .actionUnsupported, .failure, .illegalArgument, .cannotComplete] {
            guard case .uncertain? = LiveMacTreeReader.failure(after: error, doing: "AXPress") else {
                Issue.record("\(error.rawValue) is not uncertain")
                continue
            }
        }
    }

    /// FakeSelection is a tree whose elements say which attributes they let set, and answer each write with a
    /// scripted error after applying it; it keeps every write.
    final class FakeSelection: SelectionWriting {
        var settable: [String: Set<String>] = [:]
        var answers : [String: AXError] = [:]
        private(set) var writes: [String] = []

        func isSettable(_ element: String, _ attribute: String) -> Bool {
            settable[element]?.contains(attribute) == true
        }

        func setSelected(_ element: String) -> AXError {
            writes.append("\(element).\(kAXSelectedAttribute)")
            return answers[element] ?? .success
        }

        func setSelection(_ elements: [String], of container: String, attribute: String) -> AXError {
            writes.append("\(container).\(attribute)")
            return answers[container] ?? .success
        }
    }

    @Test("R06: a row lets AXSelected be set, applies it and answers unsupported: uncertain, no write to its container")
    func selectedThenUnsupported() {
        let tree = FakeSelection()
        tree.settable = ["row": [kAXSelectedAttribute], "table": [kAXSelectedRowsAttribute]]
        tree.answers = ["row": .attributeUnsupported]
        var thrown: MacTreeFailure?
        do { try LiveMacTreeReader.select("row", in: "table", containerRole: kAXTableRole, through: tree) } catch {
            thrown = error as? MacTreeFailure
        }
        guard case .uncertain? = thrown else {
            Issue.record("not uncertain: \(String(describing: thrown))")
            return
        }
        #expect(tree.writes == ["row.\(kAXSelectedAttribute)"], "one write, never a second one to the container")
    }

    @Test("R06: the way is chosen before writing: the row's own AXSelected, else its container's, else nothing")
    func selectionWayChosenFirst() throws {
        let own = FakeSelection()
        own.settable = ["row": [kAXSelectedAttribute], "table": [kAXSelectedRowsAttribute]]
        try LiveMacTreeReader.select("row", in: "table", containerRole: kAXTableRole, through: own)
        #expect(own.writes == ["row.\(kAXSelectedAttribute)"])

        let table = FakeSelection()
        table.settable = ["table": [kAXSelectedRowsAttribute]]
        try LiveMacTreeReader.select("row", in: "table", containerRole: kAXTableRole, through: table)
        #expect(table.writes == ["table.\(kAXSelectedRowsAttribute)"])

        let list = FakeSelection()
        list.settable = ["list": [kAXSelectedChildrenAttribute]]
        try LiveMacTreeReader.select("item", in: "list", containerRole: kAXListRole, through: list)
        #expect(list.writes == ["list.\(kAXSelectedChildrenAttribute)"])

        let neither = FakeSelection()
        #expect(throws: MacTreeFailure.self) {
            try LiveMacTreeReader.select("row", in: "table", containerRole: kAXTableRole, through: neither)
        }
        #expect(neither.writes.isEmpty, "nothing settable, nothing written: refused before any request")
    }

    @Test("Key-window records not taken back after the events went out are reported once, never thrown")
    func unrestoredPreparationIsReported() async throws {
        let delivery = FakeDelivery(leavesPreparation: true)
        let actuator = actuator(reader: reader(), delivery: delivery)
        try await actuator.perform(.type("ciao"), in: 9)
        #expect(delivery.sent.withLock { $0.count } == 1, "delivered once")
        #expect(actuator.lastDelivery(in: 9)?.preparationNotRestored == true)
        #expect(actuator.takeUnrestoredPreparation(in: 9))
        #expect(!actuator.takeUnrestoredPreparation(in: 9), "taken once")
        try await actuator.perform(.type("x"), in: 9)
        #expect(actuator.takeUnrestoredPreparation(in: 9), "each gesture reports its own")
        let restored = self.actuator(reader: reader(), delivery: FakeDelivery())
        try await restored.perform(.type("ciao"), in: 9)
        #expect(!restored.takeUnrestoredPreparation(in: 9))
        #expect(restored.lastDelivery(in: 9)?.preparationNotRestored == false)
    }

    @Test("Rung 2 without the window's server number refuses; without a scene nothing happens")
    func noWindowNumber() async throws {
        await #expect(throws: try #require(MacActuationFailure.refused("rung 2 needs the window's server number; none matched its frame").notSent)) {
            try await actuator(reader: reader(), delivery: FakeDelivery(), number: 0).perform(.type("x"), in: 9)
        }
        let empty = MacActuator(cache: MacSceneCache(), actor: reader(), delivery: FakeDelivery(), person: nil)
        await #expect(throws: try #require(MacActuationFailure.noScene.notSent)) { try await empty.perform(.type("x"), in: 9) }
    }

    // MARK: The person first

    final class FakePerson: MacPersonWatching {
        let touch: ContinuousClock.Instant?
        let isWatching = true
        init(_ touch: ContinuousClock.Instant?) { self.touch = touch }
        func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? { touch }
    }

    private func actuator(readAt: ContinuousClock.Instant, touch: ContinuousClock.Instant?, delivery: FakeDelivery) -> MacActuator {
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: Self.window, windowIndex: 0, windowNumber: 77, readAt: readAt), for: 9)
        return MacActuator(cache: cache, actor: reader(), delivery: delivery, person: FakePerson(touch))
    }

    @Test("The person's input after the scene was read refuses the gesture; input before it does not")
    func personFirst() async throws {
        let read = ContinuousClock.now
        let delivery = FakeDelivery()
        await #expect(throws: try #require(MacActuationFailure.personActed.notSent)) {
            try await actuator(readAt: read, touch: read + .milliseconds(5), delivery: delivery).perform(.type("x"), in: 9)
        }
        #expect(delivery.sent.withLock { $0 }.isEmpty)
        try await actuator(readAt: read, touch: read - .milliseconds(5), delivery: delivery).perform(.type("x"), in: 9)
        try await actuator(readAt: read, touch: nil, delivery: delivery).perform(.type("y"), in: 9)
        #expect(delivery.sent.withLock { $0.count } == 2)
    }

    // MARK: The person's front app

    static let personApp = MacRunningApp(processID: 99, bundleID: "com.example.person", name: "Person")
    static let app = MacRunningApp(processID: 9, bundleID: "com.example.app", name: "App")

    /// An actuator guarding the front app, whose rung 2 makes the app activate itself when `activates`.
    private func guarded(_ workspace: FakeWorkspace, activates: Bool = true, personActs: Bool = false,
                         refuses: Bool = false) -> MacActuator {
        let delivery = FakeDelivery(refuses: refuses) {
            guard activates else { return }
            workspace.state.withLock { $0.front = Self.app }
            if personActs { workspace.personActsNow() }
        }
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: Self.window, windowIndex: 0, windowNumber: 77), for: 9)
        return MacActuator(cache: cache, actor: reader(), delivery: delivery, person: nil, focus: workspace)
    }

    private func workspace() -> FakeWorkspace {
        FakeWorkspace(apps: [], front: Self.personApp, running: [Self.personApp, Self.app])
    }

    @Test("An app that activated itself during a gesture is sent back behind the person's app")
    func selfActivationRestored() async throws {
        let workspace = workspace()
        let actuator = guarded(workspace)
        try await actuator.perform(.type("x"), in: 9)
        let focus = try #require(actuator.takeFocus(in: 9))
        #expect(focus.selfActivated && focus.focusRestored && !focus.personActed && !focus.leftInFront)
        #expect(workspace.state.withLock { $0.activations } == [Self.personApp.processID])
        #expect(await workspace.frontmost() == Self.personApp)
        #expect(actuator.takeFocus(in: 9) == nil)
    }

    @Test("A gesture that leaves the front alone activates nothing")
    func noSelfActivation() async throws {
        let workspace = workspace()
        let actuator = guarded(workspace, activates: false)
        try await actuator.perform(.type("x"), in: 9)
        let focus = try #require(actuator.takeFocus(in: 9))
        #expect(!focus.selfActivated && !focus.leftInFront)
        #expect(workspace.state.withLock { $0.activations }.isEmpty)
    }

    @Test("When the person acted meanwhile their front is left as they set it, and nothing is left in front")
    func personActedKeepsTheirFront() async throws {
        let workspace = workspace()
        let actuator = guarded(workspace, personActs: true)
        try await actuator.perform(.type("x"), in: 9)
        let focus = try #require(actuator.takeFocus(in: 9))
        #expect(focus.selfActivated && focus.personActed && !focus.focusRestored && !focus.leftInFront)
        #expect(workspace.state.withLock { $0.activations }.isEmpty)
    }

    @Test("An app that stays in front is reported left in front")
    func leftInFront() async throws {
        let workspace = workspace()
        workspace.state.withLock { $0.ignoresActivation = true }
        let actuator = guarded(workspace)
        try await actuator.perform(.type("x"), in: 9)
        #expect(actuator.takeFocus(in: 9)?.leftInFront == true)
    }

    @Test("A gesture that fails still gives the person's app back")
    func failedGestureRestores() async throws {
        let workspace = workspace()
        let actuator = guarded(workspace, refuses: true)
        await #expect(throws: GestureNotSent.self) { try await actuator.perform(.type("x"), in: 9) }
        #expect(actuator.takeFocus(in: 9)?.focusRestored == true)
        #expect(await workspace.frontmost() == Self.personApp)
    }

    // MARK: Settler

    @Test("Settled 150 ms after the last notification, at once without any, and at the cap")
    func settleRule() {
        let start = ContinuousClock.now
        #expect(!MacSettler.isSettled(started: start, last: nil, now: start + .milliseconds(100), cap: .seconds(2)))
        #expect(MacSettler.isSettled(started: start, last: nil, now: start + .milliseconds(150), cap: .seconds(2)))
        let last = start + .milliseconds(400)
        #expect(!MacSettler.isSettled(started: start, last: last, now: start + .milliseconds(500), cap: .seconds(2)))
        #expect(MacSettler.isSettled(started: start, last: last, now: start + .milliseconds(560), cap: .seconds(2)))
        #expect(MacSettler.isSettled(started: start, last: start + .milliseconds(1990), now: start + .seconds(2), cap: .seconds(2)))
        // A notification from before the gesture does not count.
        #expect(MacSettler.isSettled(started: start, last: start - .milliseconds(10), now: start + .milliseconds(150), cap: .seconds(2)))
    }

    @Test("A wait answers capped only when it reached the cap with the app still notifying; settled otherwise")
    func settleResult() {
        let start = ContinuousClock.now
        let cap = Duration.seconds(2)
        #expect(MacSettler.result(started: start, last: nil, now: start + .milliseconds(150), cap: cap) == .settled)
        #expect(MacSettler.result(started: start, last: start + .milliseconds(400), now: start + .milliseconds(560), cap: cap)
                == .settled)
        #expect(MacSettler.result(started: start, last: start + .milliseconds(1990), now: start + .seconds(2), cap: cap)
                == .capped)
        #expect(MacSettler.result(started: start, last: start + .milliseconds(1700), now: start + .seconds(2), cap: cap)
                == .settled, "the last notification was quiet for longer than 150 ms at the cap")
        #expect(MacSettler.result(started: start, last: start - .milliseconds(10), now: start + .seconds(2), cap: cap)
                == .settled, "a notification from before the gesture does not count")
    }
}
