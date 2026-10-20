//
//  SeatSelectRungTests.swift
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

/// M05, the Seat's `select` on the record: the receipt the real `AgentSeat` returns for a pixel dropdown (the opener's
/// routed click, then the keys) is handed by the desktop session's own hand-over
/// (`BrokeredAutomationSession.handSelectRung`) to the call's recorder, which writes the LAST RETURNED receipt's send,
/// the last key's or the opener's when no key went out, as the call's rung with its end. A native popup (accessibility
/// actions, no receipt), a refusal before any gesture (no receipt) and a selector that threw (no receipt returned)
/// hand nothing and erase nothing. The Seat and the sender are the fakes of `NativePopupMenuTests`: no application
/// of the person's, no HID event. What stays source-only: `BrokeredAutomationSession.select` calling the hand-over
/// after the selector, and `select` through the tools.
@MainActor
@Suite("M05: the Seat's dropdown receipt reaches the call's record through the session's hand-over", .serialized)
struct SeatSelectRungTests {

    nonisolated static let item = "Sentinel-Item-7q4w"

    private func ready() async throws -> (AgentSeat, AdoptedWindow, FakeSensing, FakeSender) {
        let sensing = FakeSensing()
        let sender  = FakeSender()
        sender.onCyclePreparation = { sensing.menus = [] }
        let seat   = makeSeat(sensing: sensing, sender: sender, marker: 956)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        return (seat, window, sensing, sender)
    }

    /// The call's record: a recorder on the archive under `knowledge`, as the tools make one.
    struct Record {
        let knowledge: URL
        let memory   : MemoryService
        let brain    : BrainMemory
        let app      = AppContextIdentity(bundleID: "test.process")

        init() throws {
            knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-seat-select-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
            let memory = MemoryService.shared(for: knowledge)
            self.memory = memory
            brain = BrainMemory(brains: memory, applications: memory, relations: memory, clock: { memory.clock.brainNow() })
        }

        /// A recorder as the tools make one: the task's declared secrets are its minimization's.
        func recorder() -> CallRecorder {
            CallRecorder(memory: memory, brain: brain,
                         context: ActionContext(source: .system, streamID: "seat-select", traceID: "seat-select", sessionID: "s1"),
                         minimization: ValueMinimization(secrets: [SeatSelectRungTests.item]))
        }

        /// One `select` call as the session makes it: begun, the hand-over of what the selector returned (and, when
        /// `again`, a second hand-over with no receipt, as a later interaction of the same call that sent nothing),
        /// ended with `status`.
        func select(_ receipt: PopupMenuReceipt?, attribution: TaskCallAttribution? = nil, again: Bool = false,
                    status: AgentCallStatus = .completed) async throws -> String {
            let recorder = recorder()
            try await recorder.begin(.select(control: "Picker", item: SeatSelectRungTests.item), app: app, attribution: attribution)
            await BrokeredAutomationSession.handSelectRung(of: receipt, to: recorder)
            if again { await BrokeredAutomationSession.handSelectRung(of: nil, to: recorder) }
            try await recorder.end(status, result: status == .failed ? .error(message: "the key was refused")
                                                                     : .outcome(.foundActed, message: "selected"), tool: .select)
            return recorder.eventID
        }

        func rung(of id: String) async throws -> CallRung? { try await memory.perform { try await $0.facts.rung(of: id) } }
        func attribution(of id: String) async throws -> TaskCallAttribution? { try await memory.perform { try await $0.facts.attribution(of: id) } }

    }

    static func send(_ receipt: InputReceipt) -> CallRung { CallRung(SeatSend(receipt)) }

