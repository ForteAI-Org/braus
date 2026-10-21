//
//  HouseSidebarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseSidebar")
@MainActor
struct HouseSidebarTests {

    @Test("Rooms use two columns unless the sidebar is compact")
    func columns() {
        #expect(HouseLayout.columns(sidebarWidth: 280) == 2)
        #expect(HouseLayout.columns(sidebarWidth: 140) == 1)
    }

    @Test("The sidebar mode defaults to rooms")
    func defaultMode() {
        #expect(SidebarMode(preference: nil) == .rooms)
        #expect(SidebarMode(preference: "unknown") == .rooms)
        #expect(SidebarMode(preference: AppPreferences.restylingSidebarModeDefault) == .rooms)
        #expect(SidebarMode(preference: "rows") == .rows)
    }

    @Test("The preference values read the sidebar mode from the defaults")
    func preferenceValuesReadTheMode() throws {
        let name     = "HouseSidebarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(AppPreferenceValues(defaults: defaults).restylingSidebarMode == .rooms)

        defaults.set(
            "rows",
            forKey: AppPreferences.restylingSidebarMode
        )
        #expect(AppPreferenceValues(defaults: defaults).restylingSidebarMode == .rows)
    }

    @Test("The selected room says its worker is in chat with you")
    func selectedRoomLabel() throws {
        let worker = try #require(MockHouse.sample.workers.first)
        #expect(HouseRoomCell.spokenLabel(
            for       : worker,
            isSelected: true
        ) == "Delivery, in chat with you")
        #expect(!HouseRoomCell.spokenLabel(
            for       : worker,
            isSelected: false
        ).contains("in chat with you"))
    }

    @Test("A row's label carries the worker's name and subtitle, and that it is in chat with you once chosen")
    func rowLabel() throws {
        let workers = MockHouse.sample.workers
        let first   = try #require(workers.first)
        #expect(HouseRoomCell.spokenRowLabel(
            for       : first,
            isSelected: false
        ) == "Delivery, Exports the stems")
        #expect(HouseRoomCell.spokenRowLabel(
            for       : first,
            isSelected: true
        ) == "Delivery, Exports the stems, in chat with you")
        for worker in workers {
            #expect(HouseRoomCell.spokenRowLabel(
                for       : worker,
                isSelected: false
            ) == "\(worker.name), \(worker.subtitle)")
        }
    }

    @Test("The plaque swings down when its worker is chosen, only fades in under Reduce Motion, and hangs still when rebuilt")
    func plaqueSwing() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        RestylingMotion.overrideReducesMotion = false
        let swinging = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: false
        )
        #expect(swinging.swingLayer.isHidden)
        swinging.isHanging = true
        #expect(!swinging.swingLayer.isHidden)
        let swing = swinging.swingLayer.animation(forKey: Plaque.swingKey) as? CASpringAnimation
        #expect(swing?.stiffness == 120 && swing?.damping == 9)
        // A gentle swing: it still moves at half a second and is still, under a fifth of a degree, by 1.1 seconds.
        let drop = try #require(swinging.swing)
        #expect(abs(drop.state(at: drop.start + 0.5).angle) > 0.2 * .pi / 180)
        let settled = stride(
            from   : 1.1,
            through: 3,
            by     : 0.01
        ).allSatisfy { abs(drop.state(at: drop.start + $0).angle) < 0.2 * .pi / 180 }
        #expect(settled)

        // A plaque made for a room that is already empty, as when the sidebar is rebuilt.
        let rebuilt = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: true
        )
        #expect(!rebuilt.swingLayer.isHidden)
        #expect(rebuilt.swingLayer.animation(forKey: Plaque.swingKey) == nil)

        RestylingMotion.overrideReducesMotion = true
        let still = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: false
        )
        still.isHanging = true
        #expect(still.swingLayer.animation(forKey: Plaque.swingKey) == nil)
        #expect(still.swingLayer.animation(forKey: Plaque.fadeKey) != nil)
    }

    @Test("Behind a nail moving left the plate keeps its foot to the right, within its clamp, and never under Reduce Motion")
    func plaqueTilt() {
        typealias Plaque = HouseAwayPlaque.PlaqueView
        let lean = Plaque.maximumLean * Plaque.maximumTilt

        // Positive is counterclockwise on screen: the foot of a plate hanging from its nail swings right.
        let left = Plaque.tilt(
            forAnchorVelocity: -120,
            reducesMotion    : false
        )
        #expect(left > 0)
        func tilt(_ velocity: Double) -> Double {
            Plaque.tilt(
                forAnchorVelocity: velocity,
                reducesMotion    : false
            )
        }
        #expect(tilt(120) == -left)
        #expect(tilt(-1_000_000) == lean)
        #expect(tilt(1_000_000) == -lean)
        let still = Plaque.tilt(
            forAnchorVelocity: -120,
            reducesMotion    : true
        )
        #expect(still == 0)
    }

    @Test("A plate whose nail moves left lags, then swings past rest to the left and settles, within its clamp")
    func plaquePendulum() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        RestylingMotion.overrideReducesMotion = false
        for speed in [300.0, 20_000] {
            let plaque = Plaque(
                brows    : .idle,
                status   : .busy,
                isHanging: true
            )
            // The nail read at 120 Hz for a quarter of a second.
            for step in 0...30 {
                plaque.nailMoved(
                    to: 400 - CGFloat(Double(step) * speed / 120),
                    at: Double(step) / 120
                )
            }
            let moving = try #require(plaque.swing)
            #expect(moving.state(at: 0.26).angle > 0)

            plaque.nailStopped(at: 0.3)
            let released = try #require(plaque.swing)
            let angles   = stride(
                from    : 0.3,
                through : 2.5,
                by      : 0.002
            ).map { released.state(at: $0).angle }
            #expect((angles.min() ?? 0) < -0.005)
            #expect(angles.allSatisfy { abs($0) <= Plaque.maximumTilt + 1e-9 })
            #expect(abs(released.state(at: 2.5).angle) < 0.002)
        }

        RestylingMotion.overrideReducesMotion = true
        let still = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: true
        )
        for step in 0...30 {
            still.nailMoved(
                to: 400 - CGFloat(step) * 3,
                at: Double(step) / 120
            )
        }
        still.nailStopped(at: 0.3)
        #expect(still.swing == nil)
        #expect(still.swingLayer.animation(forKey: Plaque.swingKey) == nil)
    }

    @Test("Every swing Core Animation plays starts at the speed the plaque's model gives it")
    func plaqueSwingsAgree() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        RestylingMotion.overrideReducesMotion = false
        let plaque = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: false
        )
        plaque.isHanging = true
        #expect(Self.swingsAgree(plaque))
        for step in 0...12 {
            plaque.nailMoved(
                to: 400 - CGFloat(step) * 4,
                at: Double(step) / 120
            )
        }
        #expect(Self.swingsAgree(plaque))
        plaque.nailStopped(at: 0.2)
        #expect(Self.swingsAgree(plaque))
    }

    /// Whether the rotation spring on `plaque` runs from and to the angles of the plaque's own
    /// swing, at the swing's starting speed.
    private static func swingsAgree(_ plaque: HouseAwayPlaque.PlaqueView) -> Bool {
        let key = HouseAwayPlaque.PlaqueView.swingKey
        guard
            let swing  = plaque.swing,
            let spring = plaque.swingLayer.animation(forKey: key) as? CASpringAnimation,
            let from   = (spring.fromValue as? NSNumber)?.doubleValue,
            let to     = (spring.toValue as? NSNumber)?.doubleValue
        else { return false }
        return from == swing.from && to == swing.target
            && abs(spring.initialVelocity * (to - from) - swing.velocity) < 1e-9
    }

    @Test("Only a hanging plaque pulses with its room's light")
    func plaquePulsesOnlyWhenHanging() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        RestylingMotion.overrideReducesMotion = false
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 200,
                height: 200
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let plaque = Plaque(
            brows    : .idle,
            status   : .busy,
            isHanging: false
        )
        window.contentView?.addSubview(plaque)
        #expect(plaque.lightLayer.animation(forKey: Plaque.pulseKey) == nil)
        plaque.isHanging = true
        #expect(plaque.lightLayer.animation(forKey: Plaque.pulseKey) != nil)
        plaque.isHanging = false
        #expect(plaque.lightLayer.animation(forKey: Plaque.pulseKey) == nil)
    }

    @Test("The plaque follows the room's short side, keeps to 70% of its width, and drops its text where it cannot fit")
    func plaqueSize() {
        typealias Metrics = HouseAwayPlaque.PlaqueView.Metrics

        let room = Metrics(room: CGSize(
            width : 127,
            height: 104
        ))
        #expect(room.scale == 1)
        #expect(room.plate.width == 88)
        #expect(room.showsText)

        // The compact rooms, a compact row and a wide one with the worker at the centre.
        let rooms = [
            CGSize(
                width : 120,
                height: 92
            ),
            CGSize(
                width : 120,
                height: HouseLayout.rowHeight
            ),
            CGSize(
                width : 260,
                height: HouseLayout.rowHeight
            ),
        ]
        for size in rooms {
            let metrics = Metrics(room: size)
            #expect(metrics.scale == min(size.width, size.height) / 104)
            #expect(metrics.plate.width <= 0.7 * size.width)
            #expect(metrics.showsText)
            #expect(metrics.top + metrics.drop + metrics.plate.height <= size.height - HouseLayout.nameBand)
        }
        // A row leaning left: the plate hangs where the worker stood, clear of the wall and of the name
        // beside it, centred on the row's height.
        let row     = CGSize(
            width : 260,
            height: HouseLayout.rowHeight
        )
        let leaning = Metrics(
            room: row,
            lean: 1
        )
        let worker  = RoomLightUniforms.Shape(
            size: row,
            lean: 1
        )
        #expect(leaning.nailX == CGFloat(worker.bodyX))
        #expect(leaning.nailX - leaning.plate.width / 2 >= Metrics.wallMargin)
        let place   = CGFloat(worker.bodyX) + CGFloat(worker.sphereRadius) + HouseLayout.nameGap / 2
        #expect(leaning.nailX + leaning.plate.width / 2 <= place + 1e-9)
        #expect(abs(2 * leaning.top + leaning.drop + leaning.plate.height - row.height) < 1e-9)
        #expect(Metrics(room: row).nailX == row.width / 2)

        let narrow = Metrics(room: CGSize(
            width : 87,
            height: 104
        ))
        #expect(!narrow.showsText)
        #expect(narrow.plate.width <= 0.7 * 87)

        // A room narrowing a point at a time shrinks the plate by no more than that, but where the text goes.
        var previous = Metrics(room: CGSize(
            width : 160,
            height: 104
        ))
        for width in stride(from: 159.0, through: 80, by: -1) {
            let metrics = Metrics(room: CGSize(
                width : width,
                height: 104
            ))
            if metrics.showsText == previous.showsText {
                #expect(previous.plate.width - metrics.plate.width <= 1.01)
            }
            previous = metrics
        }
    }

    @Test("The plaque catches the room's light, and none in the room of a worker that is off")
    func plaqueLight() {
        let lit = HouseAwayPlaque.PlaqueView(
            brows    : .idle,
            status   : .waiting,
            isHanging: true
        )
        #expect(!lit.lightLayer.isHidden)
        let off = HouseAwayPlaque.PlaqueView(
            brows    : .idle,
            status   : .off,
            isHanging: true
        )
        #expect(off.lightLayer.isHidden)
        off.status = .busy
        #expect(!off.lightLayer.isHidden)
    }

    @Test("The plaque's text keeps a contrast of at least 4.5:1 in every room's light, at its brightest")
    func plaqueTextContrast() throws {
        for status in WorkerStatus.allCases {
            let plaque = HouseAwayPlaque.PlaqueView(
                brows    : .idle,
                status   : status,
                isHanging: true
            )
            plaque.frame = CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
            plaque.layout()
            let text  = try #require(Self.textLayer(in: plaque.swingLayer))
            let color = try #require(((text.string as? NSAttributedString)?.attribute(
                .foregroundColor,
                at            : 0,
                effectiveRange: nil
            ) as? NSColor)?.usingColorSpace(.sRGB))
            let lit = try Self.pixels(of: plaque.swingLayer)
            text.isHidden = true
            let bare = try Self.pixels(of: plaque.swingLayer)

            // The text's colour laid over each pixel it covers, against that pixel bare.
            let alpha  = Double(color.alphaComponent)
            let ink    = [color.redComponent, color.greenComponent, color.blueComponent].map(Double.init)
            var lowest = Double.infinity
            let covered = stride(
                from: 0,
                to  : lit.count,
                by  : 4
            ).filter { lit[$0 ..< $0 + 3] != bare[$0 ..< $0 + 3] }
            for index in covered {
                let ground = (0..<3).map { Double(bare[index + $0]) / 255 }
                let over   = (0..<3).map { alpha * ink[$0] + (1 - alpha) * ground[$0] }
                let front  = Self.luminance(over[0], over[1], over[2])
                let back   = Self.luminance(ground[0], ground[1], ground[2])
                lowest = min(lowest, (max(front, back) + 0.05) / (min(front, back) + 0.05))
            }
            #expect(lowest.isFinite && lowest >= 4.5, "the text's contrast is \(lowest) in a \(status) room")
        }
    }

    private static func textLayer(in layer: CALayer) -> CATextLayer? {
        if let text = layer as? CATextLayer { return text }
        return layer.sublayers?.lazy.compactMap { textLayer(in: $0) }.first
    }

    /// `layer` drawn at 2x into sRGB bytes, red, green, blue and alpha.
    private static func pixels(of layer: CALayer) throws -> [UInt8] {
        let width  = Int(layer.bounds.width * 2)
        let height = Int(layer.bounds.height * 2)
        var bytes  = [UInt8](
            repeating: 0,
            count    : width * height * 4
        )
        let space   = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data            : &bytes,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : width * 4,
            space           : space,
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(
            x: 2,
            y: 2
        )
        layer.render(in: context)
        return bytes
    }

    /// The relative luminance of an sRGB colour, components in 0...1, as WCAG defines it.
    private static func luminance(
        _ red  : Double,
        _ green: Double,
        _ blue : Double
    ) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    @Test("The house window never asks for less than all its columns, and its sidebar does not collapse")
    func sidebarStays() async throws {
        #expect(RestylingWindowView.columnVisibility == .all)

        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 600
            ),
            styleMask  : [.titled, .resizable],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: NavigationSplitView(
            columnVisibility: .constant(RestylingWindowView.columnVisibility)
        ) {
            Color.clear.background(SidebarBridge())
        } detail: {
            Color.clear
        })
        let deadline = ContinuousClock.now + .seconds(2)
        var sidebar: NSSplitViewItem?
        while sidebar?.canCollapse != false {
            try #require(ContinuousClock.now < deadline, "the sidebar's split item still collapses")
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
            sidebar = Self.splitControllers(in: window.contentView).first?.splitViewItems.first
        }
        let controller = try #require(Self.splitControllers(in: window.contentView).first)
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(sidebar?.isCollapsed == false)
    }

    @Test("Choosing another worker keeps the window's toolbar items, which the detail column would otherwise rebuild")
    func toolbarStaysAcrossWorkers() async throws {
        let workers = MockHouse.sample.workers
        let choice  = Choice()
        choice.worker = workers.first

        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 600
            ),
            styleMask  : [.titled, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DetailHost(choice: choice))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host

        let deadline = ContinuousClock.now + .seconds(2)
        while (window.toolbar?.items.count ?? 0) == 0 {
            try #require(ContinuousClock.now < deadline, "no toolbar appeared")
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let before = window.toolbar?.items.map(\.itemIdentifier) ?? []

        let sequence: [MockWorker?] = workers[1...3].map { $0 } + [nil, workers.first]
        for worker in sequence {
            choice.worker = worker
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.toolbar?.items.map(\.itemIdentifier) == before, "after showing \(worker?.name ?? "no worker")")
        }
    }

    /// Choice is the worker a test's detail column shows.
    @Observable
    final class Choice {
        var worker: MockWorker?
    }

    /// DetailHost is the house window's split with its detail column and a toolbar item there.
    private struct DetailHost: View {
        let choice: Choice

        @FocusState private var isFocused: Bool

        var body: some View {
            NavigationSplitView {
                Color.clear
            } detail: {
                HouseDetail(
                    worker           : choice.worker,
                    isComposerFocused: $isFocused
                )
                .toolbar {
                    ToolbarItem {
                        Button(
                            "Inspector",
                            systemImage: "info.circle"
                        ) {}
                    }
                }
            }
        }
    }

    private static func splitControllers(in view: NSView?) -> [NSSplitViewController] {
        guard let view else { return [] }
        let own = ((view as? NSSplitView)?.delegate as? NSSplitViewController).map { [$0] } ?? []
        return own + view.subviews.flatMap { splitControllers(in: $0) }
    }
}
