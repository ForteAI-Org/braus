//
//  SeatContextMenuRungTests.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import SeatCore
import SeatDriving
import SeatInput
import SQLiteMemory
@testable import SeatBroker
@testable import SeatSession
import Testing

/// The record of one `context_menu` call, as the tools make it: a recorder on a temporary archive whose minimization
/// knows the task's declared secret, begun with the call's request, handed what the Seat returned, ended.
struct ContextMenuRecord {
    let knowledge: URL
    let memory   : MemoryService
    let brain    : BrainMemory
    let secret   : String
    let app      = AppContextIdentity(bundleID: "test.menu")

    init(secret: String) throws {
        self.secret = secret
        knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-seat-context-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: knowledge)
        self.memory = memory
        brain = BrainMemory(brains: memory, applications: memory, relations: memory, clock: { memory.clock.brainNow() })
    }

    func recorder() -> CallRecorder {
        CallRecorder(memory: memory, brain: brain,
                     context: ActionContext(source: .system, streamID: "seat-context-menu", traceID: "seat-context-menu", sessionID: "s1"),
                     minimization: ValueMinimization(secrets: [secret]))
    }

    /// One call: begun, the hand-over of what the Seat returned (and, when `again`, a second hand-over with nothing,
    /// as a later interaction of the same call that sent nothing), ended with `status`.
    func contextMenu(_ receipt: SeatMenuOutcome?, attribution: TaskCallAttribution? = nil, again: Bool = false,
                     status: AgentCallStatus = .completed) async throws -> String {
        let recorder = recorder()
        try await recorder.begin(.contextMenu(target: "field", item: secret, section: nil), app: app, attribution: attribution)
        await BrokeredAutomationSession.handContextMenuRung(of: receipt, to: recorder)
        if again { await BrokeredAutomationSession.handContextMenuRung(of: nil, to: recorder) }
        try await recorder.end(status, result: status == .failed ? .error(message: "the menu never appeared")
                                                                 : .outcome(.actedUnverified, message: "requested"), tool: .contextMenu)
        return recorder.eventID
    }

    func rung(of id: String) async throws -> CallRung? { try await memory.perform { try await $0.facts.rung(of: id) } }
    func attribution(of id: String) async throws -> TaskCallAttribution? { try await memory.perform { try await $0.facts.attribution(of: id) } }

    /// The task the calls run under, begun as the tools begin one, the secret declared with its content withheld.
    func task(_ producer: TaskProducer) async throws -> OpenTask {
        try await TaskChannel.begin(try TaskRevisionContent(goal: "Choose in the menu", inputs: [
            try TaskValue(name: "item", role: "the row to choose", kind: .text, content: .withheld, sensitivity: .secret, source: .request),
        ]), producer: producer, traceID: "seat-context-menu", memory: memory)
    }

    /// A task begun with its producer and its real attribution, for a suite that imports no task module of its own.
    func beginTask() async throws -> (task: OpenTask, producer: TaskProducer, attribution: TaskCallAttribution) {
        let producer = try TaskProducer(source: .system, streamID: "seat-context-menu")
        let task = try await self.task(producer)
        guard let attribution = task.attribution else { throw CocoaError(.coderInvalidValue) }
        return (task, producer, attribution)
    }

    /// The task ended as completed.
    func endTask(_ task: OpenTask, _ producer: TaskProducer) async throws {
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed), producer: producer, memory: memory)
    }

    /// The rung the record would keep for a receipt (the session's mapping), for a suite that imports no SeatBroker.
    func expected(_ receipt: InputReceipt) -> CallRung { CallRung(SeatSend(receipt)) }

    /// The event ids of every call under the trace, after a flush, for a suite that imports no memory module of its own.
    func callIDs() async throws -> [String] {
        _ = await memory.flush(within: .seconds(10))
        return try await memory.calls(inTrace: "seat-context-menu").map(\.event.eventID)
    }

    /// The archive scanned for the secret while open (after a flush) and once closed; the folder removed after.
    func expectSecretNowhere(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        _ = await memory.flush(within: .seconds(10))
        #expect(try SeatSelectRungTests.files(under: knowledge, holding: secret).isEmpty, "the open archive holds the secret",
                sourceLocation: sourceLocation)
        await memory.close()
        MemoryService.forget(knowledge)
        #expect(try SeatSelectRungTests.files(under: knowledge, holding: secret).isEmpty, "the closed archive holds the secret",
                sourceLocation: sourceLocation)
        try? FileManager.default.removeItem(at: knowledge)
    }
}

