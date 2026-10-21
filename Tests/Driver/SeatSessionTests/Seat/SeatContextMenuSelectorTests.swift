import CoreGraphics
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCore
@testable import SeatDriving
@testable import SeatSession
import Testing

/// The consumer composes the real scoped Driver interaction with identity-bound perception.
/// Controlled surfaces prove admission, cleanup and verdicts; native app effects need live repeats.
@MainActor
@Suite("Seat contextual menu selection")
struct SeatContextMenuSelectorTests {

    enum Rows: Sendable { case unique, absent, ambiguous, disabled }

    actor Reads {
        var windows: [Int] = []
        func record(_ number: Int) { windows.append(number) }
    }

    struct EmptyText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) -> [RecognizedText] { [] }
    }

    struct NativeFacts: SceneAugmenting {
        let rows: Rows
        let reads: Reads

        func augmentation(for processID: pid_t, windowFrame: CGRect) -> AccessibilityHarvest { .none }

        func augmentation(for processID: pid_t, windowNumber: Int, windowFrame: CGRect) async -> AccessibilityHarvest {
            AccessibilityHarvest(elements: await elements(windowNumber: windowNumber), quality: .unknown)
        }

        private func elements(windowNumber: Int) async -> [SceneElement] {
            await reads.record(windowNumber)
            if windowNumber != FakeGeometry.menuWindowNumber {
                return [SceneElement(
                    id: "field", kind: .control, label: "Probe Text",
                    bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1), role: "AXTextField"
                ), SceneElement(
                    id: "button", kind: .control, label: "Probe Button",
                    bounds: NormalizedRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1), role: "AXButton"
                )]
            }
            guard rows != .absent else { return [] }
            let first = SceneElement(
                id: "select", kind: .control, label: "Select All",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.3), role: "AXMenuItem",
                isEnabled: rows != .disabled
            )
            guard rows == .ambiguous else { return [first] }
            let second = SceneElement(
                id: "other-select", kind: .control, label: "Select All",
                bounds: NormalizedRect(x: 0.1, y: 0.6, width: 0.6, height: 0.3), role: "AXMenuItem"
            )
            return [first, second]
        }
    }

    private let identity = SeatDriving.ApplicationIdentity(bundleID: "test.menu", name: "Controlled app")

    private func selector(seat: AgentSeat, rows: Rows = .unique, reads: Reads = Reads()) -> SeatContextMenuSelector {
        SeatContextMenuSelector(
            target: SeatTarget(borrowing: SeatHost(), seat: seat),
            pipeline: ScenePipeline(text: EmptyText(), augmentation: NativeFacts(rows: rows, reads: reads))
        )
    }

    @Test("one right click opens the menu, and its own observation admits the item click")
    func selectionUsesMenuAuthority() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let reads = Reads()
        let outcome = try await selector(seat: c.seat, reads: reads).select(item: "Select All", on: "field", identity: identity)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("chosenItem"))
        #expect(outcome.message.contains("effect remains unverified"))
        #expect(c.sender.sent.count == 2)
        #expect(c.sender.addressed.map { $0.0.windowNumber } == [c.window.reference.windowNumber, FakeGeometry.menuWindowNumber])
        if case .click(_, .right, _) = c.sender.sent.first?.0 {} else { Issue.record("missing single opening click") }
        if case .click(_, .left, _) = c.sender.sent.last?.0 {} else { Issue.record("missing menu item click") }
        #expect(await reads.windows.contains(FakeGeometry.menuWindowNumber))
        #expect(c.source.requested.contains { $0.windowNumber == FakeGeometry.menuWindowNumber })
        #expect(c.sensing.menus.isEmpty)
        #expect(outcome.scene?.windowTitle == c.window.title)
        let next = try await c.seat.acquire()
        try c.seat.release(next)
    }

    @Test("a missing, ambiguous or disabled menu item is withdrawn without any choice", arguments: [Rows.absent, .ambiguous, .disabled])
    func noUniqueEnabledItem(rows: Rows) async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat, rows: rows).select(item: "Select All", on: "field", identity: identity)
        #expect(outcome.kind == .honestMiss)
        #expect(outcome.message.contains("preparationCycle"))
        #expect(c.sender.sent.count == 1)
        #expect(c.sensing.menus.isEmpty)
        let next = try await c.seat.acquire()
        try c.seat.release(next)
    }

    @Test("an item named by the start of its title is chosen, and a miss names what the menu holds")
    func itemByItsStartAndMissListing() async throws {
        let chosen = try await ContextMenuTests.ready()
        try chosen.seat.release(chosen.turn)
        let outcome = try await selector(seat: chosen.seat).select(item: "Select", on: "field", identity: identity)
        #expect(outcome.message.contains("requested 'Select All'"), Comment(rawValue: outcome.message))
        #expect(chosen.sender.sent.count == 2)

        let missed = try await ContextMenuTests.ready()
        try missed.seat.release(missed.turn)
        let miss = try await selector(seat: missed.seat).select(item: "Compress", on: "field", identity: identity)
        #expect(miss.kind == .honestMiss)
        #expect(miss.message.contains("It holds: Select All"), Comment(rawValue: miss.message))
    }

    @Test("destructive menu choices refuse before opening")
    func destructiveChoiceRefuses() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat).select(item: "Delete", on: "field", identity: identity)
        #expect(outcome.kind == .refused)
        #expect(c.sender.sent.isEmpty)
        #expect(c.sensing.menus.isEmpty)
    }

    @Test("R07: a destructive menu choice the person allowed is still refused: the seat cannot read its effect back")
    func destructiveChoiceWithoutReadBack() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat).select(
            item: "Delete", on: "field", identity: identity, permissions: ActionPermissions(allowsDestructive: true)
        )
        #expect(outcome.kind == .refused && outcome.message.contains("cannot read its effect back"),
                Comment(rawValue: outcome.message))
        #expect(c.sender.sent.isEmpty)
        #expect(c.sensing.menus.isEmpty)
    }

    @Test("Qt's text-field-only restriction survives the scoped menu route")
    func nonFieldRefuses() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat).select(
            item: "Select All", on: "button", identity: identity,
            permissions: ActionPermissions(contextMenusOnTextFieldsOnly: true)
        )
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("outside the Seat"), Comment(rawValue: outcome.message))
        #expect(c.sender.sent.isEmpty)
        #expect(c.sensing.menus.isEmpty)
    }

    // The native route needs a live accessibility tree the fakes cannot provide: the decision is covered here.
    @Test("where menus open under the pointer, a non-text opener needs its own Show Menu action")
    func routeByOpener() {
        #expect(SeatContextMenuSelector.route(opener: "AXButton", textFieldsOnly: false, offersShowMenu: { true }) == .pointer)
        #expect(SeatContextMenuSelector.route(opener: "AXTextField", textFieldsOnly: true, offersShowMenu: { false }) == .pointer)
        #expect(SeatContextMenuSelector.route(opener: "AXPopUpButton", textFieldsOnly: true, offersShowMenu: { true }) == .native)
        #expect(SeatContextMenuSelector.route(opener: "AXButton", textFieldsOnly: true, offersShowMenu: { false }) == .refused)
        #expect(SeatContextMenuSelector.route(opener: nil, textFieldsOnly: true, offersShowMenu: { false }) == .refused)
    }

    @Test("a destructive item refuses before any native menu route is considered")
    func destructiveRefusesUnderTextFieldsOnly() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat).select(
            item: "Delete", on: "button", identity: identity,
            permissions: ActionPermissions(contextMenusOnTextFieldsOnly: true)
        )
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("--allow-destructive"))
        #expect(c.sender.sent.isEmpty)
        #expect(c.sensing.menus.isEmpty)
    }

    @Test("a rehearsal observes without opening a menu")
    func dryRun() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let outcome = try await selector(seat: c.seat).select(item: "Select All", on: "field", identity: identity, dryRun: true)
        #expect(outcome.kind == .dryRun)
        #expect(c.sender.sent.isEmpty)
    }

    @Test("unqualified menu capture closes the menu without parent input or replay")
    func captureRefusalCleansUp() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        c.source.supported.remove(.menuSurfaceStill)
        let outcome = try await selector(seat: c.seat).select(item: "Select All", on: "field", identity: identity)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("capabilityUnqualified"))
        #expect(outcome.message.contains("preparationCycle"))
        #expect(c.sender.sent.count == 1)
        #expect(c.sensing.menus.isEmpty)
    }

    @Test("an item delivery refusal cleans up and does not replay either click")
    func deliveryRefusalCleansUp() async throws {
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        c.sender.refusedCommand = { command in
            if case .click(_, .left, _) = command { return SeatDrivingFailure.gestureUnsupported("controlled refusal") }
            return nil
        }
        let outcome = try await selector(seat: c.seat).select(item: "Select All", on: "field", identity: identity)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("controlled refusal"))
        #expect(outcome.message.contains("preparationCycle"))
        #expect(c.sender.sent.count == 1)
        #expect(c.sensing.menus.isEmpty)
        let next = try await c.seat.acquire()
        try c.seat.release(next)
    }

    @Test("M05 CM-2: the real selector returns the Seat's outcome it used to drop, and the session's hand-over writes the last receipt of it: the row's click when chosen, the opener's when the item was missing or its delivery refused, nothing when refused before the Seat was asked; nothing replayed, the item's word nowhere")
    func receiptReachesTheRecord() async throws {
        let record = try ContextMenuRecord(secret: "Select All")
        let (task, producer, attribution) = try await record.beginTask()
        func send(_ receipt: InputReceipt) -> CallRung { record.expected(receipt) }

        // The row chosen: the opener and one click inside the menu; the row's click is the rung.
        let c = try await ContextMenuTests.ready()
        try c.seat.release(c.turn)
        let chosen = try await selector(seat: c.seat).selectWithReceipt(item: "Select All", on: "field", identity: identity)
        #expect(chosen.outcome.kind == .actedUnverified && chosen.receipt?.insideMenu.count == 1 && c.sender.sent.count == 2)
        let first = try await record.contextMenu(chosen.receipt, attribution: attribution)
        #expect(try await record.rung(of: first) == send(try #require(chosen.receipt?.insideMenu.last)))
        #expect(try await record.attribution(of: first) == attribution)

        // The item missing: the menu opened and withdrawn, no click inside; the opener's is the rung.
        let m = try await ContextMenuTests.ready()
        try m.seat.release(m.turn)
        let missing = try await selector(seat: m.seat, rows: .absent).selectWithReceipt(item: "Select All", on: "field", identity: identity)
        #expect(missing.outcome.kind == .honestMiss && missing.receipt?.insideMenu.isEmpty == true && m.sender.sent.count == 1)
        let second = try await record.contextMenu(missing.receipt, attribution: attribution)
        #expect(try await record.rung(of: second) == send(try #require(missing.receipt?.opening)))
        try await record.endTask(task, producer)

        // The row's delivery refused: the opener went out, the row's click never did; the opener's is the rung, the
        // outcome unverified as today, under no task now.
        let r = try await ContextMenuTests.ready()
        try r.seat.release(r.turn)
        r.sender.refusedCommand = { command in
            if case .click(_, .left, _) = command { return SeatDrivingFailure.gestureUnsupported("controlled refusal") }
            return nil
        }
        let refused = try await selector(seat: r.seat).selectWithReceipt(item: "Select All", on: "field", identity: identity)
        #expect(refused.outcome.kind == .actedUnverified && refused.receipt?.insideMenu.isEmpty == true && r.sender.sent.count == 1)
        let third = try await record.contextMenu(refused.receipt)
        #expect(try await record.rung(of: third) == send(try #require(refused.receipt?.opening)))
        #expect(try await record.attribution(of: third) == nil)

        // Refused before the Seat was asked: a dry run, and a control the scene lacks; no outcome from the Seat, no
        // command, no rung.
        let p = try await ContextMenuTests.ready()
        try p.seat.release(p.turn)
        let rehearsed = try await selector(seat: p.seat).selectWithReceipt(item: "Select All", on: "field", identity: identity, dryRun: true)
        let unresolved = try await selector(seat: p.seat).selectWithReceipt(item: "Select All", on: "nothing here", identity: identity)
        #expect(rehearsed.outcome.kind == .dryRun && rehearsed.receipt == nil && unresolved.outcome.kind == .honestMiss
                && unresolved.receipt == nil && p.sender.sent.isEmpty)
        let fourth = try await record.contextMenu(rehearsed.receipt)
        let fifth  = try await record.contextMenu(unresolved.receipt)
        let fourthRung = try await record.rung(of: fourth)
        let fifthRung  = try await record.rung(of: fifth)
        #expect(fourthRung == nil && fifthRung == nil)

        let ids = try await record.callIDs()
        #expect(ids.count == 5 && Set(ids) == Set([first, second, third, fourth, fifth]))
        try await record.expectSecretNowhere()
        for context in [c, m, r, p] {
            let next = try await context.seat.acquire()
            try context.seat.release(next)
        }
    }
}
