//
//  HouseTimingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("HouseTiming", .serialized)
@MainActor
struct HouseTimingTests {

    @Test("Timings match the motion table")
    func timings() {
        #expect(HouseTiming.ringBuildFirst == 2.0 && HouseTiming.ringBuildLater == 0.45)
        #expect(HouseTiming.dotsGlow == 1.35 && HouseTiming.preparation == 0.55)
        #expect(HouseTiming.zoneTravel == 0.5 && HouseTiming.zoneSpread == 0.55)
        #expect(HouseTiming.taskWindowGrow == 0.6)
        #expect(HouseTiming.toMenuBar == 0.48 && HouseTiming.fromMenuBar == 0.52)
        #expect(HouseTiming.sendFlight == 0.56 && HouseTiming.quoteFlight == 0.52)
        #expect(HouseTiming.browsCalm == 0.36 && HouseTiming.browsDecisive == 0.23)
        #expect(HouseTiming.browStagger == 0.04)
        #expect(HouseTiming.roomFlicker == 3.4 && HouseTiming.waitingBreath == 2.2)
        #expect(HouseTiming.headBreath == 6.5)
    }

    @Test("The overrides decide motion and transparency on their own")
    func overrides() {
        defer {
            HouseMotion.overrideReducesMotion       = nil
            HouseMotion.overrideReducesTransparency = nil
        }
        HouseMotion.overrideReducesMotion       = true
        HouseMotion.overrideReducesTransparency = false
        #expect(HouseMotion.reducesMotion)
        #expect(!HouseMotion.reducesTransparency)
        HouseMotion.overrideReducesMotion       = false
        HouseMotion.overrideReducesTransparency = true
        #expect(!HouseMotion.reducesMotion)
        #expect(HouseMotion.reducesTransparency)
    }
}
