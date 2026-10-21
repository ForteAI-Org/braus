//
//  HeroActionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import QuartzCore
import Testing
@testable import Braus

@Suite("HeroAction", .serialized)
@MainActor
struct HeroActionTests {

    private static let size = CGSize(
        width : 127,
        height: 127
    )

    @Test("Each action is a loop of poses within the body's limits: reading and working never rest, the reply hops")
    func actions() {
        for action in WorkerAction.allCases {
            let keys = action.keys
            #expect(keys.first?.time == 0 && keys.last?.time == action.duration, "\(action)")
            #expect(keys.first?.pose == keys.last?.pose, "\(action): the loop closes")
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0.time < $1.time })
            #expect(keys.allSatisfy { $0.pose.isAllowed }, "\(action)")
        }
        #expect(WorkerAction.reading.keys.allSatisfy { $0.pose.lean > 0 })
        #expect(WorkerAction.working.keys.allSatisfy { $0.pose.lean > 0 })
        #expect(WorkerAction.working.keys.filter { $0.pose.stretch < 0 }.count >= 4)
        #expect(WorkerAction.thinking.keys.contains { $0.pose.tilt < 0 } && WorkerAction.thinking.keys.contains { $0.pose.tilt > 0 })
        #expect(WorkerAction.replying.keys.contains { $0.pose.hop > 0 })
    }

    @Test("A hero room bakes every action ahead, plays one on its own clock, and cross-fades to the next")
    func roomActs() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let window   = Self.window()
        defer { window.close() }
        let (view, mascot, link) = try Self.hero(in: window)
        // Every action's poses are baked once the room is at rest, before any is asked for.
        let acted = Set(WorkerAction.allCases.flatMap { action in
            RoomLightView.bodyMotion(
                for          : action,
                uniforms     : view.uniforms,
                size         : Self.size,
                reducesMotion: false
            )?.poses ?? []
        })
        try await Self.until { acted.isSubset(of: Set(view.bodyFrames.keys)) }

        link.act(.working)
        let motion = try #require(view.bodyMotion)
        #expect(motion == RoomLightView.bodyMotion(
            for          : .working,
            uniforms     : view.uniforms,
            size         : Self.size,
            reducesMotion: false
        ))
        let envelope = try #require(view.bodyLayer.animation(forKey: RoomLightView.bodyKey) as? CAKeyframeAnimation)
        #expect(abs(envelope.beginTime - view.bodyLayer.convertTime(link.actionStart, from: nil)) < 1e-6)
        #expect(envelope.duration == WorkerAction.working.duration)
        // Working leans toward the screen the whole loop round.
        #expect((envelope.values as? [Double])?.allSatisfy { $0 == 1 } == true)
        #expect(mascot.animation(forKey: MascotLayer.bodyKey) != nil)

        try await Task.sleep(for: .milliseconds(200))
        link.act(.replying)
        #expect(view.bodyMotion?.duration == WorkerAction.replying.duration)
        #expect(!view.bodyFade.isHidden)
        #expect(view.bodyFade.animation(forKey: RoomLightView.bodyKey) != nil)
        #expect(mascot.animation(forKey: "body.blend.shift") != nil)

        // Back to the idle loop, on the brows' clock.
        link.act(nil)
        let idle = try #require(view.bodyLayer.animation(forKey: RoomLightView.bodyKey))
        #expect(abs(idle.beginTime - view.bodyLayer.convertTime(link.start, from: nil)) < 1e-6)
    }

    @Test("Under Reduce Motion the hero takes no action")
    func reduceMotion() async throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let window = Self.window()
        defer { window.close() }
        let (view, mascot, link) = try Self.hero(in: window)
        try await Self.until { view.renderCounts.full >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        link.act(.reading)
        #expect(view.bodyMotion == nil)
        #expect(view.bodyLayer.animation(forKey: RoomLightView.bodyKey) == nil)
        #expect(mascot.animation(forKey: MascotLayer.bodyKey) == nil)
        #expect(view.bodyRenders == 0)
    }

    // MARK: - Helpers

    /// A busy hero's room in `window`, with its brows playing their loop and a link that takes actions.
    private static func hero(in window: NSWindow) throws -> (RoomLightView, MascotLayer, RoomBodyLink) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: RoomLightUniforms(
                status     : .busy,
                shape      : .circle,
                hasOccupant: true,
                camera     : .tilted,
                lean       : HouseWorkerPortrait.lean,
                screenLit  : true
            ),
            frame   : CGRect(
                origin: .zero,
                size  : size
            )
        )
        let mascot = MascotLayer()
        mascot.frame  = CGRect(
            x     : 0,
            y     : 0,
            width : 60,
            height: 60
        )
        mascot.status = .busy
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(mascot)
        mascot.behave(seed: 3)
        let link = RoomBodyLink()
        link.browsDidBehave(mascot)
        link.room = view
        link.act(nil)
        window.contentView?.addSubview(view)
        return (view, mascot, link)
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
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
    }
}
