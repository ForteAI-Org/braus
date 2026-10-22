//
//  RoomPassageTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import QuartzCore
import Testing
@testable import Braus

@Suite("RoomPassage", .serialized)
@MainActor
struct RoomPassageTests {

    private static let size = CGSize(
        width : 127,
        height: 104
    )

    @Test("Leaving, the worker holds still while its brows look, then steps out toward the camera and fades; coming back reverses it")
    func choreography() {
        let leaving  = RoomPassage(
            isLeaving    : true,
            shape        : .circle,
            size         : Self.size,
            lean         : 0,
            reducesMotion: false
        )
        let duration = HouseTiming.roomExit
        #expect(leaving.duration == duration)
        #expect(leaving.poses.first == .rest)
        #expect(leaving.poses.count == RoomPassage.steps + 1)
        #expect(leaving.keyframes.first == RoomPassage.Keyframe(time: 0, pose: 0, opacity: 1))
        #expect(leaving.keyframes[1] == RoomPassage.Keyframe(time: RoomPassage.lookShare * duration, pose: 0, opacity: 1))
        #expect(leaving.keyframes.last?.time == duration)
        #expect(leaving.keyframes.last?.opacity == 0)
        // Out toward the camera, smaller as it goes, hopping on the way.
        let moving = leaving.poses.dropFirst()
        #expect(zip(moving, moving.dropFirst()).allSatisfy { $0.slide < $1.slide && $0.scale > $1.scale })
        #expect(moving.allSatisfy { $0.hop >= 0 && $0.tilt == 0 })
        #expect(moving.contains { $0.hop > 0 })
        let opacities = leaving.keyframes.map(\.opacity)
        #expect(zip(opacities, opacities.dropFirst()).allSatisfy { $0 >= $1 })
        // The brows follow the face down and toward the camera, smaller with the body.
        #expect(leaving.faceShifts.first == .zero && leaving.faceScales.first == 1)
        #expect(leaving.faceScales.dropFirst().allSatisfy { $0 < 1 })

        let entering = RoomPassage(
            isLeaving    : false,
            shape        : .circle,
            size         : Self.size,
            lean         : 0,
            reducesMotion: false
        )
        #expect(entering.poses == leaving.poses)
        #expect(entering.keyframes.count == leaving.keyframes.count)
        for (coming, going) in zip(entering.keyframes, leaving.keyframes.reversed()) {
            #expect(abs(coming.time - (duration - going.time)) < 1e-9)
            #expect(coming.pose == going.pose && coming.opacity == going.opacity)
        }
        #expect(entering.keyframes.last == RoomPassage.Keyframe(time: duration, pose: 0, opacity: 1))
    }

