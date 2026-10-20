//
//  RestylingTimingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("RestylingTiming", .serialized)
@MainActor
struct RestylingTimingTests {

    @Test("Timings match the motion table")
    func timings() {
        #expect(RestylingTiming.ringBuildFirst == 2.0 && RestylingTiming.ringBuildLater == 0.45)
        #expect(RestylingTiming.dotsGlow == 1.35 && RestylingTiming.preparation == 0.55)
        #expect(RestylingTiming.zoneTravel == 0.5 && RestylingTiming.zoneSpread == 0.55)
        #expect(RestylingTiming.taskWindowGrow == 0.6)
        #expect(RestylingTiming.toMenuBar == 0.48 && RestylingTiming.fromMenuBar == 0.52)
        #expect(RestylingTiming.sendFlight == 0.56 && RestylingTiming.quoteFlight == 0.52)
        #expect(RestylingTiming.browsCalm == 0.36 && RestylingTiming.browsDecisive == 0.23)
        #expect(RestylingTiming.browStagger == 0.04)
        #expect(RestylingTiming.roomFlicker == 3.4 && RestylingTiming.waitingBreath == 2.2)
        #expect(RestylingTiming.headBreath == 6.5)
    }

    @Test("The overrides decide motion and transparency on their own")
    func overrides() {
        defer {
            RestylingMotion.overrideReducesMotion       = nil
            RestylingMotion.overrideReducesTransparency = nil
        }
        RestylingMotion.overrideReducesMotion       = true
        RestylingMotion.overrideReducesTransparency = false
        #expect(RestylingMotion.reducesMotion)
        #expect(!RestylingMotion.reducesTransparency)
        RestylingMotion.overrideReducesMotion       = false
        RestylingMotion.overrideReducesTransparency = true
        #expect(!RestylingMotion.reducesMotion)
        #expect(RestylingMotion.reducesTransparency)
    }
}
