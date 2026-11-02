//
//  FrontLeaseTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import SeatCore
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
