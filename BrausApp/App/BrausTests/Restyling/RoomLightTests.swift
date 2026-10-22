//
//  RoomLightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import MetalKit
import QuartzCore
import Testing
import simd
@testable import Braus

@Suite("RoomLight", .serialized)
@MainActor
struct RoomLightTests {

    /// The original shallow-room fixture, independent of the compact card row's height.
    static let shallowRoomHeight: CGFloat = 72

    @Test("Without hardware ray tracing the light is precomputed")
    func pathChoice() {
        func choose(_ isAppleFamily9: Bool, _ supportsRaytracing: Bool, _ override: String?) -> LightingPath {
            LightingPath.choose(
                isAppleFamily9    : isAppleFamily9,
                supportsRaytracing: supportsRaytracing,
                override          : override
            )
        }
        // M3 and later.
        #expect(choose(true, true, nil) == .rayTraced)
        #expect(choose(true, true, "precomputed") == .precomputed)
        #expect(choose(true, true, "raytraced") == .rayTraced)
        // M1 and M2, Intel and AMD GPUs: Metal reports ray tracing, traced in software.
        #expect(choose(false, true, nil) == .precomputed)
        #expect(choose(false, true, "raytraced") == .precomputed)
        #expect(choose(false, false, "raytraced") == .precomputed)
    }

