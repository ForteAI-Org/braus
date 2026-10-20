//
//  MascotLayerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import QuartzCore
import Testing
@testable import Braus

@Suite("MascotLayer", .serialized)
@MainActor
struct MascotLayerTests {

    @Test("A calm change morphs both brows with a stagger")
    func calmMorph() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.show(.idle, animated: false)
        mascot.show(.listening, animated: true)

        let left  = try #require(mascot.leftBrow.animation(forKey: "path") as? CABasicAnimation)
        let right = try #require(mascot.rightBrow.animation(forKey: "path") as? CABasicAnimation)
        #expect(left.keyPath == "path" && right.keyPath == "path")
        #expect(left.duration == 0.36 && right.duration == 0.36)
        #expect(abs(right.beginTime - left.beginTime - 0.04) < 1e-9)
    }

    @Test("Reduce Motion cuts instead of morphing")
    func reduceMotionCuts() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let mascot = makeMascot()
        mascot.show(.idle, animated: false)
        mascot.show(.working, animated: true)

        #expect(mascot.leftBrow.animationKeys() == nil)
        #expect(mascot.rightBrow.animationKeys() == nil)
        let left  = try #require(BrowOutlines.bundled.left[.working])
        let right = try #require(BrowOutlines.bundled.right[.working])
        #expect(mascot.leftBrow.path == MascotLayer.path(left))
        #expect(mascot.rightBrow.path == MascotLayer.path(right))
    }

    @Test("Reduce Motion stops breathing")
    func reduceMotionStopsBreathing() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let still = makeMascot()
        still.startBreathing()
        #expect(still.animation(forKey: "breathe") == nil)

        RestylingMotion.overrideReducesMotion = false
        let breathing = makeMascot()
        breathing.startBreathing()
        #expect(breathing.animation(forKey: "breathe") != nil)
    }

    private func makeMascot() -> MascotLayer {
        let mascot = MascotLayer()
        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 56,
            height: 56
        )
        return mascot
    }
}
