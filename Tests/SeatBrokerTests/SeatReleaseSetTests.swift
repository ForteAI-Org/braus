//
//  SeatReleaseSetTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import SeatCore
import SeatSession
import Testing
@testable import SeatBroker

@Test @MainActor func aWindowIsOnlyOffTheSeatWhenItWentHomeOrIsGone() {
    #expect(SeatDriver.isHome(.returned))
    #expect(SeatDriver.isHome(.vanished))
    #expect(!SeatDriver.isHome(.refused))
    #expect(!SeatDriver.isHome(.leftOnVirtualDisplay))
}

@Test @MainActor func aReleasedSetIsHomeOnlyWhenEveryWindowInItIs() {
    // Nothing released yet is not evidence that anything is out there: the
    // seat's own pending restorations answer that, separately.
    #expect(!SeatDriver.leavesWindowUnrestored([]))
    #expect(!SeatDriver.leavesWindowUnrestored([.returned, .returned, .vanished]))

    // The application this decides about is the one with several windows, so
    // the windows that did make it home must not speak for the one that did
    // not: terminating its owner is what the whole order exists to prevent.
    #expect(SeatDriver.leavesWindowUnrestored([.returned, .refused, .returned]))
    #expect(SeatDriver.leavesWindowUnrestored([.returned, .leftOnVirtualDisplay]))
    #expect(SeatDriver.leavesWindowUnrestored([.refused]))
}

@Test @MainActor func anObligationWithoutARefusedOutcomeDoesNotStopTheQuit() {
    let driver = SeatDriver()
    let born   = WindowIdentity(
        process          : ProcessIdentity(processID: 7, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber     : 4_401,
        ownerConnectionID: 3
    )
    // A window born on the display, or another lifetime's return, is not a refusal of this app.
    driver.lastObligations = [AssignmentObligation(identity: born, owedFrame: nil, reason: .noDestinationInUserSeat)]
    driver.lastReleases    = [.returned]
    #expect(!driver.hasUnrestoredWindow)
    #expect(driver.canRetireHost(), "with no seat nothing can be left on a display")

    driver.lastReleases = [.returned, .leftOnVirtualDisplay]
    #expect(driver.hasUnrestoredWindow)
    #expect(!driver.canRetireHost())
}

@Test @MainActor func aFinishWarningAloneDoesNotKeepTheHost() async {
    var stops = 0
    let stop: () async -> String? = { stops += 1; return nil }

    let warned = await AgentSession.endingLease(finish: "still running", canRetire: true, stop: stop)
    #expect(warned == "still running")
    #expect(stops == 1, "an app left running is not a window left out")

    let owed = await AgentSession.endingLease(finish: "still running", canRetire: false, stop: stop)
    #expect(owed == "still running")
    #expect(stops == 1, "a return the host still owes keeps it")

    let both = await AgentSession.endingLease(finish: "still running", canRetire: true) { "display left" }
    #expect(both == "still running display left")
    #expect(await AgentSession.endingLease(finish: nil, canRetire: true, stop: stop) == nil)
    #expect(stops == 2)
}
