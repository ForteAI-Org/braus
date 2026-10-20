//
//  BorrowedSeatTargetTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import SeatCore
import SeatDriving
import SeatInput
@testable import SeatSession
import Testing

/// A `SeatTarget` borrowing a seat another owner holds, on the controlled seat this bundle composes:
/// the assignment, selection, issuer and admission `SeatHost` composes, with evidence supplied in
/// place of a display.
///
/// It lives in this bundle because the controlled seat does: its fakes are this bundle's and
/// nothing else can reach them. It proves the borrow's contract with the seat and nothing about
/// macOS. The host is never started here, so what `stop` does not do to a live host is read from
/// the code and left to the live spike in `SeatBrokerTests`.
@MainActor
@Suite("Borrowed seat target")
struct BorrowedSeatTargetTests {

    /// A seat with one window its owner adopted and observed once, which gives the surface the
    /// second agreeing reading it needs, and a target borrowing that seat with an unstarted host.
    static func borrowed(
        sender: FakeSender = FakeSender()
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow, host: SeatHost, target: SeatTarget) {
        let context = try await ObservationAdmissionTests.composed(sender: sender, marker: 950)
        _ = try await observe(context.seat)
        let host = SeatHost()
        return (context.seat, context.window, host, SeatTarget(borrowing: host, seat: context.seat))
    }

    @Test("a borrowed target refuses to start the host it borrowed and keeps the seat it was given")
    func aBorrowedTargetRefusesToStart() async throws {

        let context = try await Self.borrowed()

        await #expect(throws: SeatDrivingFailure.borrowedLifecycle) { try await context.target.start() }
        #expect(context.host.state == .off)
        #expect(context.host.displayID == nil)
        #expect(try context.target.agentSeat() === context.seat)
    }

    @Test("a borrowed target keeps the observation it took, and a spent one is replaced by a new look")
    func aBorrowedTargetKeepsItsObservation() async throws {

        let context = try await Self.borrowed()

        let delivery = try await context.target.observe()
        #expect(context.target.lastWindowGeometry == delivery.geometry)
        #expect(context.target.lastCapturedWindow?.id == context.window.id)
        #expect(try await context.target.currentObservation().reference == delivery.reference)

        context.target.spendObservation()
        #expect(try await context.target.currentObservation().reference != delivery.reference)
    }

    @Test("every observation taken through a borrow is handed to its owner")
    func aBorrowHandsItsObservationsToItsOwner() async throws {

        let context = try await ObservationAdmissionTests.composed(sender: FakeSender(), marker: 951)
        _ = try await observe(context.seat)
        var heard: [SeatObservationDelivery] = []
        let target = SeatTarget(
            borrowing: SeatHost(),
            seat     : context.seat
        ) { heard.append($0) }

        let first  = try await target.observe()
        let second = try await target.observe()
        #expect(heard.map(\.reference) == [first.reference, second.reference])

        // A revoked borrow observes nothing, so its owner hears nothing more.
        await target.stop()
        _ = try? await target.observe()
        #expect(heard.count == 2)
    }

