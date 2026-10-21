//
//  HouseSidebarTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import MetalKit
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

        // Compact and shallow rooms with the worker at the centre.
        let rooms = [
            CGSize(
                width : 120,
                height: 92
            ),
            CGSize(
                width : 120,
                height: RoomLightTests.shallowRoomHeight
            ),
            CGSize(
                width : 260,
                height: RoomLightTests.shallowRoomHeight
            ),
        ]
        for size in rooms {
            let metrics = Metrics(room: size)
            #expect(metrics.scale == min(size.width, size.height) / 104)
            #expect(metrics.plate.width <= 0.7 * size.width)
            #expect(metrics.showsText)
            #expect(metrics.top + metrics.drop + metrics.plate.height <= size.height - HouseLayout.nameBand)
        }
        // A shallow room leaning left: the plate hangs where the worker stood, clear of the wall and of the name
        // beside it, centred on the row's height.
        let row     = CGSize(
            width : 260,
            height: RoomLightTests.shallowRoomHeight
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

    @Test("The etched text keeps a contrast of at least 4.5:1 over the brightest room behind the glass, in every light")
    func plaqueTextContrast() throws {
        defer { RestylingMotion.overrideReducesTransparency = nil }
        typealias Plaque = HouseAwayPlaque.PlaqueView

        let device = try #require(MTLCreateSystemDefaultDevice())
        var renderers: [any RoomRenderer] = [try #require(PrecomputedRoomRenderer(device: device))]
        if let tracer = RayTracedRoomRenderer(device: device) {
            renderers.append(tracer)
        }
        let room = CGSize(
            width : 127,
            height: 104
        )
        let face = Plaque.Metrics(
            room  : room,
            camera: .tilted
        ).face
        let xs   = face.map { Int($0.x) }
        let ys   = face.map { Int($0.y) }
        for reducesTransparency in [false, true] {
            RestylingMotion.overrideReducesTransparency = reducesTransparency
            for status in WorkerStatus.allCases {
                // The brightest point of the empty room behind the plate on either path; the frost's blur
                // and the material's dark tint only lower it.
                var ground = (red: 0.0, green: 0.0, blue: 0.0)
                for renderer in renderers {
                    let image = try RoomLightTests.render(
                        RoomLightUniforms(
                            status     : status,
                            shape      : .circle,
                            hasOccupant: false,
                            camera     : .tilted
                        ),
                        with  : renderer,
                        size  : room,
                        device: device
                    )
                    for y in (ys.min() ?? 0) ... (ys.max() ?? 0) {
                        for x in (xs.min() ?? 0) ... (xs.max() ?? 0) {
                            let pixel = image.pixel(x, y)
                            let shade = (
                                red  : Double(pixel.red) / 255,
                                green: Double(pixel.green) / 255,
                                blue : Double(pixel.blue) / 255
                            )
                            if Self.luminance(shade.red, shade.green, shade.blue)
                                > Self.luminance(ground.red, ground.green, ground.blue) {
                                ground = shade
                            }
                        }
                    }
                }
                let plaque = Plaque(
                    brows    : .idle,
                    status   : status,
                    isHanging: true,
                    camera   : .tilted
                )
                plaque.frame = CGRect(
                    origin: .zero,
                    size  : room
                )
                plaque.layout()
                let backdrop = CGColor(
                    srgbRed: ground.red,
                    green  : ground.green,
                    blue   : ground.blue,
                    alpha  : 1
                )
                let text  = plaque.textLayer
                let color = try #require(text.fillColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
                let lit = try Self.pixels(
                    of  : plaque.glassLayer,
                    over: backdrop
                )
                text.isHidden = true
                let bare = try Self.pixels(
                    of  : plaque.glassLayer,
                    over: backdrop
                )

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
                    let under = (0..<3).map { Double(bare[index + $0]) / 255 }
                    let over  = (0..<3).map { alpha * ink[$0] + (1 - alpha) * under[$0] }
                    let front = Self.luminance(over[0], over[1], over[2])
                    let back  = Self.luminance(under[0], under[1], under[2])
                    lowest = min(lowest, (max(front, back) + 0.05) / (min(front, back) + 0.05))
                }
                #expect(
                    lowest.isFinite && lowest >= 4.5,
                    "the text's contrast is \(lowest) in a \(status) room, reducing transparency \(reducesTransparency)"
                )
            }
        }
    }

    @Test("Under Reduce Transparency the plate is opaque and nothing of the room shows through it")
    func plaqueReducesTransparency() throws {
        defer { RestylingMotion.overrideReducesTransparency = nil }
        let red  = CGColor(
            srgbRed: 1,
            green  : 0,
            blue   : 0,
            alpha  : 1
        )
        let blue = CGColor(
            srgbRed: 0,
            green  : 0,
            blue   : 1,
            alpha  : 1
        )
        for reducesTransparency in [true, false] {
            RestylingMotion.overrideReducesTransparency = reducesTransparency
            let plaque = HouseAwayPlaque.PlaqueView(
                brows    : .idle,
                status   : .busy,
                isHanging: true,
                camera   : .tilted
            )
            plaque.frame = CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
            plaque.layout()
            #expect(plaque.frostView.isHidden == reducesTransparency)

            // The plate over two different rooms, compared inside its rounded corners, at 2x.
            let overRed  = try Self.pixels(
                of  : plaque.glassLayer,
                over: red
            )
            let overBlue = try Self.pixels(
                of  : plaque.glassLayer,
                over: blue
            )
            let plate  = plaque.glassLayer.bounds.size
            let inset  = Int(2 * HouseAwayPlaque.PlaqueView.Metrics.cornerRadius)
            let width  = Int(2 * plate.width)
            var shows  = false
            for y in inset ..< Int(2 * plate.height) - inset {
                for x in inset ..< width - inset {
                    let index = (y * width + x) * 4
                    if overRed[index ..< index + 3] != overBlue[index ..< index + 3] { shows = true }
                }
            }
            #expect(shows == !reducesTransparency)
        }
    }

    @Test("The glass's light, the light through it and its lit top pulse with the room, on the room's cycle and phase")
    func plaquePulsesWithTheRoom() {
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
        for status in WorkerStatus.allCases {
            let plaque = Plaque(
                brows    : .idle,
                status   : status,
                isHanging: false,
                camera   : .tilted
            )
            window.contentView?.addSubview(plaque)
            plaque.isHanging = true
            let weights = RoomLightView.pulseWeights(
                for          : status,
                reducesMotion: false
            )
            for layer in [plaque.lightLayer, plaque.castLayer, plaque.rimLayer] {
                let pulse = layer.animation(forKey: Plaque.pulseKey) as? CAKeyframeAnimation
                guard let first = weights.first, let cycle = RoomLightView.pulseCycle(for: status) else {
                    // A light that holds still, or none: the plate holds still too.
                    #expect(pulse == nil)
                    continue
                }
                #expect(pulse?.keyPath == "opacity")
                #expect((pulse?.values as? [NSNumber])?.map(\.floatValue) == weights + [first])
                #expect(pulse?.duration == cycle)
                // Phased to the host clock, as the room's own pulse frames are.
                let begin = layer.convertTime(
                    pulse?.beginTime ?? 0,
                    to: nil
                )
                #expect(abs(begin - RoomLightView.pulseBeginTime(in: nil)) < 1e-6)
            }
            plaque.removeFromSuperview()
        }
    }

    @Test("Through the tilted camera the plate hangs where the worker stood, its text legible, its top showing and its shadow on the floor")
    func plaqueInPerspective() throws {
        typealias Metrics = HouseAwayPlaque.PlaqueView.Metrics

        // A room on the floor plan, a compact one, a shallow room and a wide one leaning left.
        let rooms: [(size: CGSize, lean: Float)] = [
            (
                CGSize(
                    width : 127,
                    height: 104
                ),
                0
            ),
            (
                CGSize(
                    width : 120,
                    height: 92
                ),
                0
            ),
            (
                CGSize(
                    width : 120,
                    height: RoomLightTests.shallowRoomHeight
                ),
                0
            ),
            (
                CGSize(
                    width : 260,
                    height: RoomLightTests.shallowRoomHeight
                ),
                1
            ),
        ]
        func middle(_ points: [CGPoint]) -> CGPoint {
            CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
            )
        }
        for (size, lean) in rooms {
            let metrics = Metrics(
                room  : size,
                camera: .tilted,
                lean  : lean
            )
            let bodyX = RoomLightUniforms.Shape.bodyX(
                in  : size,
                lean: lean
            )
            let xs    = metrics.face.map(\.x)
            let ys    = metrics.face.map(\.y)
            let name  = "\(size) leaning \(lean)"
            // In the room, centred where the worker stood, and above the name under it.
            #expect((xs.min() ?? -1) >= 0 && (xs.max() ?? .infinity) <= size.width, "\(name)")
            #expect((ys.min() ?? -1) > 0, "\(name)")
            #expect(abs(((xs.min() ?? 0) + (xs.max() ?? 0)) / 2 - bodyX) < 1, "\(name)")
            if lean == 0 {
                #expect((ys.max() ?? .infinity) <= size.height - HouseLayout.nameBand, "\(name)")
            }
            // Leaning toward the camera enough that the 9-point text keeps at least 90% of its height.
            let height = (metrics.face[0].y - metrics.face[3].y + metrics.face[1].y - metrics.face[2].y) / 2
            #expect(height >= 0.9 * metrics.plate.height && height < metrics.plate.height, "\(name)")
            // The slab's top shows above its face.
            let rim = try #require(metrics.rim)
            #expect((rim.map(\.y).min() ?? 0) < (ys.min() ?? 0) - 0.5, "\(name)")
            // Its shadow falls on the floor toward the camera, below it.
            #expect(middle(metrics.shadow).y > middle(metrics.face).y, "\(name)")
            // It turns about where its cords leave through the opening's top edge, above it.
            #expect(metrics.top == 0, "\(name)")
            #expect(abs(metrics.nailX - bodyX) < 1, "\(name)")
            #expect(metrics.cords.allSatisfy { ($0.last?.y ?? 0) < 0 }, "\(name)")
        }

        // A room before its first layout places the plate nowhere strange.
        let empty = Metrics(
            room  : .zero,
            camera: .tilted
        )
        let pivot = CGPoint(
            x: empty.nailX,
            y: empty.top
        )
        #expect((empty.face + [pivot]).allSatisfy { $0.x.isFinite && $0.y.isFinite })

        // From above it hangs flat from its nail, with no top showing.
        let flat = Metrics(room: CGSize(
            width : 127,
            height: 104
        ))
        #expect(flat.rim == nil)
        #expect(flat.face[0].y - flat.face[3].y == flat.plate.height)
    }

    @Test("A plaque in a room too small for its plate lays out without one, from either camera")
    func plaqueInATinyRoom() {
        for camera in [RoomCamera.top, .tilted] {
            for lean in [Float(0), 1] {
                let plaque = HouseAwayPlaque.PlaqueView(
                    brows    : .idle,
                    status   : .busy,
                    isHanging: true,
                    camera   : camera,
                    lean     : lean
                )
                plaque.frame = CGRect(
                    x     : 0,
                    y     : 0,
                    width : 12,
                    height: 12
                )
                plaque.layout()
                #expect(plaque.glassLayer.bounds.width <= 12)
            }
        }
    }

    @Test("The plate's face is mapped exactly onto its corners as the room's camera shows them")
    func plaqueFaceTransform() {
        let plate = CGSize(
            width : 88,
            height: 30
        )
        let quads = [
            // Seen in perspective, wider at the top.
            [
                CGPoint(
                    x: 20,
                    y: 10
                ),
                CGPoint(
                    x: 104,
                    y: 10
                ),
                CGPoint(
                    x: 108,
                    y: 38
                ),
                CGPoint(
                    x: 16,
                    y: 38
                ),
            ],
            // Flat, only moved.
            [
                CGPoint(
                    x: 20,
                    y: 10
                ),
                CGPoint(
                    x: 108,
                    y: 10
                ),
                CGPoint(
                    x: 108,
                    y: 40
                ),
                CGPoint(
                    x: 20,
                    y: 40
                ),
            ],
        ]
        let corners = [
            CGPoint.zero,
            CGPoint(
                x: plate.width,
                y: 0
            ),
            CGPoint(
                x: plate.width,
                y: plate.height
            ),
            CGPoint(
                x: 0,
                y: plate.height
            ),
        ]
        for quad in quads {
            let matrix = HouseAwayPlaque.PlaqueView.Metrics.transform(
                mapping: plate,
                to     : quad
            )
            for (corner, expected) in zip(corners, quad) {
                let weight = corner.x * matrix.m14 + corner.y * matrix.m24 + matrix.m44
                let x      = (corner.x * matrix.m11 + corner.y * matrix.m21 + matrix.m41) / weight
                let y      = (corner.x * matrix.m12 + corner.y * matrix.m22 + matrix.m42) / weight
                #expect(abs(x - expected.x) < 1e-6 && abs(y - expected.y) < 1e-6)
            }
        }
    }

    /// `layer` drawn at 2x over `backdrop` into sRGB bytes, red, green, blue and alpha.
    private static func pixels(
        of layer: CALayer,
        over backdrop: CGColor
    ) throws -> [UInt8] {
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
        context.setFillColor(backdrop)
        context.fill(CGRect(
            x     : 0,
            y     : 0,
            width : width,
            height: height
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

        let sequence: [HouseWorker?] = workers[1...3].map { $0 } + [nil, workers.first]
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
        var worker: HouseWorker?
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
