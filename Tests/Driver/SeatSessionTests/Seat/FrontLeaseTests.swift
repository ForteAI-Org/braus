//
//  FrontLeaseTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The seat lending the front to its application for the length of a Command, over the fakes
/// and the focus recovery `BriefActivationTests` builds on them: its requests move the front the
/// way a real one does, and its reports are recorded rather than routed to the seat.
@MainActor
@Suite("The front lent for a Command")
struct FrontLeaseTests {

    private static let user = BriefActivationTests.user

    /// A body that runs until it is cancelled, as a Command waiting on its application does.
    private static func untilCancelled() async {
        while !Task.isCancelled { await EventLoopWait.sleep(.milliseconds(20)) }
    }

    @Test("the body's value comes back, the target is in front while it runs, and the front goes back verified")
    func normalCase() async throws {
        let sensing = FakeSensing()
        let (seat, record, recovery) = try await BriefActivationTests.seat(sensing: sensing)
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }
        let before = seat.state
        let target = try #require(seat.currentTarget).reference
        await log.drain()
        let adoption = log.events.count

        let (result, outcome) = await seat.lendFront { () async throws -> Int in
            #expect(sensing.frontmostProcessID == target.processID)
            #expect(seat.state == .acting)
            // The workspace notification of the seat's own request, while the Command works.
            recovery.activationChanged(to: target.processID)
            await EventLoopWait.sleep(.milliseconds(60))
            return 42
        }
        await log.drain()

