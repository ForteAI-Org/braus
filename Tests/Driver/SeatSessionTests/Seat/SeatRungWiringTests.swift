//
//  SeatRungWiringTests.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import SeatCore
import SeatDriving
import SQLiteMemory
@testable import SeatBroker
@testable import SeatSession
import Testing

/// M05, the Seat's rung on the record, wired end to end short of the desktop session's `act`: the runtime a desktop
/// session composes over a borrowed Seat (`EngineRuntime(knowledgeDirectory:seat:)`, whose actuator is the
/// `SeatActuator`) sends a click through that actuator, confirms it as the engine does, and the session's own
/// hand-over (`BrokeredAutomationSession.handRung`) takes the send and gives it to the call's recorder, which writes
/// it with the call's end into the archive under the knowledge folder: the row is the receipt's poster and counts, for
/// the call that sent it, under the task open when it began, and a later call whose gesture was refused before any
/// event has none and never the earlier one's, and no task once the task ended. The task is begun and ended through
/// `TaskChannel`, the channel the `memory_task` tool itself uses, directly: the attribution is the record's own, the
/// tool's wording is not what is attested here. The Seat is the fakes' (`BorrowedSeatTargetTests.borrowed`): no
/// application of the person's, no HID event. What is not here, by source alone: `BrokeredAutomationSession.act`/
/// `deliver` calling `handRung` after the engine.
@MainActor
@Suite("M05: the Seat's send reaches the call's record through the runtime's actuator and the session's hand-over")
struct SeatRungWiringTests {

    @Test("the send is recorded for the call that made it, with the receipt's poster and counts, under its task; a refused call after the task records neither")
    func theSendIsRecordedForTheCallThatMadeIt() async throws {

        let sender    = FakeSender()
        let context   = try await BorrowedSeatTargetTests.borrowed(sender: sender)
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-seat-rung-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let runtime  = EngineRuntime(knowledgeDirectory: knowledge, seat: context.target)
        let actuator = try #require(runtime.actuator as? SeatActuator, "the runtime over a Seat drives the SeatActuator")
        let pid      = context.window.reference.processID
        let app      = AppContextIdentity(bundleID: "test.process")
        let frame    = try await context.target.observe().geometry.window.frame
        let inside   = CGPoint(x: frame.midX, y: frame.midY)
        let outside  = CGPoint(x: frame.maxX + 1_000, y: frame.maxY + 1_000)
        func recorder() -> CallRecorder {
            runtime.recorder(ActionContext(source: .system, streamID: "seat-rung", traceID: "seat-rung", sessionID: "seat-1"))
        }
        // A real task in the archive, begun as the tools begin one, whose attribution the first call begins under.
        let producer = try TaskProducer(source: .system, streamID: "seat-rung")
        let task     = try await TaskChannel.begin(try TaskRevisionContent(goal: "Click Save in the test window"),
                                                   producer: producer, traceID: "seat-rung", memory: runtime.service)
        let attribution = try #require(task.attribution)

        // The first call: begun on the record under the task, one click through the runtime's actuator, confirmed,
        // handed over as the session does right after the engine, ended. The recorder is the current one while the
        // call runs, as the tools make it, and no one's after.
        let first = recorder()
        try await first.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: app, attribution: attribution)
        try await CallRecorder.$current.withValue(first) {
            try await actuator.perform(.click(at: inside), in: pid)
            await actuator.confirm(.observed, in: pid)
            await BrokeredAutomationSession.handRung(of: runtime, to: first)
        }
        #expect(CallRecorder.current == nil)
        try await first.end(.completed, result: .outcome(.actedUnverified, message: "clicked"), tool: .act)
        #expect(sender.sent.count == 1)
        // The task ends; the next call begins under none.
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed),
                                             producer: producer, memory: runtime.service)

        // The second call: begun under no task, its only gesture refused before any event; the hand-over finds
        // nothing, and nothing of the first call's is left to take.
        let second = recorder()
        try await second.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: app, attribution: nil)
        _ = try await context.target.observe()
        // The actuator words it for the engine as a gesture not sent, the reason the call keeps.
        let refused = await #expect(throws: GestureNotSent.self) {
            try await actuator.perform(.click(at: outside), in: pid)
        }
        #expect(refused?.reason == "point_outside_window", "\(String(describing: refused))")
        await actuator.confirm(.unknown, in: pid)
        await BrokeredAutomationSession.handRung(of: runtime, to: second)
        try await second.end(.completed, result: .outcome(.refused, message: "outside the window"), tool: .act)
        #expect(sender.sent.count == 1 && context.seat.currentTurn == nil)
        #expect(await actuator.takeLastSend() == nil, "nothing left in the actuator after the two calls")

        // Read back from the archive: the first call's row is the receipt's, the second has none.
        let memory = runtime.service
        #expect(await memory.flush(within: .seconds(10)))
        let calls = try await memory.calls(inTrace: "seat-rung")
        #expect(calls.map(\.event.eventID).sorted() == [first.eventID, second.eventID].sorted(), "two calls, both ended")
        #expect(calls.allSatisfy { $0.progress.status == .completed }, "\(calls.map(\.progress.status))")
        let recorded = try await memory.perform { try await $0.facts.rung(of: first.eventID) }
        #expect(recorded == CallRung(rung: .seatPublicProcess,
                                     how: "2 events, 2 routed to window \(context.window.reference.windowNumber)"),
                "\(String(describing: recorded))")
        #expect(try await memory.perform { try await $0.facts.rung(of: second.eventID) } == nil,
                "a call refused before any event has no rung, and never the earlier call's")
        // The attributions are the record's: the first call's is the real task's attempt and revision, the second's none.
        let firstTask = try await memory.perform { try await $0.facts.attribution(of: first.eventID) }
        #expect(firstTask == attribution && firstTask?.taskID == task.taskID && firstTask?.attemptID == task.attemptID
                && firstTask?.revision == 1, "\(String(describing: firstTask))")
        #expect(try await memory.perform { try await $0.facts.attribution(of: second.eventID) } == nil,
                "a call begun after the task ended belongs to no task")
        #expect(try await memory.perform { try await $0.tasks.task(task.taskID, for: producer) }?.status == .completed)
        await memory.close()
        MemoryService.forget(knowledge)
        await context.target.stop()
    }
}
