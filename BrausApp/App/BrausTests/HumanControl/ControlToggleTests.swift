//
//  ControlToggleTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import Foundation
import Testing
@testable import Braus

/// ⌃⌥Tab acts only at rest: Take Control while the worker holds the application, the hand-back
/// while the person holds it, and nothing during any transition between the two.
@Suite("Control toggle shortcut")
struct ControlToggleTests {

    typealias State = ControlToggle.State

    /// The worker holds the application and no handover runs.
    static let workerAtRest = State(holdsApplication: true)

    /// Take Control was pressed and the worker's step is draining.
    static let draining = State(
        holdsApplication: true,
        isUnderway      : true
    )

    /// The windows reached the person's screen; the still has not faded into them yet.
    static let landing = State(
        holdsApplication: true,
        isUnderway      : true,
        isLent          : true,
        asksHandBack    : true
    )

    /// The person holds the application and the worker in the corner waits for Yes.
    static let personAtRest = State(
        holdsApplication: true,
        isUnderway      : true,
        isLent          : true,
        hasLanded       : true,
        asksHandBack    : true
    )

    /// Yes was answered and the take-back has not begun.
    static let answered = State(
        holdsApplication: true,
        isUnderway      : true,
        isLent          : true,
        hasLanded       : true
    )

    /// The take-back, the final read and the report.
    static let finishing = State(
        holdsApplication: true,
        isUnderway      : true,
        isFinishing     : true,
        isLent          : true,
        hasLanded       : true,
        isHandingBack   : true
    )

    /// The application left the person's screen and the curtain says Braus reads what they did.
    static let reading = State(
        holdsApplication : true,
        isUnderway       : true,
        isFinishing      : true,
        isLent           : true,
        hasLanded        : true,
        isHandingBack    : true,
        isReadingHandBack: true
    )

    /// The worker resumed while the screen window's curtain still plays.
    static let curtain = State(
        holdsApplication: true,
        isHandingBack   : true
    )

    @Test func atRestThePressTakesControlOrHandsBack() {
        #expect(ControlToggle.decide(Self.workerAtRest) == .act(.takeControl))
        #expect(ControlToggle.decide(Self.personAtRest) == .act(.handBack))
    }

    @Test func everyTransitionIgnoresThePress() {
        let transitions = [Self.draining, Self.landing, Self.answered, Self.finishing, Self.reading, Self.curtain]
        for state in transitions {
            guard case .ignore(let reason) = ControlToggle.decide(state) else {
                Issue.record("acted during \(state)")
                continue
            }
            #expect(!reason.isEmpty)
        }
        #expect(ControlToggle.decide(Self.finishing) == .ignore("the hand-back curtain is still playing"))
        #expect(ControlToggle.decide(Self.reading) == .ignore("Braus is reading what the person did"))
        var report = Self.finishing
        report.isHandingBack = false
        #expect(ControlToggle.decide(report) == .ignore("the final read and the report are under way"))
    }

    @Test func aBlockedRefusedOrEmptySeatIgnoresThePress() {
        var blocked = Self.draining
        blocked.isBlocked = true
        var refused = Self.draining
        refused.isRefused = true
        for state in [blocked, refused, State()] {
            guard case .ignore = ControlToggle.decide(state) else {
                Issue.record("acted on \(state)")
                continue
            }
        }
    }

    /// Worker, then person, then worker: each rest acts once, every step between is ignored.
    @Test func toggleBothWays() {
        let journey = [
            Self.workerAtRest, Self.draining, Self.landing, Self.personAtRest,
            Self.answered, Self.finishing, Self.reading, Self.curtain, Self.workerAtRest,
        ]
        let acted = journey.compactMap { state -> ControlToggle.Action? in
            if case .act(let action) = ControlToggle.decide(state) { action } else { nil }
        }
        #expect(acted == [.takeControl, .handBack, .takeControl])
    }

    @Test func theTargetIsTheOnlyCandidateTheLentOneOrTheFrontmost() {
        let (one, two, three) = (UUID(), UUID(), UUID())
        #expect(ControlToggle.target(
            among    : [one: State()],
            frontmost: nil
        ).workerID == nil)
        #expect(ControlToggle.target(
            among    : [one: Self.workerAtRest, two: State()],
            frontmost: nil
        ).workerID == one)
        #expect(ControlToggle.target(
            among    : [one: Self.workerAtRest, two: Self.personAtRest],
            frontmost: one
        ).workerID == two)
        #expect(ControlToggle.target(
            among    : [one: Self.workerAtRest, two: Self.workerAtRest, three: Self.workerAtRest],
            frontmost: three
        ).workerID == three)
        let none = ControlToggle.target(
            among    : [one: Self.workerAtRest, two: Self.workerAtRest],
            frontmost: nil
        )
        #expect(none.workerID == nil && none.reason.contains("none of their screen windows"))
    }
}