        guard case .completed(let after) = outcome else { Issue.record("not completed: \(outcome)"); return }
        #expect(after >= 60)
        #expect(try result?.get() == 42)
        #expect(record.requested == [target, Self.user], "in front once, and the handback asked once")
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(record.reports.isEmpty, "nothing read the seat's own activation as the person's focus taken")
        #expect(seat.inputPauseReasons.isEmpty)
        #expect(seat.state == before)
        let states = log.events.dropFirst(adoption).compactMap { event -> SeatState? in
            guard case .seatStateChanged(_, let to, _) = event else { return nil }
            return to
        }
        #expect(states == [.acting, before], "acting for the length of it, and never waiting")
    }

    @Test("the bound cancels the body, nothing is retried, and the front still goes back")
    func theBoundCancelsTheBody() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await BriefActivationTests.seat(sensing: sensing)
        let target = try #require(seat.currentTarget).reference
        var runs = 0

        let (result, outcome) = await seat.lendFront(atMost: .milliseconds(300)) { () async throws -> Int in
            runs += 1
            await Self.untilCancelled()
            throw CancellationError()
        }

        guard case .boundReached(let after) = outcome else { Issue.record("not bounded: \(outcome)"); return }
        #expect(after >= 300)
        guard case .failure(let error)? = result else { Issue.record("no failure: \(String(describing: result))"); return }
        #expect(error is CancellationError)
        #expect(runs == 1)
        #expect(record.requested == [target, Self.user])
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(record.reports.isEmpty)
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test("a dialog the application opens during the lease neither ends it nor reads as the person's focus")
    func aDialogOpenedDuringTheLeaseIsTheCommands() async throws {
        let sensing = FakeSensing()
        let (seat, record, recovery) = try await BriefActivationTests.seat(sensing: sensing)
        let target = try #require(seat.currentTarget).reference
        let dialog = try #require(target.identity)
        let before = seat.state

        let (result, outcome) = await seat.lendFront { () async -> Bool in
            seat.selectionKit.declareModal(ModalRelationClaim(
                modal     : dialog,
                scope     : .application,
                provenance: .qualifiedModalAttestation
            ))
            // The application takes the front again for its dialog.
            recovery.activationChanged(to: target.processID)
            await EventLoopWait.sleep(.milliseconds(60))
            return !seat.openDialogs.isEmpty
        }

        guard case .completed = outcome else { Issue.record("the dialog ended the lease: \(outcome)"); return }
        #expect(try result?.get() == true, "the dialog was open in the seat while the body ran")
        #expect(record.requested == [target, Self.user])
        #expect(record.reports.isEmpty)
        #expect(seat.inputPauseReasons.isEmpty)
        #expect(seat.state == before)
    }

    @Test("a dialog already open in the seat refuses the lease, unless the caller admits it")
    func anOpenDialogIsRefusedUnlessAdmitted() async throws {
        let sensing = FakeSensing()
        let (seat, record, _) = try await BriefActivationTests.seat(sensing: sensing)
        let target = try #require(seat.currentTarget).reference
        seat.selectionKit.declareModal(ModalRelationClaim(
            modal     : try #require(target.identity),
            scope     : .application,
            provenance: .qualifiedModalAttestation
        ))
        var runs = 0

        let refused = await seat.lendFront { runs += 1 }
        #expect(refused.outcome == .refused(.dialogOpen))
        #expect(refused.result == nil)
        #expect(runs == 0)
        #expect(record.requested.isEmpty, "nothing was brought in front")

        let admitted = await seat.lendFront(admittingOpenDialog: true) { runs += 1 }
        guard case .completed = admitted.outcome else { Issue.record("not admitted: \(admitted.outcome)"); return }
        #expect(runs == 1)
        #expect(record.requested == [target, Self.user])
    }

    @Test("the person taking the front ends the lease, cancels the body and keeps the front")
    func thePersonsFrontEndsTheLease() async throws {
        let sensing = FakeSensing()
        let (seat, record, recovery) = try await BriefActivationTests.seat(sensing: sensing)
        let target = try #require(seat.currentTarget).reference
        let before = seat.state
        let start = try #require(sensing.cursorLocation)
        var warped: [CGPoint] = []
        seat.warpPointer = { warped.append($0); return .success }

        let (result, outcome) = await seat.lendFront { () async -> String in
            // The person clicks their own window, which moves the pointer and takes the front.
            sensing.cursorLocation = CGPoint(x: 400, y: 400)
            sensing.frontmostProcessID = Self.user.processID
            sensing.focusedUserWindow = Self.user
            recovery.activationChanged(to: Self.user.processID)
            await Self.untilCancelled()
            return "cancelled"
        }

        guard case .frontTaken = outcome else { Issue.record("the lease went on: \(outcome)"); return }
        #expect(try result?.get() == "cancelled")
        #expect(record.requested == [target], "nothing is handed back over the person")
        #expect(sensing.frontmostProcessID == Self.user.processID)
        #expect(record.reports.isEmpty)
        #expect(seat.inputPauseReasons.isEmpty)
        #expect(seat.state == before)
        #expect(warped.isEmpty, "the pointer the person moved stays where they put it")
        #expect(sensing.cursorLocation != start)
    }

    @Test("the pointer a click left on the seat's display goes back, and one the person moved since stays",
          arguments: [false, true])
    func thePointerGoesBackUnlessThePersonMovedIt(personMovesIt: Bool) async throws {
        let sensing = FakeSensing()
        let (seat, _, _) = try await BriefActivationTests.seat(sensing: sensing)
        let start = try #require(sensing.cursorLocation)
        let moved = CGPoint(x: 300, y: 300)
        var warped: [CGPoint] = []
        seat.warpPointer = { warped.append($0); sensing.cursorLocation = $0; return .success }

        let (_, outcome) = await seat.lendFront {
            // A posted click on the held window, on the virtual display.
            sensing.cursorLocation = CGPoint(x: FakeGeometry.virtual.midX, y: FakeGeometry.virtual.midY)
            // The person moves the pointer while the front is handed back.
            if personMovesIt { sensing.onUserWindowRead = { sensing.cursorLocation = moved } }
        }
        sensing.onUserWindowRead = nil

        guard case .completed = outcome else { Issue.record("not completed: \(outcome)"); return }
        #expect(warped == (personMovesIt ? [] : [start]))
        #expect(sensing.cursorLocation == (personMovesIt ? moved : start))
    }

    // MARK: Clicks through the seat's own route

    /// The held window as the window server lists it, the only surface of the target unless a test adds one.
    private static func listTarget(_ sensing: FakeSensing, _ target: WindowReference) {
        sensing.surfaces = [WindowSurface(reference: target, level: 0, isVisible: true)]
    }

    private static func centre(of frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    @Test("clicks inside the lease reach the target's process with its window, point, count, button and modifiers")
    func clicksReachTheProcessRoute() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let (seat, _, _) = try await BriefActivationTests.seat(sensing: sensing, sender: sender)
        let target = try #require(seat.currentTarget).reference
        Self.listTarget(sensing, target)
        let point = Self.centre(of: target.frame)
        let start = try #require(sensing.cursorLocation)
        var warped: [CGPoint] = []
        seat.warpPointer = { warped.append($0); return .success }

        let (result, outcome) = await seat.lendFront { input in
            #expect(input.isActive)
            #expect(input.processID == target.processID)
            let routing = try await input.click(at: point, count: 2, modifiers: [.shift, .option])
            let menu = try await input.rightClick(at: point)
            return (routing, menu, input.marker)
        }

        guard case .completed = outcome else { Issue.record("not completed: \(outcome)"); return }
        let (routing, menu, marker) = try #require(try result?.get())
        for receipt in [routing, menu] {
            #expect(receipt.processID == target.processID)
            #expect(receipt.windowNumber == target.windowNumber)
            #expect(receipt.location == point)
        }
        #expect(sender.sent.count == 2)
        #expect(sender.sent.allSatisfy { $0.correlationID == marker })
        #expect(sender.addressed.allSatisfy { $0.window == target })
        guard case .click(let location, .left, 2) = sender.sent[0].command,
              case .click(let menuLocation, .right, 1) = sender.sent[1].command
        else { Issue.record("not a double left click then a right click: \(sender.sent)"); return }
        let fromTop = CGPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY)
        #expect(location.screenPoint == point && location.windowPointFromTop == fromTop)
        #expect(menuLocation.screenPoint == point && menuLocation.windowPointFromTop == fromTop)

        // The events the driver builds, decorated by the recipe the click was addressed with.
        let modified = try #require(sender.addressed[0].platform as? ModifiedClickPlatform)
        #expect(modified.modifiers == [.shift, .option])
        #expect(!(sender.addressed[1].platform is ModifiedClickPlatform), "a click with no modifiers keeps its recipe")
        var events: [PreparedEvent] = []
        try InputEvents.append(
            sender.sent[0].command,
            source       : try #require(CGEventSource(stateID: .privateState)),
            pacing       : modified.dragPacing,
            correlationID: marker,
            into         : &events
        )
        #expect(events.count == 4)
        for prepared in events {
            modified.decorate(prepared.event, for: sender.sent[0].command)
            #expect(prepared.event.flags == [.maskShift, .maskAlternate], "held on every down and up")
        }

        // Nothing went through the HID stream, so the person's pointer never moved.
        #expect(sensing.cursorLocation == start)
        #expect(warped.isEmpty)
    }

    @Test("a click after the lease ended, or after the body was cancelled, throws and posts nothing")
    func clicksOutsideTheLeaseAreRefused() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let (seat, _, _) = try await BriefActivationTests.seat(sensing: sensing, sender: sender)
        let target = try #require(seat.currentTarget).reference
        Self.listTarget(sensing, target)
        let point = Self.centre(of: target.frame)

        var kept: FrontLeaseInput?
        let ended = await seat.lendFront { input in kept = input }
        guard case .completed = ended.outcome else { Issue.record("not completed: \(ended.outcome)"); return }
        let input = try #require(kept)
        #expect(!input.isActive)
        await #expect(throws: FrontLeaseInput.Refusal.leaseEnded) { try await input.click(at: point) }

        let (result, outcome) = await seat.lendFront(atMost: .milliseconds(300)) { input -> Bool in
            await Self.untilCancelled()
            #expect(!input.isActive)
            do { try await input.rightClick(at: point); return false } catch is CancellationError { return true }
        }

        guard case .boundReached = outcome else { Issue.record("not bounded: \(outcome)"); return }
        #expect(try result?.get() == true, "the cancelled body's click threw a cancellation")
        #expect(sender.sent.isEmpty)
    }

    @Test("a point off the application's windows on the virtual display is refused with nothing posted")
    func pointsOutsideTheApplicationAreRefused() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let (seat, _, _) = try await BriefActivationTests.seat(sensing: sensing, sender: sender)
        let target = try #require(seat.currentTarget).reference
        Self.listTarget(sensing, target)
        // Another process's window on the virtual display, which the lent application does not own.
        let other = FakeGeometry.reference(
            frame       : CGRect(x: FakeGeometry.virtual.minX + 10, y: 10, width: 300, height: 200),
            processID   : FakeGeometry.userPID,
            windowNumber: 902
        )
        sensing.surfaces?.append(WindowSurface(reference: other, level: 0, isVisible: true))
        let points = [
            Self.centre(of: other.frame),
            CGPoint(x: FakeGeometry.virtual.maxX - 5, y: FakeGeometry.virtual.maxY - 5),
            Self.centre(of: BriefActivationTests.user.frame),
        ]

        let (result, outcome) = await seat.lendFront { input -> [FrontLeaseInput.Refusal] in
            var refusals: [FrontLeaseInput.Refusal] = []
            for point in points {
                do { try await input.click(at: point) } catch let refusal as FrontLeaseInput.Refusal {
                    refusals.append(refusal)
                }
            }
            return refusals
        }

        guard case .completed = outcome else { Issue.record("not completed: \(outcome)"); return }
        #expect(try result?.get() == points.map { .outsideApplication($0) })
        #expect(sender.sent.isEmpty)
    }

    @Test("a window the application opened during the lease is its own, and the one in front takes the click")
    func aWindowOpenedDuringTheLeaseIsAccepted() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let (seat, _, _) = try await BriefActivationTests.seat(sensing: sensing, sender: sender)
        let target = try #require(seat.currentTarget).reference
        Self.listTarget(sensing, target)
        let panel = FakeGeometry.reference(
            frame       : CGRect(x: target.frame.minX + 50, y: target.frame.minY + 50, width: 200, height: 150),
            windowNumber: 901
        )
        let point = Self.centre(of: panel.frame)

        let (result, outcome) = await seat.lendFront { input in
            // The application opens a panel over its window, listed in front of it.
            sensing.surfaces?.insert(WindowSurface(reference: panel, level: 3, isVisible: true), at: 0)
            defer { Self.listTarget(sensing, target) }
            return try await input.click(at: point)
        }

        guard case .completed = outcome else { Issue.record("not completed: \(outcome)"); return }
        let receipt = try #require(try result?.get())
        #expect(receipt.windowNumber == panel.windowNumber)
        #expect(receipt.processID == target.processID)
        #expect(sender.addressed.map(\.window) == [panel])
    }

    @Test("the command gate admits the lease's marker while the lease runs, and only then")
    func theGateAdmitsTheLeaseAlone() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let (seat, _, recovery) = try await BriefActivationTests.seat(sensing: sensing, sender: sender)
        seat.installCommandPreparation(on: sender.gate, recovery: recovery)

        let (result, outcome) = await seat.lendFront { input -> Int64 in
            try await sender.gate.prepare(correlationID: input.marker)
            await #expect(throws: InputFailure.inputPaused([.turnChanged])) {
                try await sender.gate.prepare(correlationID: input.marker &+ 1)
            }
            return input.marker
        }

        guard case .completed = outcome else { Issue.record("not completed: \(outcome)"); return }
        let marker = try #require(try result?.get())
        await #expect(throws: InputFailure.inputPaused([.noActionInFlight])) {
            try await sender.gate.prepare(correlationID: marker)
        }
    }

    @Test("a seat with no focus recovery refuses by name and never runs the body")
    func refusesWithoutARecovery() async throws {
        let (seat, _) = try await MultiWindowTests.seat()
        var runs = 0
        let (result, outcome) = await seat.lendFront { runs += 1 }
        #expect(outcome == .refused(.noFocusRecovery))
        #expect(result == nil)
        #expect(runs == 0)
    }
}