    @Test("Under Reduce Motion the worker and its brows only fade")
    func reduceMotionFades() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = true
        let passage = RoomPassage(
            isLeaving    : true,
            shape        : .circle,
            size         : Self.size,
            lean         : 0,
            reducesMotion: true
        )
        #expect(passage.poses == [.rest])
        #expect(passage.keyframes == [
            RoomPassage.Keyframe(time: 0, pose: 0, opacity: 1),
            RoomPassage.Keyframe(time: HouseTiming.roomExit, pose: 0, opacity: 0),
        ])
        let mascot = MascotLayer()
        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 56,
            height: 56
        )
        mascot.followPassage(
            passage,
            from: CACurrentMediaTime()
        )
        #expect(mascot.animationKeys() == ["passage.fade"])
        #expect(mascot.leftBrow.animationKeys()?.contains { $0.hasPrefix("passage") } != true)
    }

    @Test("A room at rest bakes its exit ahead, and choosing its worker plays it at once, the full render after it and the plaque")
    func exitBakedAhead() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let window = Self.window()
        defer { window.close() }
        let (view, mascot) = try Self.room(in: window)
        try await Self.until { view.passageFrames != nil }
        try await Task.sleep(for: .milliseconds(100))
        let settled = view.renderCounts
        let chosen  = ContinuousClock.now
        let baked   = try #require(view.passageFrames)
        // A busy light pulses: every pose of the way out, and the empty room, at full light and at its dimmest.
        #expect(baked.poses.count == RoomPassage.steps + 1 && baked.poses.values.allSatisfy { $0.count == 2 })
        #expect(baked.empty.count == 2)

        view.uniforms = Self.room(hasOccupant: false)
        // The baked passage plays at once, over the live frame of the empty room; the brows start with it.
        let passage = try #require(view.passage)
        #expect(passage.isLeaving)
        #expect(view.passageRenders == 1)
        #expect(!view.passageLayer.isHidden && view.passageEmpty.contents != nil)
        #expect(!view.passageWorkerLit.isHidden)
        let frames = try #require(view.passageWorker.animation(forKey: RoomLightView.passageKey) as? CAKeyframeAnimation)
        #expect(frames.duration == HouseTiming.roomExit)
        #expect(frames.values?.count == passage.keyframes.count)
        #expect(view.passageSnapshot.isHidden)
        #expect(mascot.animation(forKey: "passage.fade") != nil)
        #expect(mascot.animation(forKey: "passage.shift") != nil)
        #expect(mascot.leftBrow.animation(forKey: "passage.look.position") != nil)
        try await Self.until { view.renderCounts.live == settled.live + 1 }

        try await Self.until { view.renderCounts.full == settled.full + 1 }
        #expect(ContinuousClock.now - chosen >= .seconds(HouseTiming.roomExit) + .milliseconds(850))
        #expect(view.passage == nil)
        #expect(view.passageLayer.isHidden)
    }

    @Test("Chosen before its exit is baked, the worker's body still steps out, then the fresh frames take over")
    func exitBeforeBaking() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let window = Self.window()
        defer { window.close() }
        let (view, mascot) = try Self.room(in: window)
        try await Self.until { view.renderCounts.full >= 1 && view.shownImage != nil }
        try #require(view.passageFrames == nil, "the exit was baked before the test could choose the worker")

        view.uniforms = Self.room(hasOccupant: false)
        // The body's image steps out on Core Animation alone, with the brows.
        #expect(!view.passageSnapshot.isHidden)
        #expect(view.passageSnapshot.mask != nil)
        let carry = try #require(view.passageSnapshot.animation(forKey: RoomLightView.passageKey) as? CAKeyframeAnimation)
        let poses = try #require(carry.values as? [NSValue]).map(\.caTransform3DValue)
        #expect(poses.contains { !CATransform3DIsIdentity($0) })
        #expect(view.passageSnapshot.animation(forKey: RoomLightView.passageFadeKey) != nil)
        #expect(mascot.animation(forKey: "passage.fade") != nil)

        try await Self.until { view.passageWorker.animation(forKey: RoomLightView.passageKey) != nil }
        #expect(view.passageSnapshot.isHidden)
        #expect(view.passageRenders == 1)
    }

    @Test("Coming back, the worker steps in once the plaque has faded")
    func entryWaitsForThePlaque() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let view   = RoomLightView(
            device  : device,
            uniforms: Self.room(hasOccupant: false),
            frame   : CGRect(
                origin: .zero,
                size  : Self.size
            )
        )
        window.contentView?.addSubview(view)
        try await Self.until { view.renderCounts.full >= 1 }
        try await Task.sleep(for: .milliseconds(300))

        let back = CACurrentMediaTime()
        view.uniforms = Self.room(hasOccupant: true)
        #expect(view.passage?.isLeaving == false)
        try await Self.until { view.passageWorker.animation(forKey: RoomLightView.passageFadeKey) != nil }
        let fade = try #require(view.passageWorker.animation(forKey: RoomLightView.passageFadeKey))
        let begin = view.passageWorker.convertTime(fade.beginTime, to: nil)
        #expect(abs(begin - (back + HouseTiming.plaqueLeave)) < 0.02)
        // Until then the worker is not there.
        #expect(fade.fillMode == .backwards)
        #expect((fade as? CAKeyframeAnimation)?.values?.first as? Double == 0)
    }

    @Test("The plaque drops in only once the worker is out, and fades away before it comes back")
    func plaqueAfterTheExit() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        typealias Plaque = HouseAwayPlaque.PlaqueView
        #expect(HouseRoomCell.plaqueDelay(for: .tilted) == HouseTiming.roomExit)
        #expect(HouseRoomCell.plaqueDelay(for: .top) == 0)

        let plaque = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: false,
            camera   : .tilted,
            dropDelay: HouseTiming.roomExit
        )
        let window = Self.window()
        defer { window.close() }
        window.contentView?.addSubview(plaque)
        let chosen = ContinuousClock.now
        plaque.isHanging = true
        #expect(plaque.swingLayer.isHidden)
        #expect(plaque.dropTask != nil)
        try await Self.until { !plaque.swingLayer.isHidden }
        #expect(ContinuousClock.now - chosen >= .seconds(HouseTiming.roomExit))
        #expect(plaque.swingLayer.animation(forKey: Plaque.swingKey) != nil)

        plaque.isHanging = false
        #expect(!plaque.swingLayer.isHidden)
        #expect(plaque.swingLayer.animation(forKey: Plaque.fadeKey) != nil)
        try await Self.until { plaque.swingLayer.isHidden }

        // Taken down before it dropped, it never shows.
        plaque.isHanging = true
        plaque.isHanging = false
        try await Task.sleep(for: .seconds(HouseTiming.roomExit + 0.1))
        #expect(plaque.swingLayer.isHidden)
    }

    // MARK: - Helpers

    /// A busy worker's tilted room in `window`, with the brows over it playing their loop.
    private static func room(in window: NSWindow) throws -> (RoomLightView, MascotLayer) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: room(hasOccupant: true),
            frame   : CGRect(
                origin: .zero,
                size  : size
            )
        )
        let mascot = MascotLayer()
        mascot.frame  = CGRect(
            x     : 0,
            y     : 0,
            width : 56,
            height: 56
        )
        mascot.status = .busy
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(mascot)
        mascot.behave(seed: 7)
        let link = RoomBodyLink()
        link.browsDidBehave(mascot)
        link.room = view
        window.contentView?.addSubview(view)
        links.append(link)
        return (view, mascot)
    }

    /// Keeps each test's link alive, as the views hold it weakly.
    private static var links: [RoomBodyLink] = []

    private static func room(hasOccupant: Bool) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : .busy,
            shape      : .circle,
            hasOccupant: hasOccupant,
            camera     : .tilted,
            screenLit  : true
        )
    }

    /// A borderless window that is never shown, so nothing reaches the screen or takes input.
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 400,
                height: 300
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
    }
}
