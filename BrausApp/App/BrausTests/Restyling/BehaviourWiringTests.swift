//
//  BehaviourWiringTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore
import Testing
@testable import Braus

@Suite("BehaviourWiring", .serialized)
@MainActor
struct BehaviourWiringTests {

    private let worker = HouseWorker(
        id        : UUID(),
        name      : "Test",
        status    : .busy,
        activity  : "Working",
        role      : "Tester",
        category  : .general,
        shape     : .circle,
        badge     : nil,
        usesScreen: true
    )

    @Test("A room gives its worker's seed, and none while the worker is away in chat")
    func roomSeed() {
        #expect(HouseRoomCell.behaviourSeed(of: worker, isSelected: false) == WorkerBehaviour.seed(for: worker.id))
        #expect(HouseRoomCell.behaviourSeed(of: worker, isSelected: true) == nil)
    }

    @Test("The hero gives the worker's seed while its brows are the status's own, and none otherwise")
    func heroSeed() {
        let seed = WorkerBehaviour.seed(for: worker.id)
        #expect(HouseHero.behaviourSeed(of: worker, status: .busy, brows: .working) == seed)
        #expect(HouseHero.behaviourSeed(of: worker, status: .free, brows: .idle) == seed)
        #expect(HouseHero.behaviourSeed(of: worker, status: .free, brows: .listening) == nil)
    }

    @Test("The shifts scale with the face the room shows")
    func shiftsScale() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.status = .free
        mascot.behave(seed: 4)
        let flat = try shifts(of: mascot)

        let other = makeMascot()
        other.status        = .free
        other.projectedFace = RoomCamera.Face(
            anchor: CGVector(dx: 0, dy: 0),
            xScale: 0.5,
            yScale: 2
        )
        other.behave(seed: 4)
        let tilted = try shifts(of: other)

        #expect(flat.count == tilted.count)
        #expect(flat.contains { abs($0.x) > 0.01 })
        #expect(flat.contains { abs($0.y) > 0.01 })
        for (before, after) in zip(flat, tilted) {
            #expect(abs(after.x - before.x * 0.5) < 1e-6)
            #expect(abs(after.y - before.y * 2) < 1e-6)
        }
    }

    @Test("A change of face size rebuilds the loop in step, scaled to it")
    func sizeRebuilds() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.behave(seed: 6)
        clearBlends(mascot)
        let before = try shifts(of: mascot)
        let start  = try #require(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey)).beginTime

        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 112,
            height: 112
        )
        mascot.refreshBehaviourScale()
        let after = try shifts(of: mascot)
        for (small, large) in zip(before, after) {
            #expect(abs(large.x - small.x * 2) < 1e-6)
            #expect(abs(large.y - small.y * 2) < 1e-6)
        }
        let loop = try #require(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey))
        #expect(loop.beginTime == start)
        #expect(loop.repeatCount == .infinity)
    }

    @Test("The rebuild fires once the size settles, by itself")
    func debounced() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.status = .free
        // A window never ordered in commits its layers, as a real one does.
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 200,
                height: 200
            ),
            styleMask  : .borderless,
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(mascot)
        mascot.behave(seed: 8)
        clearBlends(mascot)
        let before = try shifts(of: mascot)
        for width in [60.0, 70, 80, 112] {
            mascot.frame = CGRect(
                x     : 0,
                y     : 0,
                width : width,
                height: width
            )
        }
        #expect(try shifts(of: mascot) == before)
        try await Task.sleep(for: .milliseconds(500))
        let after = try shifts(of: mascot)
        #expect(zip(before, after).allSatisfy { abs($1.x - $0.x * 2) < 1e-6 })
    }

    @Test("No rebuild under Reduce Motion or without a loop")
    func quiet() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.behave(seed: 2)
        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 112,
            height: 112
        )
        mascot.refreshBehaviourScale()
        #expect(mascot.leftBrow.animationKeys() == nil)

        RestylingMotion.overrideReducesMotion = false
        let away = makeMascot()
        away.behave(seed: nil)
        away.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 112,
            height: 112
        )
        away.refreshBehaviourScale()
        #expect(away.leftBrow.animationKeys() == nil)
    }

    /// The left brow's loop shifts, in points.
    private func shifts(of mascot: MascotLayer) throws -> [CGPoint] {
        let animation = try #require(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) as? CAKeyframeAnimation)
        return try #require(animation.values as? [NSValue]).map(\.pointValue)
    }

    /// Drops the status change's blend, which a detached layer never finishes.
    private func clearBlends(_ mascot: MascotLayer) {
        for brow in [mascot.leftBrow, mascot.rightBrow] {
            brow.removeAnimation(forKey: MascotLayer.blendPositionKey)
            brow.removeAnimation(forKey: MascotLayer.blendRotationKey)
        }
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
