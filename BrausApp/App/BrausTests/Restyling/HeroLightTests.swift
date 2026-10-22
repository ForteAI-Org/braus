//
//  HeroLightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HeroLight", .serialized)
@MainActor
struct HeroLightTests {

    @Test("The light's tone follows the status and stays soft")
    func toneFollowsStatus() {
        let busy    = HeroLight.tone(for: .busy)
        let free    = HeroLight.tone(for: .free)
        let waiting = HeroLight.tone(for: .waiting)
        let off     = HeroLight.tone(for: .off)
        #expect(busy.red > busy.blue)
        #expect(free.green > free.red && free.green > free.blue)
        #expect(waiting.blue > waiting.red)
        #expect(off.blue > off.red)
        for tone in [busy, free, waiting, off] {
            #expect(tone.alpha >= 0.15 && tone.alpha <= 0.4)
        }
        #expect(off.alpha < busy.alpha)
    }

    @Test("The hosted light takes the status colour, and a change cuts under Reduce Motion")
    func hostedLightFollowsStatus() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let view = HeroLight.HostView()
        view.show(
            .busy,
            animated: false
        )
        #expect(try firstColor(of: view) == expected(.busy))
        view.show(
            .waiting,
            animated: true
        )
        #expect(try firstColor(of: view) == expected(.waiting))
        #expect(view.glow.animationKeys() == nil)
    }

    @Test("The hero shows its worker standing in three quarters, as its room does, lit by its capsule")
    func heroUsesTheTiltedPortrait() throws {
        let worker = HouseFixture.workers[0]
        let (host, window) = Self.host(hero(
            worker,
            status: .busy
        ))
        defer { window.close() }
        let portrait = try #require(find(HouseWorkerPortrait.HostView.self, in: host))
        let room     = try #require(portrait.room)
        #expect(room.uniforms.camera == .tilted)
        #expect(room.uniforms.hasOccupant)
        #expect(room.uniforms.lean == HouseWorkerPortrait.lean)
        #expect(room.uniforms.shape == worker.shape)
        #expect(room.uniforms.status == .busy)
        #expect(room.uniforms.capsuleStrength > 0 && room.uniforms.screenStrength == 0)
        #expect(room.changeFade == HeroLight.fade)
        #expect(portrait.face.mascot.projectedFace != nil)
        #expect(!portrait.face.mascot.drawsBody)
        // No mascot in the hero draws a flat body of its own.
        #expect(all(MascotFace.HostView.self, in: host).allSatisfy { !$0.mascot.drawsBody })
    }

    @Test("Nothing lights the worker from behind: the capsule's glow sits under it, on the capsule's top edge")
    func noLightBehindTheWorker() throws {
        let (host, window) = Self.host(hero(
            HouseFixture.workers[0],
            status: .waiting
        ))
        defer { window.close() }
        let portrait = try #require(find(HouseWorkerPortrait.HostView.self, in: host))
        let worker   = portrait.convert(
            portrait.bounds,
            to: nil
        )
        let glows = all(HeroLight.HostView.self, in: host)
        #expect(glows.count == 1)
        for glow in glows {
            let frame = glow.convert(
                glow.bounds,
                to: nil
            )
            // Window coordinates point up: the glow ends below the worker's foot.
            #expect(frame.maxY <= worker.minY + 0.5, "\(frame) against \(worker)")
            #expect(frame.height < 12)
        }
    }

    @Test("The capsule's light follows the status in the worker's render, and its glow with it")
    func capsuleLightFollowsStatus() throws {
        for status in WorkerStatus.allCases {
            let light = HeroLight.capsuleLight(for: status)
            let tone  = HeroLight.tone(for: status)
            #expect(light.x == Float(tone.red) && light.y == Float(tone.green) && light.z == Float(tone.blue))
            #expect(light.w > 0 && light.w <= 1)
        }
        #expect(HeroLight.capsuleLight(for: .off).w < HeroLight.capsuleLight(for: .free).w)

        let worker = HouseFixture.workers[0]
        let (host, window) = Self.host(hero(
            worker,
            status: .free
        ))
        defer { window.close() }
        for status in [WorkerStatus.busy, .waiting, .off, .free] {
            host.rootView = hero(
                worker,
                status: status
            )
            host.layoutSubtreeIfNeeded()
            let room = try #require(find(HouseWorkerPortrait.HostView.self, in: host)?.room)
            #expect(room.uniforms.status == status)
            #expect(room.uniforms.capsuleLight == HeroLight.capsuleLight(for: status))
            let glow = try #require(find(HeroLight.HostView.self, in: host))
            #expect(try firstColor(of: glow) == expected(status))
        }
    }

    @Test("The hero holds its light, and its name and subtitle sit in an opaque capsule under Reduce Transparency")
    func heroHasLightAndCapsule() throws {
        defer { RestylingMotion.overrideReducesTransparency = nil }
        RestylingMotion.overrideReducesTransparency = true
        let hero = HouseHero(
            worker     : HouseFixture.workers[0],
            status     : .busy,
            brows      : .idle,
            activity   : "Mixing the final cut",
            preparation: 0
        )
        let host = NSHostingView(rootView: hero.frame(
            width : 320,
            height: 160
        ))
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 320,
                height: 160
            ),
            styleMask  : .borderless,
            backing    : .buffered,
            defer      : false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let light = try #require(find(HeroLight.HostView.self, in: host))
        #expect(try firstColor(of: light) == expected(.busy))

        // The opaque capsule paints its tone around the text, which the bare window lacks.
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(
            in : host.bounds,
            to : bitmap
        )
        let tone = try #require(NSColor(
            named : "RestylingOpaqueGlass",
            bundle: Bundle(for: HeroLight.HostView.self)
        )?.usingColorSpace(.sRGB))
        var matching = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(
                    x: x,
                    y: y
                ) else { continue }
                if abs(pixel.redComponent - tone.redComponent) < 0.004
                    && abs(pixel.greenComponent - tone.greenComponent) < 0.004
                    && abs(pixel.blueComponent - tone.blueComponent) < 0.004 {
                    matching += 1
                }
            }
        }
        #expect(matching > 2_000)
    }

    private func hero(
        _ worker: HouseWorker,
        status  : WorkerStatus
    ) -> HouseHero {
        HouseHero(
            worker     : worker,
            status     : status,
            brows      : BrowState(status),
            activity   : "Mixing the final cut",
            preparation: 0
        )
    }

    /// `hero` in a borderless window that is never shown, laid out.
    private static func host(_ hero: HouseHero) -> (NSHostingView<HouseHero>, NSWindow) {
        let host   = NSHostingView(rootView: hero)
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 320,
                height: 200
            ),
            styleMask  : .borderless,
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func all<V: NSView>(
        _ type: V.Type,
        in view: NSView
    ) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private func find<V: NSView>(
        _ type: V.Type,
        in view: NSView,
        where match: (V) -> Bool = { _ in true }
    ) -> V? {
        if let found = view as? V, match(found) { return found }
        for sub in view.subviews {
            if let found = find(type, in: sub, where: match) { return found }
        }
        return nil
    }

    private func expected(_ status: WorkerStatus) -> [Double] {
        let tone = HeroLight.tone(for: status)
        return [tone.red, tone.green, tone.blue, tone.alpha].map { ($0 * 1000).rounded() / 1000 }
    }

    private func firstColor(of view: HeroLight.HostView) throws -> [Double] {
        let colors = try #require(view.glow.colors as? [CGColor])
        let parts  = try #require(colors.first?.components)
        return parts.map { ($0 * 1000).rounded() / 1000 }
    }
}