/// M05, the Seat's `context_menu` on the record (CM-1): the real `AgentSeat.withContextMenu` on the fakes of
/// `ContextMenuTests` answers its outcome, the opener's right click and the receipts posted inside the menu; the desktop
/// session's own hand-over (`BrokeredAutomationSession.handContextMenuRung`) gives the LAST RETURNED receipt, the row's
/// click or the opener's, to the call's recorder, which writes it with the end. The cleanup's Escape goes out through
/// the sender and is never the row; a Seat that throws returns no outcome and records nothing. No application of the
/// person's, no HID event. Source-only: `BrokeredAutomationSession.deliver` calling the hand-over, and the tools.
@MainActor
@Suite("M05: the Seat's contextual menu receipt reaches the call's record through the session's hand-over", .serialized)
struct SeatContextMenuRungTests {

    nonisolated static let item = "Sentinel-Row-5k2j"

    /// `ContextMenuTests.ready` with the receipts' poster and counts set per command before each receipt is made, on
    /// top of the fixture's own behaviour (the menu appearing on the right click, closing on the left click or the Escape).
    private func ready(closedBy: Set<ContextMenuReceipt.Closure>? = nil, opensAMenu: Bool = true) async throws
        -> (seat: AgentSeat, window: AdoptedWindow, turn: Turn, sensing: FakeSensing, sender: FakeSender) {
        let context: (seat: AgentSeat, window: AdoptedWindow, turn: Turn, sensing: FakeSensing, sender: FakeSender, source: ControlledObservationSource)
        if let closedBy {
            context = try await ContextMenuTests.ready(opensAMenu: opensAMenu, closedBy: closedBy)
        } else {
            context = try await ContextMenuTests.ready(opensAMenu: opensAMenu)
        }
        let base = context.sender.onSend
        let sender = context.sender
        sender.onSend = { command in
            base?(command)
            switch command {
                case .click(_, .right, _): sender.receiptPoster = .publicProcess;   sender.receiptEventCount = 2
                case .click(_, .left, _) : sender.receiptPoster = .skyLightProcess; sender.receiptEventCount = 3
                default                  : sender.receiptPoster = .publicProcess;   sender.receiptEventCount = 1
            }
        }
        return (context.seat, context.window, context.turn, context.sensing, context.sender)
    }

    static func send(_ receipt: InputReceipt) -> CallRung { CallRung(SeatSend(receipt)) }

    /// The body that chooses the row: observes the menu and clicks inside it, as the selector does.
    static func chooseRow(_ interaction: SeatMenuInteraction) async {
        guard case .success(let delivery) = await interaction.observe() else { return }
        let frame = delivery.geometry.window.frame
        guard let point = InputLocation(screenPoint: CGPoint(x: frame.minX + 57.5, y: frame.minY + 17), observedIn: delivery.geometry) else { return }
        _ = try? await interaction.send(.click(point, button: .left), observation: delivery.reference)
    }

    @Test("the row's click is the call's rung, distinct from the opener's; a second hand-over with nothing keeps it; a menu withdrawn by the cleanup's Escape records the opener, never the Escape; after the task ends the next call is its own; a menu that never appears records nothing; the item's word nowhere")
    func theLastReturnedReceiptIsTheRung() async throws {
        let record = try ContextMenuRecord(secret: Self.item)
        let producer = try TaskProducer(source: .system, streamID: "seat-context-menu")
        let task = try await record.task(producer)
        let attribution = try #require(task.attribution)

        // 1. The row chosen: the opener public/2, the row's click SkyLight/3; the rung the row's click.
        let a = try await ready()
        let chosen = try await a.seat.withContextMenu(openedAt: ContextMenuTests.openAt, observation: try await observedReference(a.seat), turn: a.turn) {
            await Self.chooseRow($0)
        }
        try a.seat.release(a.turn)
        #expect(chosen.insideMenu.count == 1 && chosen.cleanup == .verifiedClosed(.chosenItem) && a.sender.sent.count == 2)
        let row = try #require(chosen.insideMenu.last)
        let first = try await record.contextMenu(chosen, attribution: attribution, again: true)
        let firstRung = try await record.rung(of: first)
        #expect(firstRung == Self.send(row) && firstRung?.rung == .seatSkyLightProcess
                && firstRung?.how == "3 events, 3 routed to window \(row.route.windowNumber)", "\(String(describing: firstRung))")
        #expect(firstRung != Self.send(chosen.opening), "the row's click, not the opener's")
        #expect(try await record.attribution(of: first) == attribution)