    /// The regular files under `knowledge` whose bytes hold `text`. A file the memory makes and removes while it works
    /// (its backup's partial files) may be gone between the enumeration and the read: gone (`ENOENT`, and nothing
    /// else), it holds nothing; any other error, on the enumeration, the metadata or the bytes, is thrown.
    nonisolated static func files(under knowledge: URL, holding text: String) throws -> [String] {
        struct ScanFailure: Error, CustomStringConvertible { let description: String }
        /// The error the enumeration met on its way, kept for the caller: the handler cannot throw, so the walk is
        /// stopped and the error rethrown after it; an ephemeral file's `ENOENT` lets the walk go on instead.
        final class Interrupted: @unchecked Sendable {
            private let lock = NSLock()
            private var failure: (URL, any Error)?
            func record(_ url: URL, _ error: any Error) { lock.withLock { failure = (url, error) } }
            var value: (URL, any Error)? { lock.withLock { failure } }
        }
        let interrupted = Interrupted()
        guard let walk = FileManager.default.enumerator(at: knowledge, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [], errorHandler: { url, error in
            if vanished(error) { return true }
            interrupted.record(url, error)
            return false
        }) else {
            throw ScanFailure(description: "the knowledge folder could not be enumerated: \(knowledge.path)")
        }
        var holding: [String] = []
        while let file = walk.nextObject() as? URL {
            let regular: Bool
            do { regular = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            catch let error where vanished(error) { continue }
            guard regular else { continue }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error where vanished(error) { continue }
            if data.range(of: Data(text.utf8)) != nil { holding.append(file.lastPathComponent) }
        }
        if let (url, error) = interrupted.value {
            throw ScanFailure(description: "the enumeration of \(knowledge.path) failed at \(url.lastPathComponent): \(error)")
        }
        return holding
    }

    /// Whether an error says the file is no longer there: POSIX `ENOENT`, or Cocoa's no-such-file, itself or underneath.
    nonisolated static func vanished(_ error: any Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return failure.code == Int(ENOENT) }
        guard failure.domain == NSCocoaErrorDomain else { return false }
        if failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError { return true }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError { return vanished(underlying) }
        return false
    }

    @Test("the last key's receipt is the call's rung, distinct from the opener's and the previous key's; a second hand-over with nothing keeps it; an opener alone is the opener's; after the task ends the next call is its own under no task; a native popup, a refusal before any gesture and a key refused after the opener record none; nothing replayed, the item's word nowhere")
    func theLastReturnedReceiptIsTheRung() async throws {
        let (seat, window, sensing, sender) = try await ready()
        let record = try Record()
        let producer = try TaskProducer(source: .system, streamID: "seat-select")
        // A secret input is declared with its content withheld: the archive keeps the declaration, the recorder's
        // minimization keeps the word (as the task tool does for the producer's secrets).
        let task = try await TaskChannel.begin(try TaskRevisionContent(goal: "Pick the item", inputs: [
            try TaskValue(name: "item", role: "the item to pick", kind: .text, content: .withheld, sensitivity: .secret, source: .request),
        ]), producer: producer, traceID: "seat-select", memory: record.memory)
        let attribution = try #require(task.attribution)

        // A. The dropdown: the opener's click (public, 2 events), an arrow (public, 1 event), the return key (SkyLight,
        //    3 events): three receipts with different posters and counts; the rung is the last key's, and a second
        //    hand-over with nothing in the same call keeps it.
        sender.onSend = { command in
            switch command {
                case .click:
                    sensing.menus = [FakeGeometry.menuWindow]
                    sender.receiptPoster = .publicProcess; sender.receiptEventCount = 2
                case .key(36, _, _, _, _):
                    sensing.menus = []
                    sender.receiptPoster = .skyLightProcess; sender.receiptEventCount = 3
                default:
                    sender.receiptPoster = .publicProcess; sender.receiptEventCount = 1
            }
        }
        var turn = try await seat.acquire()
        let chosen = try await seat.useDropdownMenu(openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero) { _ in [126, 36] }
        try seat.release(turn)
        #expect(sender.sent.count == 3 && chosen.selectionRequested && chosen.choosing.count == 2)
        let opener = try #require(chosen.opening), previous = chosen.choosing[0], last = try #require(chosen.choosing.last)
        let first = try await record.select(chosen, attribution: attribution, again: true)
        let firstRung = try await record.rung(of: first)
        #expect(firstRung == Self.send(last) && firstRung?.rung == .seatSkyLightProcess
                && firstRung?.how == "3 events, 3 routed to window \(last.route.windowNumber)", "\(String(describing: firstRung))")
        #expect(firstRung != Self.send(opener) && firstRung != Self.send(previous), "the last key, not the opener nor the previous key")
        #expect(try await record.attribution(of: first) == attribution)

