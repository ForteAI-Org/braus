//
//  BrowTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Testing
@testable import Braus

@Suite("Brows")
struct BrowTests {

    @Test("Every outline has 320 points")
    func pointCount() {
        for state in BrowState.allCases {
            #expect(BrowOutlines.bundled.left[state]?.count == 320)
            #expect(BrowOutlines.bundled.right[state]?.count == 320)
        }
    }

    @Test("A brow whose group does not change holds still")
    func holds() {
        let t = BrowTransition.between(.listening, .asking, leftFirst: true)
        #expect(!t.movesLeft && t.movesRight)
    }

    @Test("Calm states stagger, decisive states do not")
    func timing() {
        let calm = BrowTransition.between(.idle, .listening, leftFirst: true)
        #expect(calm.duration == 0.36 && calm.leftDelay == 0 && calm.rightDelay == 0.04)
        let decisive = BrowTransition.between(.idle, .working, leftFirst: false)
        #expect(decisive.duration == 0.23 && decisive.leftDelay == 0 && decisive.rightDelay == 0)
    }
}
