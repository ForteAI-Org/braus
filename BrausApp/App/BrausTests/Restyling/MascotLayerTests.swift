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

    @Test("In a room the brows' top edge catches its light, white below it, never when off")
    func roomLight() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let white  = CGColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        let srgb   = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func components(_ color: CGColor?) throws -> [CGFloat] {
            try #require(color?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components)
        }
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.catchRoomLight(true)

        // The edge: warm, at most `roomLightTint` of the light.
        let edge = try components(mascot.leftBrow.fillColor)
        #expect(edge[0] - edge[2] > 0.2)
        #expect(0xF7 / 255.0 - edge[2] <= MascotLayer.roomLightTint + 1e-6)
        // Below it, half way, then white: green and blue stay near white away from the edge.
        let copies = mascot.lightCopies(of: mascot.leftBrow)
        #expect(copies.count == 2 && copies.allSatisfy { !$0.isHidden && $0.mask != nil })
        let half = try components(copies[0].fillColor)
        #expect(half[2] > edge[2] && half[2] < 0xF7 / 255.0)
        let inner = try components(copies[1].fillColor)
        #expect(abs(inner[1] - 0xF5 / 255.0) < 0.01 && abs(inner[2] - 0xF7 / 255.0) < 0.01)

        // The edge and the half step pulse with the room, phased like it.
        let pulse = try #require(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) as? CAKeyframeAnimation)
        #expect(pulse.keyPath == "fillColor" && pulse.duration == 3.4)
        #expect(pulse.values?.count == RoomLightView.framesPerCycle + 1)
        #expect(pulse.beginTime == RoomLightView.pulseBeginTime(in: mascot.leftBrow))
        #expect(copies[0].animation(forKey: MascotLayer.roomLightKey) != nil)

        // The copies morph with the brow.
        mascot.show(.working, animated: true)
        #expect(copies.allSatisfy { $0.animation(forKey: "path") != nil })
        #expect(copies[1].path == mascot.leftBrow.path)

        RestylingMotion.overrideReducesMotion = true
        mascot.catchRoomLight(true)
        #expect(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) == nil)

        RestylingMotion.overrideReducesMotion = false
        mascot.status = .off
        mascot.catchRoomLight(true)
        #expect(mascot.leftBrow.animation(forKey: MascotLayer.roomLightKey) == nil)
        #expect(copies.allSatisfy { $0.isHidden })
        #expect(mascot.leftBrow.fillColor == CGColor(srgbRed: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x6E / 255.0, alpha: 1))

        mascot.status = .busy
        mascot.catchRoomLight(false)
        #expect(mascot.leftBrow.fillColor == white)
        #expect(copies.allSatisfy { $0.isHidden })
    }

    @Test("Each shape draws its own outline and keeps the brows on its face")
    func shapes() throws {
        var outlines: [CGPath] = []
        var brows   : [WorkerShape: (y: CGFloat, scale: CGFloat)] = [:]
        for shape in WorkerShape.allCases {
            let mascot = makeMascot()
            mascot.shape = shape
            mascot.layoutIfNeeded()
            let outline = try #require(mascot.bodyOutline)
            #expect(!outlines.contains(outline), "\(shape)")
            outlines.append(outline)
            brows[shape] = (mascot.leftBrow.position.y, mascot.leftBrow.transform.m22)
        }
        // The circle is the sphere, filling the 56 point square, with the brows where they were.
        let circle = try #require(outlines.first)
        #expect(abs(circle.boundingBoxOfPath.width - 56) < 0.01 && abs(circle.boundingBoxOfPath.height - 56) < 0.01)
        let round = try #require(brows[.circle])
        #expect(abs(round.y - 56 * (1 - 0.36)) < 1e-9)
        // The triangle's face, its inscribed circle around its low centroid, is smaller and lower.
        let triangle = try #require(brows[.triangle])
        #expect(abs(triangle.scale / round.scale - WorkerShape.triangle.outline.inradius) < 1e-9)
        #expect(triangle.y < round.y)
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