        // 2. Nothing chosen and the menu withdrawn by the cleanup's Escape: the Escape really went out (public/1, its own
        //    receipt to the fake), the outcome holds no receipt of it, and the rung is exactly the opener's.
        let b = try await ready(closedBy: [.escapeKey])
        let withdrawn = try await b.seat.withContextMenu(openedAt: ContextMenuTests.openAt, observation: try await observedReference(b.seat), turn: b.turn) { _ in }
        try b.seat.release(b.turn)
        #expect(withdrawn.insideMenu.isEmpty && withdrawn.cleanup == .verifiedClosed(.escapeKey), "\(withdrawn.cleanup)")
        #expect(b.sender.sent.count == 2, "the opener and the cleanup's Escape")
        if case .key(53, _, _, _, _) = b.sender.sent[1].command {} else { Issue.record("the cleanup's Escape was not the second command") }
        let second = try await record.contextMenu(withdrawn, attribution: attribution)
        let secondRung = try await record.rung(of: second)
        #expect(secondRung == Self.send(withdrawn.opening) && secondRung?.rung == .seatPublicProcess
                && secondRung?.how == "2 events, 2 routed to window \(withdrawn.opening.route.windowNumber)", "\(String(describing: secondRung))")
        #expect(secondRung?.how != "1 events, 1 routed to window \(withdrawn.opening.route.windowNumber)", "never the Escape")
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed), producer: producer, memory: record.memory)

        // 3. After the task ended: the row chosen again, its own row under no task.
        let c = try await ready()
        let later = try await c.seat.withContextMenu(openedAt: ContextMenuTests.openAt, observation: try await observedReference(c.seat), turn: c.turn) {
            await Self.chooseRow($0)
        }
        try c.seat.release(c.turn)
        let third = try await record.contextMenu(later)
        #expect(try await record.rung(of: third) == Self.send(try #require(later.insideMenu.last)))
        #expect(try await record.attribution(of: third) == nil)

        // 4. A menu that never appears: the Seat throws after the right click went out, returns no outcome; nothing
        //    handed, no rung, the call failed; the right click went out once, no row click ever.
        let d = try await ready(opensAMenu: false)
        await #expect(throws: (any Error).self) {
            _ = try await d.seat.withContextMenu(openedAt: ContextMenuTests.openAt, observation: try await observedReference(d.seat), turn: d.turn,
                                                 appearingWithin: .milliseconds(30)) { _ in Issue.record("no menu, no body") }
        }
        try? d.seat.release(d.turn)
        #expect(d.sender.sent.filter { if case .click(_, .right, _) = $0.command { return true }; return false }.count == 1)
        #expect(!d.sender.sent.contains { if case .click(_, .left, _) = $0.command { return true }; return false })
        let fourth = try await record.contextMenu(nil, status: .failed)
        #expect(try await record.rung(of: fourth) == nil)

        // The record: four calls, four event ids, one failed; the item's word in no file, open and closed.
        _ = await record.memory.flush(within: .seconds(10))
        let calls = try await record.memory.calls(inTrace: "seat-context-menu")
        #expect(Set(calls.map(\.event.eventID)) == Set([first, second, third, fourth]) && calls.count == 4)
        #expect(calls.filter { $0.progress.status == .failed }.map(\.event.eventID) == [fourth])
        try await record.expectSecretNowhere()
    }
}
