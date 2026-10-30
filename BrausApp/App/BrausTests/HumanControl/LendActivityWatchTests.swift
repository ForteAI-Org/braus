//
//  LendActivityWatchTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import SeatBroker
import Testing
@testable import Braus

/// The watch hands the activity policy's decisions on with their reasons, places late evidence by its
/// age, maps the bubble's answers, and says nothing once stopped.
@MainActor
@Suite("Lend activity watch")
struct LendActivityWatchTests {

    /// A process that is never in front.
    private static let lent: pid_t = 1

    @Test("Nothing is decided before the lend lands; a quit then takes back with its reason")
    func quitWaitsForLanding() {
        var decisions: [(LendActivity.Decision, String)] = []
        let watch = LendActivityWatch(
            processID: Self.lent,
            now      : { 10 }
        ) { decisions.append(($0, $1)) }
        watch.receive(.quit)
        #expect(decisions.isEmpty)
        watch.landed()
        #expect(decisions.map(\.0) == [.takeBack(.quit)])
        #expect(decisions.first?.1 == "the application quit")
        watch.stop()
    }

    @Test("Closing every window asks; Yes takes back with the answer in the reason")
    func closedThenYes() {
        var decisions: [(LendActivity.Decision, String)] = []
        let watch = LendActivityWatch(
            processID: Self.lent,
            now      : { 10 }
        ) { decisions.append(($0, $1)) }
        watch.landed()
        watch.receive(.windows(.closed))
        #expect(decisions.map(\.0) == [.ask(.closed)])
        watch.answered(.yes)
        #expect(decisions.map(\.0) == [.ask(.closed), .takeBack(.closed)])
        #expect(decisions.last?.1 == "every window of the application was closed; the person confirmed being done")
        watch.stop()
    }

    @Test("Input that ended before the answer keeps the back-off; later work lifts it")
    func agePlacesLateEvidence() {
        var decisions: [LendActivity.Decision] = []
        var clock = 0.0
        let watch = LendActivityWatch(
            processID: Self.lent,
            now      : { clock }
        ) { decision, _ in decisions.append(decision) }
        watch.landed()
        // Coming to the front is no input: five minutes without any ask.
        clock = 300
        watch.receive(.frontmost(.lent))
        watch.receive(.input(.lent))
        #expect(decisions == [.ask(.away), .withdraw])
        clock = 305
        watch.answered(.no)
        // A typing burst reported at 307 that ended at 304, before the answer.
        clock = 307
        watch.receive(
            .input(.lent),
            age: 3
        )
        clock = 605
        watch.receive(.frontmost(.lent))
        #expect(decisions == [.ask(.away), .withdraw])
        clock = 610
        watch.receive(.input(.lent))
        clock = 910
        watch.receive(.frontmost(.lent))
        #expect(decisions == [.ask(.away), .withdraw, .ask(.away)])
        watch.stop()
    }

    @Test("A stopped watch decides nothing")
    func stoppedIsSilent() {
        var decisions: [LendActivity.Decision] = []
        let watch = LendActivityWatch(
            processID: Self.lent,
            now      : { 10 }
        ) { decision, _ in decisions.append(decision) }
        watch.stop()
        watch.landed()
        watch.receive(.quit)
        watch.answered(.timeout)
        #expect(decisions.isEmpty)
    }
}
