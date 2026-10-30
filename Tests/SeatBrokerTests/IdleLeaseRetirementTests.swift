//
//  IdleLeaseRetirementTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/10/2026.
//

import Foundation
import Testing
@testable import SeatBroker

/// A clean lease keeps its host for `idleRetirementDelay` and retires it then (ADR 0030).
/// The driver here has no seat, so every finish is clean and the stops are counted.
@MainActor
@Suite("Idle lease retirement")
struct IdleLeaseRetirementTests {

    @MainActor
    private final class Stops {
        var count = 0
        var finished = 0
    }

    /// A session whose host stops are counted, retired after `delay`; `holding` keeps each stop
    /// suspended that long, so a test can act while a teardown is under way.
    private static func session(
        of broker: SeatBroker = SeatBroker(),
        retiringAfter delay: Duration = .milliseconds(50),
        holding: Duration = .zero
    ) -> (AgentSession, Stops) {
        let session = broker.openSession()
        let stops   = Stops()
        configure(session, stops, delay: delay, holding: holding)
        return (session, stops)
    }

    private static func configure(_ session: AgentSession, _ stops: Stops, delay: Duration, holding: Duration) {
        session.idleRetirementDelay = delay
        session.stopHost = {
            stops.count += 1
            if holding > .zero { try? await Task.sleep(for: holding) }
            stops.finished += 1
            return nil
        }
    }

    private static func wait(within limit: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a clean lease keeps its host, and the retirement takes it down once the delay passes")
    func aCleanLeaseRetiresItsHostAfterTheDelay() async {
        let (session, stops) = Self.session()
        #expect(await session.finishUsingApp() == nil)
        #expect(stops.count == 0, "a clean lease took its display down at once")

        await Self.wait(within: .seconds(2)) { stops.count > 0 }
        #expect(stops.count == 1)
        #expect(session.isOpen, "retiring the host closed the reusable session")
    }

    @Test("a new lease before the delay cancels the retirement and is handed the same session")
    func aNewLeaseCancelsThePendingRetirement() async throws {
        let broker = SeatBroker()
        let stops  = Stops()
        let first  = try await broker.queue.acquire("first")
        let session = first.session
        Self.configure(session, stops, delay: .milliseconds(100), holding: .zero)
        _ = await session.finishUsingApp()
        first.giveBack()

        let second = try await broker.queue.acquire("second")
        #expect(second.session === session, "the queue did not hand the parked session back")
        try await Task.sleep(for: .milliseconds(400))
        #expect(stops.count == 0, "a retirement woke under a later lease and took its host down")
        second.giveBack()
        await broker.queue.shutdown()
        #expect(stops.count == 1, "closing the parked session at shutdown did not stop its host once")
    }

    @Test("a close during the delay stops once, and the retirement does nothing afterwards")
    func aCloseDuringTheDelayStopsOnce() async throws {
        let (session, stops) = Self.session()
        _ = await session.finishUsingApp()
        #expect(await session.close() == nil)
        #expect(stops.count == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(stops.count == 1, "the retirement stopped a host the close had already taken down")
    }

    @Test("a close after the retirement, or while it is under way, stops nothing more")
    func aCloseAfterTheRetirementStopsNothingMore() async {
        let (session, stops) = Self.session(retiringAfter: .milliseconds(10), holding: .milliseconds(200))
        _ = await session.finishUsingApp()
        await Self.wait(within: .seconds(2)) { stops.count > 0 }
        #expect(stops.finished == 0, "the teardown was not under way when the close began")
        _ = await session.close()
        #expect(stops.finished == 1, "the close did not wait for the teardown under way")
        #expect(stops.count == 1, "the host was stopped twice")
    }

    @Test("a new lease waits for a teardown already under way before anything adopts")
    func aNewLeaseWaitsForATeardownUnderWay() async {
        let (session, stops) = Self.session(retiringAfter: .milliseconds(10), holding: .milliseconds(200))
        _ = await session.finishUsingApp()
        await Self.wait(within: .seconds(2)) { stops.count > 0 }
        await session.beginLease()
        #expect(stops.finished == 1, "the lease began while its host was still going down")
        // The host went down after the last lease, so this lease's close stops it again.
        _ = await session.close()
        #expect(stops.count == 2)
    }
}
