//
//  BubbleFlightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Testing
@testable import Braus

@Suite("BubbleFlight")
@MainActor
struct BubbleFlightTests {

    @Test("A flight and the transcript making room settle in the send flight's time")
    func settlesInTheSendFlight() {
        #expect(abs(BubbleFlight.flightDuration - RestylingTiming.sendFlight) < 0.01)
    }
}