    @Test("This GPU's path follows its family")
    func devicePath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let path   = LightingPath.choose(
            for     : device,
            override: nil
        )
        #expect(path == (device.supportsFamily(.apple9) && device.supportsRaytracing ? .rayTraced : .precomputed))
    }

    @Test("Uniforms follow the status")
    func uniforms() {
        let busy = room(.busy)
        #expect(busy.strength == 1)
        #expect(busy.lightColor == SIMD3<Float>(1, 176.0 / 255, 72.0 / 255))
        #expect(room(.off).strength == 0)
        // Ten float4 in RoomLight.metal.
        #expect(MemoryLayout<RoomLightUniforms.Packed>.stride == 160)
    }

    @Test("The uniforms carry the worker's shape and no tint")
    func shapeNotTint() {
        let uniforms = RoomLightUniforms(
            status     : .busy,
            shape      : .triangle,
            hasOccupant: true
        )
        let packed = uniforms.packed(
            size      : CGSize(width: 128, height: 104),
            pixelWidth: 256
        )
        let labels = Mirror(reflecting: uniforms).children.compactMap(\.label)
            + Mirror(reflecting: packed).children.compactMap(\.label)
        #expect(labels.contains("shape") && labels.contains("outline"))
        #expect(!labels.contains { $0.lowercased().contains("tint") })
        #expect(packed.outline == WorkerShape.triangle.outline.packed)
        #expect(packed.body == SIMD4(
            Float(WorkerShape.triangle.outline.dome),
            Float(WorkerShape.triangle.outline.bottom),
            0,
            1
        ))
    }

    @Test("The circle's body is the sphere it was, and every body faces up at its centre")
    func circleIsTheSphere() throws {
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let size     = CGSize(width: 128, height: 104)
        let radius   = RoomLightUniforms.Shape.centreSphereShare * Float(size.height)
        let centre   = SIMD2(Float(size.width) / 2, Float(size.height) / 2)
        // A grid across the sphere and a little past its silhouette.
        let offsets  = stride(from: -1.1, through: 1.1, by: 0.1).flatMap { x in
            stride(from: -1.1, through: 1.1, by: 0.1).map { y in SIMD2(Float(x), Float(y)) }
        }
        let normals = try bodyNormals(
            room(.busy),
            at    : offsets.map { centre + radius * $0 },
            size  : size,
            device: device
        )
        for (offset, normal) in zip(offsets, normals) {
            // Today's sphere normal, as RoomLight.metal computed it before the shapes.
            let disc   = offset / max(1, simd_length(offset))
            let sphere = SIMD3(disc, (max(0, 1 - simd_dot(disc, disc))).squareRoot())
            #expect(simd_distance(normal, sphere) < 1e-3, "at \(offset): \(normal) against \(sphere)")
        }
        for shape in WorkerShape.allCases {
            let up = try bodyNormals(
                RoomLightUniforms(
                    status     : .busy,
                    shape      : shape,
                    hasOccupant: true
                ),
                at    : [centre],
                size  : size,
                device: device
            )
            #expect(up.first.map { $0.z > 0.999 } == true, "\(shape)")
        }
    }

    @Test("The view renders on demand")
    func onDemand() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: room(.busy)
        )
        #expect(view.isPaused == true)
        #expect(view.enableSetNeedsDisplay == true)
        #expect(view.path != nil)
    }

    @Test("A different uniforms value requests a render, the same one does not")
    func uniformsRequestRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: room(.busy)
        )
        let before = view.requestedRenders
        view.uniforms = room(.busy)
        #expect(view.requestedRenders == before)
        view.uniforms = room(.waiting)
        #expect(view.requestedRenders == before + 1)
    }

    @Test("A resized room shows its last image scaled by the short side and centred, so the sphere fits the brows")
    func resizedRoomKeepsTheSphere() {
        let unit = CGRect(
            x     : 0,
            y     : 0,
            width : 1,
            height: 1
        )
        #expect(RoomLightView.contentsRect(
            rendered: nil,
            bounds  : CGSize(width: 127, height: 104)
        ) == unit)
        #expect(RoomLightView.contentsRect(
            rendered: CGSize(width: 127, height: 104),
            bounds  : CGSize(width: 127, height: 104)
        ) == unit)
        let resizes: [(rendered: CGSize, bounds: CGSize)] = [
            (CGSize(width: 97, height: 104), CGSize(width: 157, height: 104)),
            (CGSize(width: 157, height: 104), CGSize(width: 97, height: 104)),
            (CGSize(width: 127, height: 104), CGSize(width: 120, height: 92)),
            (CGSize(width: 260, height: 104), CGSize(width: 320, height: 104))
        ]
        for resize in resizes {
            let rect = RoomLightView.contentsRect(
                rendered: resize.rendered,
                bounds  : resize.bounds
            )
            // The sphere is a share of the short side, so it must grow by the short side's change in both axes.
            let wanted = min(resize.bounds.width, resize.bounds.height) / min(resize.rendered.width, resize.rendered.height)
            #expect(abs(resize.bounds.width / (rect.width * resize.rendered.width) - wanted) < 1e-9)
            #expect(abs(resize.bounds.height / (rect.height * resize.rendered.height) - wanted) < 1e-9)
            #expect(abs(rect.midX - 0.5) < 1e-9)
            #expect(abs(rect.midY - 0.5) < 1e-9)
        }
        // A row leaning left keeps its worker where the room puts it, at the left, as the row resizes.
        let rows: [(rendered: CGSize, bounds: CGSize)] = [
            (CGSize(width: 260, height: 72), CGSize(width: 300, height: 72)),
            (CGSize(width: 260, height: 72), CGSize(width: 200, height: 60)),
        ]
        for resize in rows {
            let rect = RoomLightView.contentsRect(
                rendered    : resize.rendered,
                bounds      : resize.bounds,
                renderedLean: 1,
                lean        : 1
            )
            let placed = RoomLightUniforms.Shape.bodyX(
                in  : resize.bounds,
                lean: 1
            ) / resize.bounds.width
            let shown  = RoomLightUniforms.Shape.bodyX(
                in  : resize.rendered,
                lean: 1
            ) / resize.rendered.width
            #expect(abs(rect.minX + placed * rect.width - shown) < 1e-9)
            #expect(abs(rect.midY - 0.5) < 1e-9)
        }
        // A compact row's image, its worker at the centre, shows its worker at the left once the row leans.
        let reshaped = RoomLightView.contentsRect(
            rendered    : CGSize(width: 120, height: 72),
            bounds      : CGSize(width: 200, height: 72),
            renderedLean: 0,
            lean        : 1
        )
        #expect(abs(reshaped.minX + 36 / 200 * reshaped.width - 0.5) < 1e-9)
    }

    @Test("While its size changes a room draws one precomputed frame per coalesced change, and the full render once it settles")
    func liveFramesWhileResizing() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let view = RoomLightView(
            device  : device,
            uniforms: room(.busy),
            frame   : CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
        )
        window.contentView?.addSubview(view)
        try await until { view.renderCounts.full >= 1 }
        // Lets the first render's completion and pulse land.
        try await Task.sleep(for: .milliseconds(300))
        let settled = view.renderCounts

        resize(
            view,
            width: 140
        )
        #expect(view.renderCounts == RoomLightView.RenderCounts(
            live   : settled.live + 1,
            preview: settled.preview,
            full   : settled.full
        ))
        // Both arrive while the first live frame is in flight: one frame follows, at the last size.
        resize(
            view,
            width: 150
        )
        resize(
            view,
            width: 160
        )
        #expect(view.renderCounts.live == settled.live + 1)
        try await until { view.renderCounts.live == settled.live + 2 }
        #expect(view.renderCounts.preview == settled.preview)
        #expect(view.renderCounts.full == settled.full)
        let layer  = try #require(view.layer as? CAMetalLayer)
        let pixels = view.convertToBacking(view.bounds).size
        #expect(abs(layer.contentsRect.width * layer.drawableSize.width - pixels.width) < 0.5)
        #expect(layer.drawableSize.height == pixels.height.rounded(.up))

        // Settled: today's path, a preview and the ray tracer's refinement, or one precomputed render.
        try await until { view.renderCounts.full == settled.full + 1 }
        #expect(view.renderCounts.live == settled.live + 2)
        #expect(view.renderCounts.preview == settled.preview + (view.path == .rayTraced ? 1 : 0))
    }

    @Test("A room scrolled far out of sight renders nothing and lets its pulse go, and renders again back in sight")
    func culledOutOfSight() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let scroll = NSScrollView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 400,
            height: 300
        ))
        let document = NSView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 400,
            height: 2000
        ))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(
            x: 0,
            y: 1600
        ))
        let view = RoomLightView(
            device  : device,
            uniforms: room(.busy),
            frame   : CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
        )
        document.addSubview(view)
        #expect(view.isCulled)
        #expect(!view.isShown)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.renderCounts == RoomLightView.RenderCounts())

        // Back in sight it renders, and its light pulses.
        clip.scroll(to: .zero)
        try await until { view.renderCounts.full >= 1 && view.pulseLayer.animation(forKey: RoomLightView.pulseKey) != nil }
        #expect(!view.isCulled)
        #expect(view.isShown)

        // Far out of sight again, it keeps only its last image.
        clip.scroll(to: CGPoint(
            x: 0,
            y: 1600
        ))
        try await until { view.isCulled }
        #expect(view.pulseLayer.animation(forKey: RoomLightView.pulseKey) == nil)
        #expect(view.bodyFrames.isEmpty && view.passageFrames == nil && view.shownImage == nil)
        #expect(!view.canRenderQueuedFrame)
    }

    @Test("A change of uniforms draws a live frame at once and the full render only after the plaque's swing")
    func uniformsDrawLiveFirst() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let view = RoomLightView(
            device  : device,
            uniforms: room(.busy),
            frame   : CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
        )
        window.contentView?.addSubview(view)
        try await until { view.renderCounts.full >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        let settled = view.renderCounts
        let changed = ContinuousClock.now

        view.uniforms = room(
            .busy,
            hasOccupant: false
        )
        #expect(view.renderCounts == RoomLightView.RenderCounts(
            live   : settled.live + 1,
            preview: settled.preview,
            full   : settled.full
        ))
        try await until { view.renderCounts.full == settled.full + 1 }
        #expect(ContinuousClock.now - changed >= .milliseconds(850))
        #expect(view.renderCounts.preview == settled.preview)
    }

    @Test("A change of status renders fully at once; only the worker leaving or coming back waits for the swing")
    func statusRendersAtOnce() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = Self.window()
        defer { window.close() }
        let view = RoomLightView(
            device  : device,
            uniforms: room(.busy),
            frame   : CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
        )
        window.contentView?.addSubview(view)
        try await until { view.renderCounts.full >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        let settled = view.renderCounts
        let changed = ContinuousClock.now

        view.uniforms = room(.waiting)
        try await until { view.renderCounts.full == settled.full + 1 }
        #expect(ContinuousClock.now - changed < .milliseconds(500))
        #expect(view.renderCounts.live == settled.live)
    }

    @Test("With a change fade the shown image cross-fades into the new render; without one or under Reduce Motion it cuts")
    func changeCrossFades() async throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        for (fade, reducesMotion) in [(0.5, false), (0.5, true), (nil, false)] as [(Double?, Bool)] {
            HouseMotion.overrideReducesMotion = reducesMotion
            let window = Self.window()
            defer { window.close() }
            let view = RoomLightView(
                device  : device,
                uniforms: room(.free),
                frame   : CGRect(
                    x     : 0,
                    y     : 0,
                    width : 127,
                    height: 104
                )
            )
            view.changeFade = fade
            window.contentView?.addSubview(view)
            try await until { view.renderCounts.full >= 1 }
            try await Task.sleep(for: .milliseconds(300))
            let settled = view.renderCounts

            view.uniforms = room(.waiting)
            try await until { view.renderCounts.full == settled.full + 1 }
            guard let fade, !reducesMotion else {
                try await Task.sleep(for: .milliseconds(100))
                #expect(view.refineLayer.isHidden, "\(String(describing: fade)), \(reducesMotion)")
                continue
            }
            #expect(!view.refineLayer.isHidden)
            try await until { view.refineLayer.animation(forKey: RoomLightView.fadeKey) != nil }
            #expect(view.refineLayer.animation(forKey: RoomLightView.fadeKey)?.duration == fade)
        }
    }

    @Test("The live frame's weight is the pulse's own at that moment")
    func liveWeightFollowsThePulse() {
        let weights = RoomLightView.pulseWeights(
            for          : .waiting,
            reducesMotion: false
        )
        let cycle = HouseTiming.waitingBreath
        let begin = RoomLightView.pulseBeginTime(in: nil)
        for (index, weight) in weights.enumerated() {
            let time = begin + 7 * cycle + Double(index) / Double(weights.count) * cycle
            let shown = RoomLightView.pulseWeight(
                for          : .waiting,
                reducesMotion: false,
                at           : time
            )
            #expect(abs(shown - weight) < 1e-3)
        }
        let steady = RoomLightView.pulseWeight(
            for          : .free,
            reducesMotion: false,
            at           : begin + 1.3
        )
        #expect(steady == 1)
        let reduced = RoomLightView.pulseWeight(
            for          : .busy,
            reducesMotion: true,
            at           : begin + 1.3
        )
        #expect(reduced == 1)
    }

    @Test("A busy light flickers and a waiting light breathes, neither under Reduce Motion")
    func pulse() throws {
        let busy = RoomLightView.pulseWeights(
            for          : .busy,
            reducesMotion: false
        )
        #expect(busy.count == RoomLightView.framesPerCycle)
        #expect(busy.first == 1)
        #expect(abs((busy.min() ?? 0) - 0.8) < 0.05)

        let waiting = RoomLightView.pulseWeights(
            for          : .waiting,
            reducesMotion: false
        )
        #expect(waiting.count == RoomLightView.framesPerCycle)
        #expect(abs((waiting.min() ?? 0) - 0.55) < 0.01)

        #expect(RoomLightView.pulseWeights(for: .free, reducesMotion: false).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .off, reducesMotion: false).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .busy, reducesMotion: true).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .waiting, reducesMotion: true).isEmpty)

        let frame = try #require(
            CGContext(
                data            : nil,
                width           : 1,
                height          : 1,
                bitsPerComponent: 8,
                bytesPerRow     : 4,
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.noneSkipFirst.rawValue
            )?.makeImage()
        )
        let frames  = Array(repeating: frame, count: RoomLightView.framesPerCycle)
        let flicker = try #require(RoomLightView.pulse(frames, for: .busy))
        #expect(flicker.keyPath == "contents" && flicker.duration == 3.4)
        #expect(flicker.values?.count == frames.count + 1)
        // Phased to the host clock, as the brows' tint is.
        #expect(flicker.beginTime == RoomLightView.pulseBeginTime(in: nil))
        let breath = try #require(RoomLightView.pulse(frames, for: .waiting))
        #expect(breath.duration == 2.2)
        #expect(RoomLightView.pulse(frames, for: .free) == nil)
    }

    @Test("Pulse frames are shared only on Apple GPUs, managed on Intel and AMD")
    func frameStorage() {
        // Apple silicon.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: true, hasUnifiedMemory: true) == .shared)
        // An integrated Intel GPU reports unified memory, yet takes no shared textures.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: false, hasUnifiedMemory: true) == .managed)
        // A discrete AMD or Intel GPU.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: false, hasUnifiedMemory: false) == .managed)
    }

    @Test("A shallow room leans left: the worker larger at the left, and the stage tells the shaders where")
    func leaningStage() {
        let size = CGSize(
            width : 260,
            height: RoomLightTests.shallowRoomHeight
        )
        let centred = RoomLightUniforms.Shape(size: size)
        let leaning = RoomLightUniforms.Shape(
            size: size,
            lean: 1
        )
        #expect(centred.bodyX == 130 && leaning.bodyX == Float(0.5 * size.height))
        // The rows' worker is about a sixth larger than in the rows before, 84 points tall, whose share
        // of the short side was 0.17.
        let before: Float = 0.17 * 84
        #expect(leaning.sphereRadius / before > 1.15 && leaning.sphereRadius / before < 1.2)
        for camera in [RoomCamera.top, .tilted] {
            let packed = RoomLightUniforms(
                status     : .busy,
                shape      : .circle,
                hasOccupant: true,
                camera     : camera,
                lean       : 1
            ).packed(
                size      : size,
                pixelWidth: 520
            )
            #expect(packed.stage == SIMD4(leaning.bodyX, 1, 0, 0), "\(camera)")
            #expect(packed.shape.z == leaning.sphereRadius, "\(camera)")
        }
    }

    @Test("A room leaning left is lit from the worker at the left and fades toward the right, on both paths and cameras")
    func leaningLight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var renderers: [any RoomRenderer] = [try #require(PrecomputedRoomRenderer(device: device))]
        if let tracer = RayTracedRoomRenderer(device: device) {
            renderers.append(tracer)
        }
        let size   = CGSize(
            width : 260,
            height: RoomLightTests.shallowRoomHeight
        )
        let band   = 10
        let worker = Int(RoomLightUniforms.Shape.bodyX(
            in  : size,
            lean: 1
        )) / band
        for renderer in renderers {
            for camera in [RoomCamera.top, .tilted] {
                // The mean brightness of each band of columns 10 points wide, of an empty room.
                func bands(_ lean: Float) throws -> [Double] {
                    let image = try Self.render(
                        RoomLightUniforms(
                            status     : .busy,
                            shape      : .circle,
                            hasOccupant: false,
                            camera     : camera,
                            lean       : lean
                        ),
                        with  : renderer,
                        size  : size,
                        device: device
                    )
                    return stride(
                        from: 0,
                        to  : image.width,
                        by  : band
                    ).map { start in
                        var sum = 0
                        for x in start ..< min(start + band, image.width) {
                            for y in 0 ..< image.height {
                                let pixel = image.pixel(x, y)
                                sum += pixel.red + pixel.green + pixel.blue
                            }
                        }
                        return Double(sum) / Double(band * image.height)
                    }
                }
                let name    = "\(type(of: renderer)) \(camera)"
                let leaning = try bands(1)
                let centred = try bands(0)
                let peak    = try #require(leaning.indices.max { leaning[$0] < leaning[$1] })
                let middle  = try #require(centred.indices.max { centred[$0] < centred[$1] })
                #expect(abs(peak - worker) <= 2, "\(name): \(leaning)")
                #expect(abs(middle - centred.count / 2) <= 3, "\(name): \(centred)")
                // Right of the worker the light only fades, softly, with no step a hard edge would make,
                // and is dim by the last third.
                let dim = Int(0.7 * size.width) / band
                for index in (worker + 2) ..< (leaning.count - 1) {
                    #expect(leaning[index + 1] <= leaning[index] + 1.5, "\(name) at band \(index): \(leaning)")
                    #expect(leaning[index] - leaning[index + 1] < 0.12 * leaning[peak], "\(name) at band \(index): \(leaning)")
                }
                #expect(leaning[dim] < 0.4 * leaning[peak], "\(name): \(leaning)")
                // The right end is black, its walls and corners too: only the dither's half step is left.
                for index in (Int(0.82 * size.width) / band) ..< leaning.count {
                    #expect(leaning[index] < 3, "\(name) at band \(index): \(leaning)")
                }
            }
        }
    }

    @Test("A room set into the column spills its light's colour, and the moon's faint cool light when the worker is off")
    func openingSpillColor() throws {
        let device  = try #require(MTLCreateSystemDefaultDevice())
        let opening = RoomOpeningView(
            device  : device,
            uniforms: room(.busy)
        )
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        for status in [WorkerStatus.busy, .free, .waiting] {
            opening.uniforms = room(status)
            let light = try #require(status.light)
            let color = try #require(opening.glow.shadowColor?.converted(
                to     : sRGB,
                intent : .defaultIntent,
                options: nil
            )?.components)
            #expect(abs(color[0] - light.red) < 1e-6 && abs(color[1] - light.green) < 1e-6, "\(status)")
            #expect(abs(color[2] - light.blue) < 1e-6, "\(status)")
            #expect(!opening.glow.isHidden && opening.glow.shadowOpacity > 0 && !opening.sill.isHidden, "\(status)")
        }
        opening.uniforms = room(.off)
        let moon = try #require(opening.glow.shadowColor?.converted(
            to     : sRGB,
            intent : .defaultIntent,
            options: nil
        )?.components)
        #expect(moon[2] > moon[0], "cool: \(moon)")
        #expect(!opening.glow.isHidden && opening.glow.shadowOpacity > 0)
        #expect(opening.glow.shadowOpacity < RoomOpeningView.spillOpacity * Float(WorkerStatus.free.lightStrength))
        #expect(opening.glow.animation(forKey: RoomOpeningView.pulseKey) == nil)
    }

    @Test("The spill and the sill pulse on the room's own cycle and phase, and hold still under Reduce Motion")
    func openingSpillPulse() throws {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let device  = try #require(MTLCreateSystemDefaultDevice())
        let window  = Self.window()
        defer { window.close() }
        let opening = RoomOpeningView(
            device  : device,
            uniforms: room(.waiting)
        )
        window.contentView?.addSubview(opening)
        let spill   = try #require(opening.glow.animation(forKey: RoomOpeningView.pulseKey) as? CAKeyframeAnimation)
        let sill    = try #require(opening.sill.animation(forKey: RoomOpeningView.pulseKey) as? CAKeyframeAnimation)
        let weights = RoomLightView.pulseWeights(
            for          : .waiting,
            reducesMotion: false
        )
        let base    = RoomOpeningView.spillOpacity * Float(WorkerStatus.waiting.lightStrength)
        for pulse in [spill, sill] {
            #expect(pulse.duration == RoomLightView.pulseCycle(for: .waiting))
            #expect(pulse.repeatCount == .infinity)
            #expect(pulse.keyTimes?.count == weights.count + 1)
        }
        #expect(spill.beginTime == RoomLightView.pulseBeginTime(in: opening.glow))
        #expect(sill.beginTime == RoomLightView.pulseBeginTime(in: opening.sill))
        let values = (spill.values as? [NSNumber])?.map(\.floatValue)
        #expect(values == (weights + [weights[0]]).map { base * $0 })

        // A light that holds still, and any light under Reduce Motion, does not pulse.
        opening.uniforms = room(.free)
        #expect(opening.glow.animation(forKey: RoomOpeningView.pulseKey) == nil)
        HouseMotion.overrideReducesMotion = true
        opening.uniforms = room(.busy)
        #expect(opening.glow.animation(forKey: RoomOpeningView.pulseKey) == nil)
        #expect(opening.sill.animation(forKey: RoomOpeningView.pulseKey) == nil)
    }

    @Test("The spill fills the gap between rooms and its blur stays within it, so it never lights a neighbour")
    func openingSpillFitsTheGap() {
        // A shadow's blur reaches about twice its radius; upward the drop takes some of that back.
        #expect(2 * RoomOpeningView.spillRadius <= HouseLayout.gap)
        #expect(2 * RoomOpeningView.spillRadius - RoomOpeningView.spillDrop < HouseLayout.gap)
        #expect(RoomOpeningView.spillReach >= 2 * RoomOpeningView.spillRadius + RoomOpeningView.spillDrop)
        #expect(HouseLayout.gap >= 12 && HouseLayout.margin >= 10)
    }

    @Test("A row leaning left spills nothing on its right, where its room is black, and a centred room spills all round")
    func openingSpillFollowsTheLean() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size   = CGSize(
            width : 260,
            height: RoomLightTests.shallowRoomHeight
        )
        for lean: Float in [0, 1] {
            var uniforms = room(.busy)
            uniforms.lean = lean
            let opening = RoomOpeningView(
                device  : device,
                uniforms: uniforms
            )
            opening.frame = CGRect(
                origin: .zero,
                size  : size
            )
            opening.layout()
            let reach  = RoomOpeningView.spillReach
            let alphas = (opening.spillMask.colors as? [CGColor])?.map(\.alpha) ?? []
            let sill   = (opening.sill.colors as? [CGColor])?.map(\.alpha) ?? []
            let ends   = (opening.spillMask.locations ?? []).map { CGFloat($0.doubleValue) * (size.width + 2 * reach) - reach }
            if lean == 0 {
                #expect(alphas.allSatisfy { $0 == 1 })
                #expect(Set(sill).count == 1)
            } else {
                // Gone past the right's dark range, which ends inside the room, short of its right edge.
                #expect(alphas.last == 0 && sill.last == 0)
                let body = RoomLightUniforms.Shape.bodyX(
                    in  : size,
                    lean: 1
                )
                #expect(ends.count == 3 && ends[1] > body && ends[2] < size.width - 40, "\(ends)")
            }
        }
    }

    @Test("The precomputed path renders without hardware ray tracing")
    func precomputed() throws {
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
        try expectContactShadow(renderer, device: device)
    }

    @Test("The ray-traced path lights the room")
    func rayTraced() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(device.supportsRaytracing)
        let renderer = try #require(RayTracedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
        try expectContactShadow(renderer, device: device)
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

    /// Gives `view` a new width and lays it out, as a drag of the sidebar does.
    private func resize(
        _ view: NSView,
        width : CGFloat
    ) {
        view.setFrameSize(CGSize(
            width : width,
            height: view.frame.height
        ))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// Waits for `condition`, checking every few milliseconds, for at most two seconds.
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    private func room(
        _ status   : WorkerStatus,
        hasOccupant: Bool = true
    ) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : status,
            shape      : .circle,
            hasOccupant: hasOccupant
        )
    }

    /// The body's normals at `points` of a room of `size`, from RoomLight.metal's `bodyNormals`.
    private func bodyNormals(
        _ uniforms: RoomLightUniforms,
        at points : [SIMD2<Float>],
        size      : CGSize,
        device    : MTLDevice
    ) throws -> [SIMD3<Float>] {
        let pipeline = try #require(PrecomputedRoomRenderer.pipeline(
            named : "bodyNormals",
            device: device
        ))
        var packed = uniforms.packed(
            size      : size,
            pixelWidth: Int(size.width)
        )
        let input = try #require(device.makeBuffer(
            bytes  : points,
            length : points.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ))
        let output = try #require(device.makeBuffer(
            length : points.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ))
        let queue         = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder       = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &packed,
            length: MemoryLayout<RoomLightUniforms.Packed>.stride,
            index : 0
        )
        encoder.setBuffer(
            input,
            offset: 0,
            index : 1
        )
        encoder.setBuffer(
            output,
            offset: 0,
            index : 2
        )
        encoder.dispatchThreads(
            MTLSize(
                width : points.count,
                height: 1,
                depth : 1
            ),
            threadsPerThreadgroup: MTLSize(
                width : min(points.count, pipeline.maxTotalThreadsPerThreadgroup),
                height: 1,
                depth : 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        let normals = output.contents().bindMemory(
            to      : SIMD4<Float>.self,
            capacity: points.count
        )
        return (0..<points.count).map { SIMD3(normals[$0].x, normals[$0].y, normals[$0].z) }
    }

    /// A busy room's light pools warm at the centre. The room is empty, so the centre pixel shows
    /// the floor, not the sphere.
    private func expectLitRoom(
        _ renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws {
        let image  = try Self.render(
            room(.busy, hasOccupant: false),
            with  : renderer,
            device: device
        )
        let centre = image.pixel(image.width / 2, image.height / 2)
        let corner = image.pixel(8, 8)
        #expect(centre.red + centre.green + centre.blue > corner.red + corner.green + corner.blue)
        #expect(centre.red > centre.blue)
    }

    /// With the worker in the room, the floor just below the sphere is darker than the same floor
    /// with the room empty: the sphere casts its shadow there.
    private func expectContactShadow(
        _ renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws {
        let occupied = try Self.render(
            room(.busy),
            with  : renderer,
            device: device
        )
        let empty = try Self.render(
            room(.busy, hasOccupant: false),
            with  : renderer,
            device: device
        )
        let radius = Int(Double(RoomLightUniforms.Shape.centreSphereShare) * Double(occupied.height))
        let x      = occupied.width / 2
        let y      = occupied.height / 2 + radius + 3
        #expect(occupied.pixel(x, y).red + 6 < empty.pixel(x, y).red)
    }

    /// Pixels is a rendered room read back, in BGRA order.
    struct Pixels {
        let width : Int
        let height: Int
        let bytes : [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index]))
        }
    }

    /// Renders `uniforms` at one pixel per point into a room of `size`, 128 × 104 by default, and
    /// reads it back.
    static func render(
        _ uniforms   : RoomLightUniforms,
        with renderer: any RoomRenderer,
        size         : CGSize = CGSize(width: 128, height: 104),
        device       : MTLDevice
    ) throws -> Pixels {
        let width  = Int(size.width)
        let height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let texture       = try #require(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(
            uniforms,
            size         : CGSize(width: width, height: height),
            into         : texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from       : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return Pixels(
            width : width,
            height: height,
            bytes : bytes
        )
    }
}