    @Test("a borrow refuses a different window before its first scene is exposed")
    func initialWindowChangeRefuses() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 952)
        _ = try await observe(context.seat)
        var heard: [SeatObservationDelivery] = []
        let target = SeatTarget(
            borrowing: SeatHost(),
            seat     : context.seat
        ) { heard.append($0) }

        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        #expect(context.seat.currentTarget?.id == other.id)

        let refusal = SeatDrivingFailure.initialWindowChanged(
            expected: try #require(context.window.reference.identity),
            observed: other.reference.identity
        )
        let capturesBefore = context.source.requested.count
        await #expect(throws: refusal) { try await target.observe() }
        await #expect(throws: refusal) { try await target.currentObservation() }
        await #expect(throws: refusal) { try await target.displayStill() }
        #expect(throws: refusal) { try target.currentWindow() }
        #expect(context.source.requested.count == capturesBefore)
        #expect(target.lastWindowGeometry == nil)
        #expect(target.lastCapturedWindow == nil)
        #expect(heard.isEmpty, "the owner's preview does not receive the unintended window")
        #expect(context.sender.sent.isEmpty)
        await target.stop()
    }

    @Test("the adopted opening identity refuses a selection changed before the borrow")
    func suppliedInitialIdentityRefuses() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 954)
        _ = try await observe(context.seat)
        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        let expected = try #require(context.window.reference.identity)
        let target = SeatTarget(
            borrowing    : SeatHost(),
            seat         : context.seat,
            initialWindow: expected
        )
        let refusal = SeatDrivingFailure.initialWindowChanged(expected: expected, observed: other.reference.identity)
        await #expect(throws: refusal) { try await target.windowStill() }
        #expect(target.lastCapturedWindow == nil)
        #expect(context.sender.sent.isEmpty)
        await target.stop()
    }

    @Test("opening compares process lifetime and owner even when the window number matches", arguments: [true, false])
    func initialIdentityUsesLifetimeAndOwner(differentConnection: Bool) async throws {
        let context = try await Self.borrowed()
        let actual = try #require(context.window.reference.identity)
        let process = differentConnection ? actual.process : ProcessIdentity(
            processID       : actual.process.processID,
            serialNumberHigh: actual.process.serialNumberHigh,
            serialNumberLow : actual.process.serialNumberLow + 1
        )
        let expected = WindowIdentity(
            process          : process,
            windowNumber     : actual.windowNumber,
            ownerConnectionID: actual.ownerConnectionID + (differentConnection ? 1 : 0)
        )
        let target = SeatTarget(
            borrowing    : context.host,
            seat         : context.seat,
            initialWindow: expected
        )
        await #expect(throws: SeatDrivingFailure.initialWindowChanged(expected: expected, observed: actual)) {
            try await target.observe()
        }
        #expect(target.lastCapturedWindow == nil)
        await target.stop()
    }

    @Test("a selection change during the first capture does not expose or retry the other window")
    func initialCaptureChangeRefuses() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 955)
        _ = try await observe(context.seat)
        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        _ = try await context.seat.switchTarget(to: context.window)
        var heard: [SeatObservationDelivery] = []
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat) { heard.append($0) }
        context.source.duringCapture = {
            context.source.duringCapture = nil
            _ = try? await context.seat.switchTarget(to: other)
        }
        let capturesBefore = context.source.requested.count
        let refusal = SeatDrivingFailure.initialWindowChanged(
            expected: try #require(context.window.reference.identity),
            observed: other.reference.identity
        )
        await #expect(throws: refusal) { try await target.observe() }
        #expect(Array(context.source.requested.dropFirst(capturesBefore)) == [context.window.reference.identity])
        #expect(target.lastCapturedWindow == nil)
        #expect(target.lastWindowGeometry == nil)
        #expect(heard.isEmpty)
        #expect(context.sender.sent.isEmpty)
        await target.stop()
    }

    @Test("a verified initial scene leaves later deliberate window changes available")
    func laterWindowChangeRemainsAvailable() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 953)
        _ = try await observe(context.seat)
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat)

        let first = try await target.observe()
        #expect(first.reference.recipient == context.window.reference.identity)

        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        let changed = try await target.observe()
        #expect(changed.reference.recipient == other.reference.identity)
        #expect(target.lastCapturedWindow?.id == other.id)
        #expect(context.sender.sent.isEmpty)
        await target.stop()
    }

    @Test("a typing turn stops when observation follows another window")
    func aGestureSequenceKeepsItsRecipient() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 956)
        _ = try await observe(context.seat)
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat)
        let actuator = SeatActuator(target: target)
        let pid = context.window.reference.processID
        let before = try await target.observe()
        let frame = before.geometry.window.frame
        try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)), in: pid)
        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await context.seat.adopt(reference, platform: AppKitPlatform())
        _ = try await target.observe()
        await #expect(throws: GestureNotSent.self) {
            try await actuator.perform(.click(at: CGPoint(x: second.reference.frame.midX, y: second.reference.frame.midY)), in: pid)
        }
        #expect(context.sender.sent.count == 1)
        await actuator.confirm(.unknown, in: pid)
        _ = try await target.observe()
        let current = second.reference.frame
        try await actuator.perform(.click(at: CGPoint(x: current.midX, y: current.midY)), in: pid)
        #expect(context.sender.sent.count == 2)
        await actuator.confirm(.observed, in: pid)
    }

    @Test("a gesture refused for a changed recipient keeps the receipt of the send before it, taken once by its call")
    func aRecipientChangeKeepsTheEarlierReceipt() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: 957)
        _ = try await observe(context.seat)
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat)
        let actuator = SeatActuator(target: target)
        let pid = context.window.reference.processID
        let frame = try await target.observe().geometry.window.frame
        try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)), in: pid)
        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await context.seat.adopt(reference, platform: AppKitPlatform())
        _ = try await target.observe()
        let refused = await #expect(throws: GestureNotSent.self) {
            try await actuator.perform(.click(at: CGPoint(x: second.reference.frame.midX, y: second.reference.frame.midY)), in: pid)
        }
        #expect(refused?.reason == "input_target_changed")
        await actuator.confirm(.unknown, in: pid)
        // The refused gesture posted nothing: the call's receipt is the first click's, on the first window, once.
        let first = try #require(await actuator.takeLastSend())
        #expect(first.windowNumber == context.window.reference.windowNumber, "\(first)")
        #expect(await actuator.takeLastSend() == nil, "taken once")
        // Confirmation releases the binding: the next call reaches the second window and keeps its own receipt.
        _ = try await target.observe()
        let current = second.reference.frame
        try await actuator.perform(.click(at: CGPoint(x: current.midX, y: current.midY)), in: pid)
        await actuator.confirm(.observed, in: pid)
        let next = try #require(await actuator.takeLastSend())
        #expect(next.windowNumber == ObservationAdmissionTests.secondWindowNumber, "\(next)")
        #expect(context.sender.sent.count == 2)
    }

    @Test("an observation either holder takes supersedes the other's, and the refused Command posts nothing")
    func eitherHoldersObservationSupersedesTheOther() async throws {

        let sender   = FakeSender()
        let context  = try await Self.borrowed(sender: sender)
        let actuator = SeatActuator(target: context.target)
        let pid      = context.window.reference.processID

        // The engine perceives through the borrow, then the owner observes before the gesture goes.
        let perceived = try await context.target.observe()
        let owners    = try await observe(context.seat)
        let frame     = perceived.geometry.window.frame
        await #expect(throws: ObservationAdmissionRefusal.referenceSuperseded) {
            try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)), in: pid)
        }
        #expect(sender.sent.isEmpty)
        // The engine confirms a failed delivery too, and that is what gives the Turn back.
        await actuator.confirm(.unknown, in: pid)
        #expect(context.seat.currentTurn == nil)

        // The refusal cost the owner nothing: its observation still admits its Command.
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            ObservationAdmissionTests.click,
            observation: owners.reference,
            turn       : turn
        )
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
        #expect(sender.sent.count == 1)

        // The reverse: a look through the borrow leaves the owner's kept reference stale.
        let ownersNext = try await observe(context.seat)
        _ = try await context.target.observe()
        let second = try await context.seat.acquire()
        await #expect(throws: ObservationAdmissionRefusal.referenceSuperseded) {
            try await context.seat.send(
                ObservationAdmissionTests.click,
                observation: ownersNext.reference,
                turn       : second
            )
        }
        try context.seat.release(second)
        #expect(sender.sent.count == 1)
    }

    @Test("stopping a borrowed target ends the borrow and leaves the seat and its window with the owner")
    func stoppingABorrowedTargetLeavesTheSeatWithItsOwner() async throws {

        let sender  = FakeSender()
        let context = try await Self.borrowed(sender: sender)
        _ = try await context.target.observe()

        await context.target.stop()

        #expect(context.target.lastWindowGeometry == nil)
        #expect(context.target.lastCapturedWindow == nil)
        #expect(throws: SeatDrivingFailure.notAdopted) { try context.target.agentSeat() }
        #expect(context.seat.adoptedWindows.map(\.id) == [context.window.id])
        #expect(context.host.state == .off)

        let owners  = try await observe(context.seat)
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            ObservationAdmissionTests.click,
            observation: owners.reference,
            turn       : turn
        )
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
        #expect(sender.sent.count == 1)
    }

    @Test("the last send is kept for the call that made it: the receipt's poster and counts, taken once, past confirm, never a refused gesture's")
    func theLastSendIsTakenOnceByTheCallThatMadeIt() async throws {

        let sender   = FakeSender()
        let context  = try await Self.borrowed(sender: sender)
        let actuator = SeatActuator(target: context.target)
        let pid      = context.window.reference.processID
        #expect(await actuator.takeLastSend() == nil, "nothing was sent")

        // A click the fake posts through the public call: taken after confirm, with the receipt's counts, once.
        let frame  = try await context.target.observe().geometry.window.frame
        let inside = CGPoint(x: frame.midX, y: frame.midY)
        try await actuator.perform(.click(at: inside), in: pid)
        await actuator.confirm(.observed, in: pid)
        #expect(sender.sent.count == 1 && context.seat.currentTurn == nil)
        let posted = try #require(await actuator.takeLastSend())
        #expect(posted.poster == .publicProcess && posted.eventCount == 2 && posted.routedEventCount == 2
                && posted.windowNumber == context.window.reference.windowNumber, "\(posted)")
        #expect(await actuator.takeLastSend() == nil, "taken once")

        // An accessibility action answers a receipt of no event: a valid send, kept as it is. A gesture refused
        // before any event (a point outside the window) leaves the send before it to take, and adds nothing.
        sender.receiptPoster     = .accessibilityAction
        sender.receiptEventCount = 0
        _ = try await context.target.observe()
        try await actuator.perform(.click(at: inside), in: pid)
        // The actuator words the refusal for the engine as a gesture not sent (`SeatActuator.unsent`).
        let outside = CGPoint(x: frame.maxX + 1_000, y: frame.maxY + 1_000)
        let refused = await #expect(throws: GestureNotSent.self) {
            try await actuator.perform(.click(at: outside), in: pid)
        }
        #expect(refused?.reason == "point_outside_window", "\(String(describing: refused))")
        await actuator.confirm(.unknown, in: pid)
        #expect(sender.sent.count == 2)
        let action = try #require(await actuator.takeLastSend())
        #expect(action.poster == .accessibilityAction && action.eventCount == 0 && action.routedEventCount == 0, "\(action)")
        #expect(await actuator.takeLastSend() == nil)

        // A call whose only gesture was refused before any event has nothing to take: no send, no rung.
        _ = try await context.target.observe()
        let again = await #expect(throws: GestureNotSent.self) {
            try await actuator.perform(.click(at: outside), in: pid)
        }
        #expect(again?.reason == "point_outside_window")
        await actuator.confirm(.unknown, in: pid)
        #expect(sender.sent.count == 2 && context.seat.currentTurn == nil)
        #expect(await actuator.takeLastSend() == nil, "a refused gesture leaves no send")
        await context.target.stop()
    }

    @Test("a revoked borrow refuses to observe or act, and posts nothing, while the owner keeps its seat")
    func aRevokedBorrowRefuses() async throws {

        let sender   = FakeSender()
        let context  = try await Self.borrowed(sender: sender)
        let actuator = SeatActuator(target: context.target)
        let perceived = try await context.target.observe()

        // `stop` is what the broker's driver calls on every borrow it lent, before it adopts again.
        await context.target.stop()

        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.observe() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.currentObservation() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.windowStill() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.displayStill() }
        let frame = perceived.geometry.window.frame
        await #expect(throws: SeatDrivingFailure.notAdopted) {
            try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)),
                                       in: context.window.reference.processID)
        }
        #expect(sender.sent.isEmpty)
        #expect(context.seat.currentTurn == nil)
        #expect(context.seat.adoptedWindows.map(\.id) == [context.window.id])
    }
}