        // B. The menu opened and closed with no row chosen: the opener's receipt is the last returned, and the row.
        sender.onSend = { _ in sensing.menus = [FakeGeometry.menuWindow]; sender.receiptPoster = .publicProcess; sender.receiptEventCount = 2 }
        turn = try await seat.acquire()
        let openedOnly = try await seat.useDropdownMenu(openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero) { _ in nil }
        try seat.release(turn)
        #expect(sender.sent.count == 4 && !openedOnly.selectionRequested && openedOnly.choosing.isEmpty && openedOnly.closedBy == .preparationCycle)
        let second = try await record.select(openedOnly, attribution: attribution)
        #expect(try await record.rung(of: second) == Self.send(try #require(openedOnly.opening)), "the opener's send, not the cleanup's")
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed), producer: producer, memory: record.memory)

        // C. After the task ended: the same dropdown again, its own row under no task.
        sender.onSend = { command in
            if case .click = command { sensing.menus = [FakeGeometry.menuWindow] }
            if case .key(36, _, _, _, _) = command { sensing.menus = [] }
            sender.receiptPoster = .publicProcess; sender.receiptEventCount = 1
        }
        turn = try await seat.acquire()
        let later = try await seat.useDropdownMenu(openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero) { _ in [36] }
        try seat.release(turn)
        #expect(sender.sent.count == 6 && later.choosing.count == 1)
        let third = try await record.select(later)
        #expect(try await record.rung(of: third) == Self.send(try #require(later.choosing.last)))
        #expect(try await record.attribution(of: third) == nil, "begun after the task ended: no task")

        // D. The native popup: accessibility actions, no receipt returned for them: nothing handed, no row.
        turn = try await seat.acquire()
        let native = try await seat.useNativePopupMenu(of: window, turn: turn, opening: { sensing.menus = [FakeGeometry.menuWindow] }) { _ in
            sensing.menus = []
            return true
        }
        try seat.release(turn)
        #expect(native.selectionRequested && native.opening == nil && native.choosing.isEmpty && sender.sent.count == 6)
        let fourth = try await record.select(native)
        #expect(try await record.rung(of: fourth) == nil, "a native popup's actions carry no receipt: no rung, none inferred")

        // E. The Seat's own refusal before any input: a menu already open when the dropdown would open. The Seat throws
        //    its typed refusal, no command goes out, the selector has no receipt to return: nothing handed, no row.
        sensing.menus = [FakeGeometry.menuWindow]
        turn = try await seat.acquire()
        await #expect(throws: SessionFailure.contextMenuAlreadyOpen(processID: FakeGeometry.targetPID)) {
            _ = try await seat.useDropdownMenu(openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero) { _ in [36] }
        }
        try? seat.release(turn)
        sensing.menus = []
        #expect(sender.sent.count == 6, "refused before any input: nothing sent")
        let fifth = try await record.select(nil)
        #expect(try await record.rung(of: fifth) == nil)

        // F. The key refused after the opener went out: the Seat throws, the receipts are not returned, the call fails
        //    with no rung; the opener's command went out once and nothing is replayed.
        sender.onSend = { _ in sensing.menus = [FakeGeometry.menuWindow] }
        sender.refusedCommand = { command in
            if case .key = command { return SeatDrivingFailure.notAdopted }
            return nil
        }
        turn = try await seat.acquire()
        await #expect(throws: (any Error).self) {
            _ = try await seat.useDropdownMenu(openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero) { _ in [36] }
        }
        try? seat.release(turn)
        sender.refusedCommand = nil
        #expect(sender.sent.count == 7, "the opener once; the refused key never recorded as sent")
        let sixth = try await record.select(nil, status: .failed)
        #expect(try await record.rung(of: sixth) == nil, "a selector that threw returned no receipt: no rung")

        // The record: six calls under the trace, each its own event, nothing replayed; the item's word in no file.
        _ = await record.memory.flush(within: .seconds(10))
        let calls = try await record.memory.calls(inTrace: "seat-select")
        #expect(calls.count == 6 && Set(calls.map(\.event.eventID)) == Set([first, second, third, fourth, fifth, sixth]), "\(calls.map(\.event.eventID))")
        #expect(calls.filter { $0.progress.status == .failed }.map(\.event.eventID) == [sixth])
        #expect(try Self.files(under: record.knowledge, holding: Self.item).isEmpty, "the open archive holds the item")
        await record.memory.close()
        MemoryService.forget(record.knowledge)
        #expect(try Self.files(under: record.knowledge, holding: Self.item).isEmpty, "the closed archive holds the item")
        try? FileManager.default.removeItem(at: record.knowledge)
    }
}
