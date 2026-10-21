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
            #expect(tone.alpha >= 0.1 && tone.alpha <= 0.2)
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
        #expect(view.glow.animation(forKey: "breathe") == nil)
    }

    @Test("The hero holds its light, and its name and subtitle sit in an opaque capsule under Reduce Transparency")
    func heroHasLightAndCapsule() throws {
        defer { RestylingMotion.overrideReducesTransparency = nil }
        RestylingMotion.overrideReducesTransparency = true
        let hero = HouseHero(
            worker     : MockHouse.sample.workers[0],
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
