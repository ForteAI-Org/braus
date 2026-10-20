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

    @Test("Looking right morphs both brows together in 0.2 s")
    func pointerLook() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.look(
            yaw  : 0.5,
            pitch: 0
        )

        let left  = try #require(mascot.leftBrow.animation(forKey: "path") as? CABasicAnimation)
        let right = try #require(mascot.rightBrow.animation(forKey: "path") as? CABasicAnimation)
        #expect(left.duration == 0.2 && right.duration == 0.2)
        #expect(left.beginTime == right.beginTime)
        let look = try #require(BrowOutlines.bundled.left[.look])
        #expect(mascot.leftBrow.path == MascotLayer.path(look))
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

    @Test("In a room the brows take a faint pulsing tint of its light, never when off")
    func roomLight() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let white  = CGColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.catchRoomLight(true)
        let fill = try #require(mascot.leftBrow.fillColor?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components)
        // Warmer than white, by at most the tint's share.
        #expect(fill[0] > fill[2])
        #expect(abs(fill[0] - 0xF5 / 255.0) <= MascotLayer.roomLightTint + 1e-6)
        let pulse = try #require(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) as? CAKeyframeAnimation)
        #expect(pulse.keyPath == "fillColor" && pulse.duration == 3.4)
        #expect(pulse.values?.count == RoomLightView.framesPerCycle + 1)
        #expect(pulse.beginTime == RoomLightView.pulseBeginTime(in: mascot.leftBrow))
        #expect(mascot.rightBrow.animation(forKey: MascotLayer.roomLightKey) != nil)

        RestylingMotion.overrideReducesMotion = true
        mascot.catchRoomLight(true)
        #expect(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) == nil)

        RestylingMotion.overrideReducesMotion = false
        mascot.status = .off
        mascot.catchRoomLight(true)
        #expect(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) == nil)
        #expect(mascot.leftBrow.fillColor == CGColor(srgbRed: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x6E / 255.0, alpha: 1))

        mascot.status = .busy
        mascot.catchRoomLight(false)
        #expect(mascot.leftBrow.fillColor == white)
        #expect(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) == nil)
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
